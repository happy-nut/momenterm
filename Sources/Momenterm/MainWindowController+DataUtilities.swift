import Foundation

// Small controller-level data helpers shared across output pipelines.
extension MainWindowController {
    static func joinDataChunks(_ chunks: [Data]) -> Data {
        var joined = Data()
        joined.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
        for chunk in chunks {
            joined.append(chunk)
        }
        return joined
    }
}
