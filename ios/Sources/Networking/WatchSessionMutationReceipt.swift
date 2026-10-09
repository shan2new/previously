import Foundation

enum WatchSessionMutationReceipt {
    /// A legacy server omits the header. A replay or superseded write explicitly reports false,
    /// requiring a canonical read rather than treating the submitted session as server state.
    static func applied(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "X-Previously-Applied")?.lowercased() != "false"
    }
}
