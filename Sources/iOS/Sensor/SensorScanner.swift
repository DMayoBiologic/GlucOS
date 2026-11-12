import Foundation
#if canImport(CoreNFC)
import CoreNFC
#endif

/// What one NFC tap on a Libre sensor told us.
struct SensorScanResult {
    let patchInfo: LibrePatchInfo
    let serial: String?
    let scannedAt: Date
    /// The tag's 8-byte identifier, least-significant byte first (what the Libre 2 crypto wants).
    let uid: [UInt8]
    /// The decrypted memory, when this is a sensor GlucOS can decode and the read got all of it.
    let fram: LibreFRAM?
    /// Why `fram` is nil for a sensor that should decode (read cut short, checksum failed).
    let decodeProblem: String?
    /// Technical detail behind `decodeProblem` (which block, which NFC error), for a bug report.
    let decodeDetail: String?
    /// Set when the scan switched the sensor's Bluetooth stream to this phone.
    let bluetoothAddress: String?

    /// Current reading plus the last 8 hours, oldest first.
    var readings: [GlucoseReading] {
        fram.map { LibreReadings.readings(fram: $0, readAt: scannedAt) } ?? []
    }
}

enum SensorScanError: LocalizedError {
    case unavailable
    case notLibre
    case cannotStream
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "This iPhone can't read NFC tags."
        case .notLibre: return "That tag isn't a FreeStyle Libre sensor."
        case .cannotStream: return "GlucOS can't take over Bluetooth on this sensor."
        case .failed(let m): return m
        }
    }
}

/// One NFC tap on a Libre sensor.
///
/// `.identify` and `.read` only read: the header, then (for Libre 2 and 2 Plus) the 344-byte memory,
/// which GlucOS decrypts on the phone. Neither changes anything on the sensor, so LibreLink is unaffected.
/// `.takeOverBluetooth` also sends the "enable streaming" command, which moves the sensor's Bluetooth
/// stream from LibreLink to GlucOS.
@MainActor
final class SensorScanner: NSObject {
    enum Mode { case identify, read, takeOverBluetooth }

    static var isAvailable: Bool {
        #if canImport(CoreNFC)
        return NFCTagReaderSession.readingAvailable
        #else
        return false
        #endif
    }

    #if canImport(CoreNFC)
    private var session: NFCTagReaderSession?
    private var continuation: CheckedContinuation<SensorScanResult, Error>?
    private var mode: Mode = .read
    #endif

