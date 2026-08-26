import Foundation

/* The markdown subset a briefing is actually written in -- ported line for line
 * from the web console's markdown renderer.
 *
 * Hand-rolled, and deliberately not a dependency. A parser would be several
 * times the size of this whole feature to read a document that only ever
 * contains headings, paragraphs, bullets, links, bold, rules and fenced drafts
 * -- and every extra construct it brought (tables, images, raw HTML,
 * footnotes) would be a shape this design system has no rendering for, so it
 * would arrive as something to suppress rather than something to draw.
 *
 * Everything outside the subset is left as the literal text it was written as.
 * That is the one failure mode worth having: a briefing is prose an agent wrote
 * at 6am, and showing an unknown construct verbatim keeps the sentence
 * readable, where guessing at it would not.
 */

enum MdBlock: Equatable {
    case h1(text: String)
    /// `##` and `###`. Both carry an id, because both are jump targets.
    case head(level: Int, text: String, id: String)
    case p(text: String)
    case ul(items: [String])
    case hr
    case code(body: String)
    /// A `>` blockquote. In a briefing this is how the agent sets off a draft
    /// (the real briefings quote their drafts rather than fencing them), so the
    /// reader draws it exactly like a fence.
    case quote(body: String)
}

/// One block with its position in the document. Two blocks can honestly be the
/// same text, and SwiftUI still has to tell them apart, so the ordinal rides
/// alongside rather than inside the case payloads -- which would otherwise put
/// an index into every pattern match in the renderer.
struct MdNode: Equatable, Identifiable {
    var id: Int
    var block: MdBlock
    /// The nearest `###` above this block, cleared at every section boundary.
    /// Only the draft blocks have any use for it, and only because that heading
    /// is the draft's only name.
    var heading: String?
}

enum Markdown {

    // MARK: - the slug

    /// An id from the heading text. Emoji and punctuation drop out, so
    /// `## ✍️ drafts ready` addresses as `md-drafts-ready`.
    static func slug(_ text: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in text.lowercased().unicodeScalars {
            if CharacterSet.letters.contains(ch) || CharacterSet.decimalDigits.contains(ch) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(ch)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "section" : out
    }

    /// Two sections can honestly share a name. The suffix keeps the second one
    /// addressable rather than silently pointing at the first.
    private static func uniqueId(_ text: String, _ taken: inout [String: Int]) -> String {
        let base = slug(text)
        let n = (taken[base] ?? 0) + 1
        taken[base] = n
        return n == 1 ? "md-\(base)" : "md-\(base)-\(n)"
    }

    // MARK: - line tests
    //
    // The five regexes from the reference, written out as scanners. A regex
    // engine here would be five patterns whose behaviour has to be checked
    // against JavaScript's anyway; these are the same tests with the answers
    // spelled out.

    private static func lstrip(_ s: String) -> Substring {
        s.drop { $0 == " " || $0 == "\t" }
    }

    /// `/^\s*```/`
    private static func isFence(_ line: String) -> Bool {
        lstrip(line).hasPrefix("```")
    }

    /// `/^\s*-{3,}\s*$/`
    private static func isRule(_ line: String) -> Bool {
        let body = line.trimmingCharacters(in: .whitespaces)
        return body.count >= 3 && body.allSatisfy { $0 == "-" }
    }

    /// `/^(#{1,6})\s+(.*)$/` -- note the absence of `\s*`: a heading's hashes
    /// are in column one or it is not a heading.
    private static func heading(_ line: String) -> (level: Int, text: String)? {
        var hashes = 0
        var i = line.startIndex
        while i < line.endIndex, line[i] == "#", hashes < 6 {
            hashes += 1
            i = line.index(after: i)
        }
        guard hashes >= 1, i < line.endIndex, line[i] == " " || line[i] == "\t" else { return nil }
        var text = String(line[i...]).trimmingCharacters(in: .whitespaces)
        // `replace(/\s+#+$/, '')`: closing hashes are decoration.
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return (hashes, text)
    }

    /// `/^\s*[-*]\s+(.*)$/`
    private static func bullet(_ line: String) -> String? {
        let rest = lstrip(line)
        guard let mark = rest.first, mark == "-" || mark == "*" else { return nil }
        let after = rest.dropFirst()
        guard let next = after.first, next == " " || next == "\t" else { return nil }
        return String(after.drop { $0 == " " || $0 == "\t" })
    }

    /// `/^\s*>[ ]?(.*)$/`
    private static func quote(_ line: String) -> String? {
        let rest = lstrip(line)
        guard rest.hasPrefix(">") else { return nil }
        var body = rest.dropFirst()
        if body.first == " " { body = body.dropFirst() }
        return String(body)
    }

    /// `/^\s*(\d+[.)]|\|)\s/` -- a line opening with a marker this reader does
    /// not draw: an ordered-list number, a table pipe.
    ///
    /// They stay literal text, which is the rule for everything outside the
    /// subset. What they must NOT do is get reflowed: the paragraph joiner
    /// exists to put hard-wrapped prose back together, and running `1.` `2.`
    /// `3.` into one sentence is how "renders as plain text" turns into
    /// unreadable.
    private static func isLiteral(_ line: String) -> Bool {
        var rest = lstrip(line)
        if rest.first == "|" {
            let after = rest.dropFirst()
            return after.first == " " || after.first == "\t"
        }
        var digits = 0
        while let c = rest.first, c.isNumber {
            digits += 1
            rest = rest.dropFirst()
        }
        guard digits > 0, let mark = rest.first, mark == "." || mark == ")" else { return false }
        let after = rest.dropFirst()
        return after.first == " " || after.first == "\t"
    }

    // MARK: - the pass

    /// One pass, line by line.
    static func parse(_ src: String) -> [MdNode] {
        let lines = src
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var out: [MdBlock] = []
        var taken: [String: Int] = [:]
        var para: [String] = []
        var list: [String] = []

        func closePara() {
            if !para.isEmpty { out.append(.p(text: para.joined(separator: " "))) }
            para = []
        }
        func closeList() {
            if !list.isEmpty { out.append(.ul(items: list)) }
            list = []
        }
        func close() {
            closePara()
            closeList()
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]

            // A fence suspends every other rule: a draft is quoted text, and a
            // `#` or a `-` inside one is a character the reader is meant to
            // copy, not syntax.
            if isFence(line) {
                close()
                var body: [String] = []
                i += 1
                while i < lines.count, !isFence(lines[i]) {
                    body.append(lines[i])
                    i += 1
                }
                out.append(.code(body: body.joined(separator: "\n")))
                i += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                close()
                i += 1
                continue
            }

            // Before the bullet test: `---` is a rule and `- x` is an item, and
            // only the space tells them apart.
            if isRule(line) {
                close()
                out.append(.hr)
                i += 1
                continue
            }

            if let head = heading(line) {
                close()
                if head.level == 1 {
                    out.append(.h1(text: head.text))
                } else {
                    // Four hashes and deeper fold into `###`. The document has
                    // two levels of structure and a third would need a third
                    // heading treatment, which at one type size is a
                    // distinction the page cannot draw.
                    out.append(.head(level: head.level == 2 ? 2 : 3,
                                     text: head.text,
                                     id: uniqueId(head.text, &taken)))
                }
                i += 1
                continue
            }

            if let item = bullet(line) {
                closePara()
                list.append(item)
                i += 1
                continue
            }

            // Contiguous `>` lines are one draft: a bare `>` is the blank line
            // between the draft's paragraphs, so it stays a break inside the
            // block rather than ending it.
            if let first = quote(line) {
                close()
                var body: [String] = [first]
                while i + 1 < lines.count, let more = quote(lines[i + 1]) {
                    i += 1
                    body.append(more)
                }
                out.append(.quote(
                    body: body.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)))
                i += 1
                continue
            }

            if isLiteral(line) {
                close()
                out.append(.p(text: line.trimmingCharacters(in: .whitespaces)))
                i += 1
                continue
            }

            // A wrapped bullet is the common case in a hand-written briefing,
            // and the continuation line looks exactly like a paragraph. Inside
            // a list it belongs to the item above it; markdown calls this lazy
            // continuation, and without it every wrapped bullet splits into a
            // one-item list and an orphan sentence.
            if !list.isEmpty {
                list[list.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
                i += 1
                continue
            }

            para.append(line.trimmingCharacters(in: .whitespaces))
            i += 1
        }

        close()
        return nodes(out)
    }

