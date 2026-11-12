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
    /// Set when the scan switched the sensor's Bluetooth stream to this phone: its Bluetooth
    /// address, upper-case hex with no separators.
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
                } catch {
                    problem = "The read was cut short. Hold the phone still against the sensor and try again."
                }
                if mode == .takeOverBluetooth {
                    guard fram != nil else { throw SensorScanError.failed(problem ?? "Couldn't read the sensor.") }
                    // A newer scan replaced this one: don't move the stream for a request that's gone.
                    guard self.session === session else { return }
                    let params = Libre2.enableStreamingParameters(uid: uid, patchInfo: info.raw)
                    let reply = try await tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA1,
                                                            customRequestParameters: Data(params))
                    guard let mac = DirectSensor.macAddress(fromEnableReply: [UInt8](reply)) else {
                        throw SensorScanError.cannotStream
                    }
                    address = mac
                }
            } else if mode == .takeOverBluetooth {
                throw SensorScanError.cannotStream
            }

            guard self.session === session else { return }
            let result = SensorScanResult(patchInfo: info, serial: serial, scannedAt: Date(), uid: uid,
                                          fram: fram, decodeProblem: problem, bluetoothAddress: address)
            session.alertMessage = address != nil ? "Connected to your sensor." : fram != nil ? "Read your sensor." : (info.family == .unknown ? "Read an unrecognised sensor." : info.family.rawValue)
            session.invalidate()
            finish(.success(result))
        } catch {
            guard self.session === session else { return }
            session.invalidate(errorMessage: "Couldn't read the sensor. Try again and hold still.")
            finish(.failure(error as? SensorScanError ?? SensorScanError.failed(error.localizedDescription)))
        }
    }

    /// The 43 eight-byte FRAM blocks, three at a time (what Libre sensors accept per request).
    private func readFRAM(_ tag: NFCISO15693Tag) async throws -> [UInt8] {
        var out = [UInt8]()
        var block = 0
        while block < Libre2.framBlocks {
            let count = min(3, Libre2.framBlocks - block)
            let blocks = try await tag.readMultipleBlocks(requestFlags: [.highDataRate, .address],
                                                          blockRange: NSRange(location: block, length: count))
            guard blocks.count == count, blocks.allSatisfy({ $0.count == 8 }) else {
                throw SensorScanError.failed("short read")
            }
            blocks.forEach { out += [UInt8]($0) }
            block += count
        }
        return out
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
