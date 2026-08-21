import Foundation

/// Turns a GDTF spec string into something a person would say out loud.
///
/// The strings in real files carry a lot that isn't the fixture's name:
/// a manufacturer prefix, a `.gdtf` extension, a revision (`@r3016`), a
/// build variant (`[Bulb=LED]`), an office naming convention
/// (`Custom@PM_Light_…`, `OM - …`), and underscores where spaces belong.
/// `Custom@PM_Light_ACME_Pixel_Line_IP_100.gdtf` is a Pixel Line IP 100 to
/// everyone who has to read it.
enum GDTFSpecName {
    /// Prefixes that describe a filing system rather than a fixture.
    /// Matched *after* underscores become spaces, so they are written that
    /// way — the underscore forms never matched.
    private static let houseNoise = [
        "pm light instr", "pm light", "pm atmos", "pm chauvet", "pm",
        "om -", "om-", "dummy", "light instr", "custom",
    ]

    /// Makers, stripped when they lead the name.
    ///
    /// `PM_Light_ACME_Pixel_Line_IP_100` is a Pixel Line IP 100 — the maker
    /// is already obvious from the fixture and only makes the row longer.
    /// Longest first, so "American DJ" is not left as "DJ".
    private static let makers = [
        "american dj", "clay paky", "look solutions", "chauvet professional",
        "robe lighting", "high end systems", "black light design", "chroma q",
        "acme", "antari", "arri", "astera", "ayrton", "blizzard", "cameo",
        "chauvet", "chromaq", "elation", "glp", "hazebase", "martin",
        "mdg", "robe", "sgm", "tmb", "varilite", "vari-lite", "adj",
    ]

    /// Readable names for a whole document, guaranteed distinct.
    ///
    /// Shortening throws information away, and occasionally two specs in
    /// one file shorten to the same thing — a revision pair, or a
    /// "(TRY 2)" duplicate. Measured: 5 files of 143. Those keep their full
    /// spec, because a name that cannot tell two types apart is worse than
    /// a long one.
    static func readableNames(for specs: [String]) -> [String: String] {
        var byReadable: [String: [String]] = [:]
        for spec in specs { byReadable[readable(spec), default: []].append(spec) }

        var result: [String: String] = [:]
        for (name, owners) in byReadable {
            for spec in owners { result[spec] = owners.count == 1 ? name : spec }
        }
        return result
    }

    /// The product family a readable name belongs to: the name with any
    /// trailing size off it. "Sceptron 320" and "Sceptron 100" are both
    /// Sceptron.
    ///
    /// Only a *purely numeric* trailing token is dropped, and only from the
    /// end. That is deliberately narrow. Matching on the first word instead
    /// would put a MAC Aura and a MAC Viper in one family — same series,
    /// different instruments — and matching loosely anywhere in the name
    /// would pair a Rivale Profile with a Rivale Wash. A length is the one
    /// thing that reliably distinguishes two members of one system rather
    /// than two different fixtures.
    ///
    /// Nil when nothing was stripped, or when what's left is too short to
    /// mean anything — a family of "IP" is not a family.
    static func family(of readableName: String) -> String? {
        var tokens = readableName
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        var stripped = false

        while let last = tokens.last, last.allSatisfy(\.isNumber) {
            tokens.removeLast()
            stripped = true
        }

        guard stripped else { return nil }
        let stem = tokens.joined(separator: " ")
        guard stem.count >= 3 else { return nil }
        return stem.lowercased()
    }

    static func readable(_ spec: String) -> String {
        var text = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return spec }

        if text.lowercased().hasSuffix(".gdtf") { text = String(text.dropLast(5)) }

        // Bracketed variants: [Bulb=LED], (Bulb=LED), [Lens=Clear].
        text = stripBracketed(text, open: "[", close: "]")
        text = stripBracketed(text, open: "(", close: ")")

        // Manufacturer and revision both arrive as @-separated parts. The
        // revision is the tail; the manufacturer is the head.
        var parts = text.components(separatedBy: "@")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if parts.count > 1, isRevision(parts.last ?? "") { parts.removeLast() }
        if parts.count > 1 { parts.removeFirst() }
        text = parts.joined(separator: " ")

        text = text.replacingOccurrences(of: "_", with: " ")

        // House prefixes then the maker, repeatedly: one real file nests
        // two prefixes before the maker even appears.
        var didStrip = true
        while didStrip {
            didStrip = false
            for noise in houseNoise + makers where leads(text, with: noise) {
                text = String(text.dropFirst(noise.count))
                didStrip = true
                break
            }
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        }

        text = text.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))

        // Never hand back nothing: a name that strips to empty was all
        // convention and no fixture, so the original is the better answer.
        return text.isEmpty ? spec : text
    }

    /// A prefix match on a word boundary, so "Acme" doesn't strip out of
    /// "Acmelite" and "PM" doesn't strip out of "PMX".
    private static func leads(_ text: String, with prefix: String) -> Bool {
        let lower = text.lowercased()
        guard lower.hasPrefix(prefix) else { return false }
        guard lower.count > prefix.count else { return true }
        let next = lower[lower.index(lower.startIndex, offsetBy: prefix.count)]
        return next == " " || next == "-" || next == "_"
    }

    /// `r3016`, `v2`, and similar — a version tag, not part of the name.
    private static func isRevision(_ part: String) -> Bool {
        guard part.count >= 2, let first = part.first else { return false }
        guard first == "r" || first == "R" || first == "v" || first == "V" else { return false }
        return part.dropFirst().allSatisfy(\.isNumber)
    }

    private static func stripBracketed(_ text: String, open: Character, close: Character) -> String {
        var result = ""
        var depth = 0
        for character in text {
            if character == open { depth += 1; continue }
            if character == close { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(character) }
        }
        return result.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
