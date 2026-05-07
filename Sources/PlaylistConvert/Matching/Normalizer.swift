import Foundation

enum Normalizer {
    /// Aggressive normalization for matching titles and artists across services.
    /// Lower-cases, strips diacritics, removes common parenthetical/dashed cruft
    /// ("feat.", "Remastered 2011", "- Single Version", etc.), collapses whitespace.
    static func normalize(_ s: String) -> String {
        var working = s

        working = working.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)

        working = working.replacingOccurrences(of: "&", with: " and ")
        working = working.replacingOccurrences(of: "’", with: "'")
        working = working.replacingOccurrences(of: "‘", with: "'")
        working = working.replacingOccurrences(of: "“", with: "\"")
        working = working.replacingOccurrences(of: "”", with: "\"")
        working = working.replacingOccurrences(of: "—", with: "-")
        working = working.replacingOccurrences(of: "–", with: "-")

        working = stripParentheticals(working, droppedKeywords: parenDropKeywords)
        working = stripBracketedSuffixes(working, droppedKeywords: parenDropKeywords)
        working = stripDashSuffixes(working, droppedKeywords: dashDropKeywords)

        // After dropping parentheticals, "feat." / "ft." may still appear as bare words.
        working = stripFeaturedFromBareText(working)

        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "'"))
        working = String(working.unicodeScalars.filter { allowed.contains($0) })

        let collapsed = working
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return collapsed
    }

    /// Strip "(feat. X)", "(Remastered 2011)", "(Live at the Apollo)" etc. — but
    /// keep "(Reprise)" if it doesn't contain a drop keyword.
    private static func stripParentheticals(_ s: String, droppedKeywords: [String]) -> String {
        regexReplace(in: s, pattern: #"\(([^()]*)\)"#) { full, groups in
            let inside = groups[0].lowercased()
            return shouldDrop(inside, droppedKeywords: droppedKeywords) ? "" : full
        }
    }

    private static func stripBracketedSuffixes(_ s: String, droppedKeywords: [String]) -> String {
        regexReplace(in: s, pattern: #"\[([^\[\]]*)\]"#) { full, groups in
            let inside = groups[0].lowercased()
            return shouldDrop(inside, droppedKeywords: droppedKeywords) ? "" : full
        }
    }

    /// Strip everything from " - <suffix>" if the suffix matches a drop keyword.
    /// e.g. "Song - Remastered 2011", "Song - Single Version", "Song - Live at Foo".
    private static func stripDashSuffixes(_ s: String, droppedKeywords: [String]) -> String {
        regexReplace(in: s, pattern: #"\s+-\s+(.+)$"#) { full, groups in
            let suffix = groups[0].lowercased()
            return shouldDrop(suffix, droppedKeywords: droppedKeywords) ? "" : full
        }
    }

    private static func stripFeaturedFromBareText(_ s: String) -> String {
        regexReplace(in: s, pattern: #"(?i)\s+(feat\.?|ft\.?|featuring)\s+.+$"#) { _, _ in "" }
    }

    private static func shouldDrop(_ haystack: String, droppedKeywords: [String]) -> Bool {
        droppedKeywords.contains { kw in haystack.contains(kw) }
    }

    /// Keywords that — when found inside "(...)"  or "[...]" — cause the
    /// whole parenthetical to be dropped.
    private static let parenDropKeywords: [String] = [
        "feat.", "feat ", "ft.", "ft ", "featuring",
        "with ", "& ",
        "remaster", "remastered",
        "live at", "live in", "live from", "live -",
        "acoustic", "unplugged",
        "demo", "demo version",
        "single version", "album version", "radio edit", "radio version",
        "explicit", "clean",
        "mono", "stereo",
        "deluxe", "anniversary",
        "extended", "extended mix", "club mix", "edit",
        "instrumental", "karaoke",
        "remix", "mix",
        "version",
        "original", "original mix",
        "bonus", "bonus track",
        "20", "19" // common year prefixes inside parens, e.g. "(2011 Remaster)"
    ]

    private static let dashDropKeywords: [String] = [
        "remaster", "remastered",
        "live at", "live in", "live from", "live version", "live",
        "acoustic", "unplugged",
        "demo",
        "single version", "album version", "radio edit", "radio version",
        "mono", "stereo",
        "deluxe", "anniversary",
        "extended", "club mix", "edit",
        "instrumental", "karaoke",
        "remix", "mix",
        "version",
        "original", "original mix",
        "bonus track",
        "20", "19"
    ]

    /// Regex replace where the replacement is computed from the full match + groups.
    private static func regexReplace(
        in input: String,
        pattern: String,
        replace: (String, [String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return input
        }
        let ns = input as NSString
        var result = ""
        var cursor = 0
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches {
            if m.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            }
            let full = ns.substring(with: m.range)
            var groups: [String] = []
            for i in 1..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += replace(full, groups)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return result
    }
}

/// Levenshtein-based similarity ratio in [0, 1], where 1 = identical strings.
enum StringSimilarity {
    static func ratio(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 1.0 }
        let maxLen = max(a.count, b.count)
        if maxLen == 0 { return 1.0 }
        let dist = levenshtein(a, b)
        return 1.0 - (Double(dist) / Double(maxLen))
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    curr[j - 1] + 1,
                    prev[j] + 1,
                    prev[j - 1] + cost
                )
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }
}
