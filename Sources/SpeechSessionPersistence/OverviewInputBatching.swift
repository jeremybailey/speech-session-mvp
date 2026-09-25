import Foundation

public enum OverviewInputBatching {
    /// Lossless bounded partitions. Long individual entries are split, never dropped.
    public static func chunks(_ input: String, limit: Int) -> [String] {
        precondition(limit > 0)
        var result: [String] = []
        var start = input.startIndex
        while start < input.endIndex {
            let end = input.index(start, offsetBy: limit, limitedBy: input.endIndex) ?? input.endIndex
            result.append(String(input[start..<end]))
            start = end
        }
        return result
    }
}