    /// The blocks with their ordinals and their standing `###`.
    ///
    /// The heading is cleared at every section boundary: a heading from the
    /// section before this one is not this block's title, and titling a draft
    /// with the wrong item is worse than leaving it un-dismissable.
    private static func nodes(_ blocks: [MdBlock]) -> [MdNode] {
        var current: String?
        return blocks.enumerated().map { index, block in
            switch block {
            case .h1: current = nil
            case .head(let level, let text, _): current = level == 3 ? text : nil
            default: break
            }
            return MdNode(id: index, block: block, heading: current)
        }
    }

    // MARK: - headings, for the scoping rules

    struct HeadingRef: Equatable {
        var id: String
        var text: String
    }

    static func headings(_ nodes: [MdNode]) -> [HeadingRef] {
        nodes.compactMap { node in
            if case .head(_, let text, let id) = node.block {
                return HeadingRef(id: id, text: text)
            }
            return nil
        }
    }

    // MARK: - inline spans

    enum Span: Equatable {
        case text(String)
        case code(String)
        case strong(String)
        case link(label: String, href: String)
    }

    /// `` /`([^`]+)`|\*\*([^*]+?)\*\*|\[([^\]]+)\]\(([^)\s]+)\)/g ``, in one
    /// scan. Code wins over bold and links, because the point of a code span is
    /// that what is inside it is not syntax.
    static func inline(_ text: String) -> [Span] {
        let s = Array(text)
        var out: [Span] = []
        var plain = ""
        var i = 0

        func flush() {
            if !plain.isEmpty { out.append(.text(plain)) }
            plain = ""
        }

        while i < s.count {
            if s[i] == "`", let close = index(of: "`", in: s, from: i + 1), close > i + 1 {
                flush()
                out.append(.code(String(s[(i + 1)..<close])))
                i = close + 1
                continue
            }

            if s[i] == "*", i + 1 < s.count, s[i + 1] == "*",
               let star = index(of: "*", in: s, from: i + 2),
               star > i + 2, star + 1 < s.count, s[star + 1] == "*" {
                flush()
                out.append(.strong(String(s[(i + 2)..<star])))
                i = star + 2
                continue
            }

            if s[i] == "[", let bracket = index(of: "]", in: s, from: i + 1),
               bracket > i + 1, bracket + 1 < s.count, s[bracket + 1] == "(",
               let paren = index(of: ")", in: s, from: bracket + 2), paren > bracket + 2 {
                let href = String(s[(bracket + 2)..<paren])
                if !href.contains(where: { $0.isWhitespace }) {
                    flush()
                    out.append(.link(label: String(s[(i + 1)..<bracket]), href: href))
                    i = paren + 1
                    continue
                }
            }

            plain.append(s[i])
            i += 1
        }

        flush()
        return out
    }

    private static func index(of needle: Character, in s: [Character], from: Int) -> Int? {
        var i = from
        while i < s.count {
            if s[i] == needle { return i }
            i += 1
        }
        return nil
    }
}