    func scan(_ mode: Mode = .read) async throws -> SensorScanResult {
        #if canImport(CoreNFC)
        guard Self.isAvailable else { throw SensorScanError.unavailable }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            self.mode = mode
            let s = NFCTagReaderSession(pollingOption: .iso15693, delegate: self, queue: .main)
            s?.alertMessage = "Hold the top of your iPhone against your sensor."
            session = s
            s?.begin()
        }
        #else
        throw SensorScanError.unavailable
        #endif
    }

    #if canImport(CoreNFC)
    fileprivate func finish(_ result: Result<SensorScanResult, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        session = nil
    }

    fileprivate func run(_ tag: NFCISO15693Tag, first: NFCTag, in session: NFCTagReaderSession) async {
        do {
            try await session.connect(to: first)
            guard self.session === session else { return }
            let identifier = [UInt8](tag.identifier)
            let uid = Array(identifier.reversed())
            let response = try await tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA1,
                                                       customRequestParameters: Data())
            let info = LibrePatchInfo(raw: [UInt8](response))
            let serial = LibrePatchInfo.serialNumber(identifier: identifier, patchInfo: info)

            var fram: LibreFRAM?
            var problem: String?
            var detail: String?
            var address: String?
            if mode != .identify, info.directAccess == .encryptedKnown, info.raw.count == 6 {
                session.alertMessage = "Reading…"
                do {
                    let encrypted = try await readFRAM(tag)
                    fram = LibreFRAM(decrypted: try Libre2.decryptFRAM(uid: uid, patchInfo: info.raw, fram: encrypted))
                    if fram == nil {
                        problem = "The sensor's data decoded but didn't make sense, so GlucOS can't show it. Try again in a minute."
                    }
                } catch Libre2.CryptoError.badCRC {
                    problem = "The sensor's data didn't pass its checksum after decoding, so GlucOS can't read this sensor."
                } catch let e as FRAMReadError {
                    problem = "The read was cut short. Hold the phone still against the sensor and try again."
                    detail = e.detail
                } catch {
                    problem = "The read was cut short. Hold the phone still against the sensor and try again."
                    detail = Self.describe(error)
                }
                if let problem {
                    Diagnostics.shared.report(Self.diagnostic(patchInfo: info, problem: problem, detail: detail,
                                                              mode: mode))
                }
                if mode == .takeOverBluetooth {
                    guard fram != nil else {
                        throw SensorScanError.failed([problem ?? "Couldn't read the sensor.", detail.map { "Details: \($0)" }]
                            .compactMap { $0 }.joined(separator: "\n\n"))
                    }
                    // A newer scan replaced this one: don't move the stream for a request that's gone.
                    guard self.session === session else { return }
                    let params = Libre2.enableStreamingParameters(uid: uid, patchInfo: info.raw)
                    let reply = try await tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA1,
                                                            customRequestParameters: Data(params))
                    guard reply.count == 6 else { throw SensorScanError.cannotStream }
                    address = reply.reversed().map { String(format: "%02X", $0) }.joined(separator: ":")
                }
            } else if mode == .takeOverBluetooth {
                throw SensorScanError.cannotStream
            }

            guard self.session === session else { return }
            let result = SensorScanResult(patchInfo: info, serial: serial, scannedAt: Date(), uid: uid,
                                          fram: fram, decodeProblem: problem, decodeDetail: detail, bluetoothAddress: address)
            session.alertMessage = fram != nil ? "Read your sensor." : (info.family == .unknown ? "Read an unrecognised sensor." : info.family.rawValue)
            session.invalidate()
            finish(.success(result))
        } catch {
            guard self.session === session else { return }
            if !DiagnosticEvent.isNoise(error) {
                Diagnostics.shared.report(Self.diagnostic(step: "scan", error: error, patchInfo: nil, mode: mode))
            }
            session.invalidate(errorMessage: "Couldn't read the sensor. Try again and hold still.")
            finish(.failure(error as? SensorScanError ?? SensorScanError.failed(error.localizedDescription)))
        }
    }

    /// Why the memory read stopped: the first block that couldn't be read, and every way it was tried.
    struct FRAMReadError: Error {
        let block: Int
        let attempts: [String]
        var detail: String { "block \(block): " + attempts.joined(separator: "; ") }
    }

    /// The 43 eight-byte FRAM blocks.
    ///
    /// Sensors and iPhones differ in what they accept, so each step falls back: three blocks at a
    /// time without the address flag (the same flags as the patch-info command, which works),
    /// then with it, then one block at a time. Each is retried once, since a tap often wobbles.
    private func readFRAM(_ tag: NFCISO15693Tag) async throws -> [UInt8] {
        var out = [UInt8]()
        var block = 0
        var attempts = [String]()
        while block < Libre2.framBlocks {
            let count = min(3, Libre2.framBlocks - block)
            var got: [Data]?
            attempts.removeAll()
            outer: for flags in Self.multiFlags {
                for _ in 0..<2 {
                    do {
                        let blocks = try await tag.readMultipleBlocks(requestFlags: flags,
                                                                      blockRange: NSRange(location: block, length: count))
                        if blocks.count == count, blocks.allSatisfy({ $0.count == 8 }) {
                            got = blocks
                            break outer
                        }
                        attempts.append("multi\(Self.name(flags)) got \(blocks.map(\.count))")
                    } catch {
                        attempts.append("multi\(Self.name(flags)) " + Self.describe(error))
                        if Self.connectionLost(error) { throw FRAMReadError(block: block, attempts: attempts) }
                    }
                }
            }
            if got == nil {
                // One block at a time.
                var singles = [Data]()
                for b in block..<(block + count) {
                    var data: Data?
                    for _ in 0..<2 where data == nil {
                        do {
                            let d = try await tag.readSingleBlock(requestFlags: .highDataRate, blockNumber: UInt8(b))
                            if d.count == 8 { data = d } else { attempts.append("single \(b) got \(d.count)") }
                        } catch {
                            attempts.append("single \(b) " + Self.describe(error))
                            if Self.connectionLost(error) { throw FRAMReadError(block: b, attempts: attempts) }
                        }
                    }
                    guard let data else { throw FRAMReadError(block: b, attempts: attempts) }
                    singles.append(data)
                }
                got = singles
            }
            got?.forEach { out += [UInt8]($0) }
            block += count
        }
        return out
    }

    private static let multiFlags: [NFCISO15693RequestFlag] = [[.highDataRate], [.highDataRate, .address]]

    private static func name(_ flags: NFCISO15693RequestFlag) -> String {
        flags.contains(.address) ? "(addr)" : ""
    }

    private static func connectionLost(_ error: Error) -> Bool {
        (error as? NFCReaderError)?.code == .readerTransceiveErrorTagConnectionLost
            || (error as? NFCReaderError)?.code == .readerSessionInvalidationErrorSessionTimeout
    }

    /// An NFC error as "NFC 102 (Tag response error), ISO 0x0F", or the error's own text.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var s = ns.domain == NFCErrorDomain ? "NFC \(ns.code)" : "\(ns.domain) \(ns.code)"
        s += " (\(ns.localizedDescription))"
        if let iso = ns.userInfo[NFCISO15693TagResponseErrorKey] as? NSNumber {
            s += String(format: ", ISO 0x%02X", iso.intValue)
        }
        return s
    }
    #endif
}

#if canImport(CoreNFC)
extension SensorScanner: NFCTagReaderSessionDelegate {
    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            // A successful read already finished; this is just the sheet closing.
            guard self.session === session, self.continuation != nil else { return }
            let nfc = error as? NFCReaderError
            if nfc?.code == .readerSessionInvalidationErrorUserCanceled {
                self.finish(.failure(CancellationError()))
            } else {
                if nfc?.code != .readerSessionInvalidationErrorSessionTimeout {
                    Diagnostics.shared.report(Self.diagnostic(step: "session", error: error, patchInfo: nil, mode: self.mode))
                }
                self.finish(.failure(SensorScanError.failed(error.localizedDescription)))
            }
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        Task { @MainActor in
            guard self.session === session else { return }
            guard let first = tags.first, case let .iso15693(tag) = first else {
                session.invalidate(errorMessage: SensorScanError.notLibre.localizedDescription)
                self.finish(.failure(SensorScanError.notLibre))
                return
            }
            await self.run(tag, first: first, in: session)
        }
    }
}
#endif
