import Foundation
import RelayKit
#if canImport(Glibc)
import Glibc
#endif

setvbuf(stdout, nil, _IOLBF, 0)

do {
    let config = try RelayConfig.fromEnvironment()
    try await Relay.run(config: config)
} catch {
    FileHandle.standardError.write(Data("glucos-relay: \(error)\n".utf8))
    exit(1)
}
