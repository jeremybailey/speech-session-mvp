import Foundation

public enum ContactActionURL {
    public static func make(label: String, value: String) -> URL? {
        let label = label.lowercased().trimmingCharacters(in: .whitespaces)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.contains("phone") || label == "tel" || label == "telephone" {
            let parts = value.components(separatedBy: try! NSRegularExpression(pattern: #"(?i)\s*(?:ext\.?|extension|x)\s*(?=\d)"#))
            let number = (parts.first ?? value).filter { $0.isNumber || $0 == "+" }
            guard number.filter(\.isNumber).count >= 3 else { return nil }
            return URL(string: "tel:" + number)
        }
        if label.contains("address"), !value.isEmpty {
            var url = URLComponents(string: "maps://")!
            url.queryItems = [URLQueryItem(name: "q", value: value)]
            return url.url
        }
        return nil
    }
}

private extension String {
    func components(separatedBy expression: NSRegularExpression) -> [String] {
        guard let match = expression.firstMatch(in: self, range: NSRange(startIndex..., in: self)), let range = Range(match.range, in: self) else { return [self] }
        return [String(self[..<range.lowerBound]), String(self[range.upperBound...])]
    }
}
