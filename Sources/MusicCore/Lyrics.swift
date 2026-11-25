import Foundation

public struct LyricLine: Identifiable, Codable, Equatable, Sendable {
    public var id: Int
    public var time: Double
    public var text: String
}

public struct LyricsDocument: Codable, Equatable, Sendable {
    public var rawText: String
    public var lines: [LyricLine]
    public var plainText: String
    public var source: String
    public var isSynced: Bool { !lines.isEmpty }

    public init(text: String, source: String = "本地歌词") {
        rawText = text
        self.source = source
        let regex = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        let offsetRegex = try! NSRegularExpression(pattern: #"(?i)\[offset:\s*(-?\d+)\]"#)
        let full = text as NSString
        let offsetMatch = offsetRegex.firstMatch(in: text, range: NSRange(location: 0, length: full.length))
        let offset = offsetMatch.flatMap { Double(full.substring(with: $0.range(at: 1))) }.map { $0 / 1000 } ?? 0
        var parsed: [(Double, String)] = []
        for row in text.components(separatedBy: .newlines) {
            let ns = row as NSString
            let matches = regex.matches(in: row, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let content = ns.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                guard seconds < 60 else { continue }
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound {
                    let digits = ns.substring(with: match.range(at: 3))
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                parsed.append((max(0, minutes * 60 + seconds + fraction + offset), content))
            }
        }
        lines = parsed.enumerated().sorted {
            $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0
        }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.element.0, text: $0.element.element.1) }
        plainText = lines.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines)
            : lines.map(\.text).joined(separator: "\n")
    }

    public func activeLine(at time: Double) -> Int? {
        guard time.isFinite, let first = lines.first, time >= first.time else { return nil }
        var lower = 0, upper = lines.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lines[middle].time <= time { lower = middle + 1 } else { upper = middle }
        }
        return lines[lower - 1].id
    }
}
