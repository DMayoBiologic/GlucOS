import Foundation
#if canImport(CoreNFC)
import CoreNFC
#endif

/// What one NFC tap on a Libre sensor told us.
struct SensorScanResult: Equatable {
    let patchInfo: LibrePatchInfo
    let serial: String?
    let scannedAt: Date
}

enum SensorScanError: LocalizedError {
    case unavailable
    case notLibre
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "This iPhone can't read NFC tags."
        case .notLibre: return "That tag isn't a FreeStyle Libre sensor."
        case .failed(let m): return m
        }
    }
}

/// Reads a Libre sensor's unencrypted header with one NFC tap: its type, region and serial.
/// It never reads glucose data and never starts, pairs or changes the sensor.
@MainActor
final class SensorScanner: NSObject {
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
    #endif

    func scan() async throws -> SensorScanResult {
        #if canImport(CoreNFC)
        guard Self.isAvailable else { throw SensorScanError.unavailable }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
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

    fileprivate func read(_ tag: NFCISO15693Tag, in session: NFCTagReaderSession) {
        let identifier = [UInt8](tag.identifier)
        // Abbott tags carry the TI manufacturer code (0x07) the custom command is addressed to.
        tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA1, customRequestParameters: Data()) { [weak self] data, error in
            Task { @MainActor in
                guard let self, self.session === session else { return }
                if let error {
                    session.invalidate(errorMessage: "Couldn't read the sensor. Try again and hold still.")
                    self.finish(.failure(SensorScanError.failed(error.localizedDescription)))
                    return
                }
                let info = LibrePatchInfo(raw: [UInt8](data))
                let result = SensorScanResult(patchInfo: info,
                                              serial: LibrePatchInfo.serialNumber(identifier: identifier, patchInfo: info),
                                              scannedAt: Date())
                session.alertMessage = info.family == .unknown ? "Read an unrecognised sensor." : info.family.rawValue
                session.invalidate()
                self.finish(.success(result))
            }
        }
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
            session.connect(to: first) { error in
                Task { @MainActor in
                    guard self.session === session else { return }
                    if let error {
                        session.invalidate(errorMessage: "Lost the sensor. Try again and hold still.")
                        self.finish(.failure(SensorScanError.failed(error.localizedDescription)))
                    } else {
                        self.read(tag, in: session)
                    }
                }
            }
        }
    }
}
#endif
