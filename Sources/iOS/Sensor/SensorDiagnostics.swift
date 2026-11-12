import Foundation
#if canImport(CoreNFC)
import CoreNFC
#endif

// Error reports for Settings › Read sensor (see Sources/Core/Diagnostics.swift). They carry the
// sensor's type, region and patch info bytes, which identify the model, never its serial number
// or readings.

extension SensorScanResult {
    /// The report for a read that identified the sensor but couldn't decode it, if this was one.
    var diagnostic: DiagnosticEvent? {
        decodeProblem.map { SensorScanner.diagnostic(patchInfo: patchInfo, problem: $0, detail: decodeDetail, mode: .read) }
    }
}

extension SensorScanner {
    nonisolated static let feature = "sensor.nfc"

    nonisolated static func context(_ info: LibrePatchInfo?, mode: Mode) -> [String: String] {
        var c = ["mode": "\(mode)"]
        if let info {
            c["sensor"] = info.family.rawValue
            c["region"] = info.region.rawValue
            c["patchInfo"] = info.hex
        }
        return c
    }

    /// The memory read failed: the code is the NFC error from the Details line ("NFC 100"), or
    /// what went wrong after the read.
    nonisolated static func diagnostic(patchInfo: LibrePatchInfo, problem: String, detail: String?, mode: Mode) -> DiagnosticEvent {
        let code: String
        if let detail, let r = detail.range(of: #"NFC \d+"#, options: [.regularExpression, .backwards]) {
            code = String(detail[r])
        } else if problem.contains("checksum") {
            code = "bad-crc"
        } else {
            code = "bad-data"
        }
        return DiagnosticEvent(feature: feature, step: "read-memory", code: code, message: problem, detail: detail,
                               context: context(patchInfo, mode: mode))
    }

    nonisolated static func diagnostic(step: String, error: Error, patchInfo: LibrePatchInfo?, mode: Mode) -> DiagnosticEvent {
        var e = DiagnosticEvent(feature: feature, step: step, error: error, context: context(patchInfo, mode: mode))
        #if canImport(CoreNFC)
        let ns = error as NSError
        if ns.domain == NFCErrorDomain {
            e.code = "NFC \(ns.code)"
            e.detail = "NFC \(ns.code) (\(ns.localizedDescription))"
                + ((ns.userInfo[NFCISO15693TagResponseErrorKey] as? NSNumber).map { String(format: ", ISO 0x%02X", $0.intValue) } ?? "")
        }
        #endif
        return e
    }

}
