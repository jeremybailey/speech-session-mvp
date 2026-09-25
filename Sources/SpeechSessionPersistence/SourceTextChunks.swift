import Foundation

public enum SourceTextChunks {
    /// Every character is covered; overlap protects statements crossing a chunk boundary.
    public static func split(_ text: String, limit: Int, overlap: Int = 200) -> [String] {
        guard !text.isEmpty else { return [] }
        let size = max(limit, 1)
        let overlap = min(max(overlap, 0), size - 1)
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            if end == text.endIndex { break }
            start = text.index(end, offsetBy: -overlap)
        }
        return result
    }
}
