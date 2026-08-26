import AppKit
import SwiftUI

/* The parsed document, drawn.
 *
 * **One renderer, two variants**, which is the whole reason it is one file. The
 * shapes are identical everywhere markdown appears in this console -- a
 * briefing, a dossier, one of the operator's own documents, an answer from an ask
 * session -- and a second copy of this switch is how two pages start rendering
 * the same paragraph differently.
 *
 * What differs is what a fenced or quoted block IS in each place:
 *
 *   `.plain` -- in a file it is cited material and in an answer it is copy the
 *   CMO drafted. Neither is a control, so both are framed and left alone.
 *
 *   `.draft` -- in a briefing every fenced block is copy-paste material for a
 *   human to send, so the copy control is the point of the block, and the
 *   sentence beside it is the agent's hardest rule restated where the text is
 *   actually picked up.
 *
 * The section rules follow the same split rather than a second flag: only the
 * briefing reader draws a rule over its headings, because only there is a
 * scoped route a page of one section and the rule is what says where a section
 * begins.
 */

enum MarkdownVariant: Equatable {
    case plain
    /// The briefing reader. The date is what a dismissal is keyed on.
    case draft(date: String)
}

struct MarkdownDoc: View {
    var nodes: [MdNode]
    var variant: MarkdownVariant = .plain

    /// The reading column: 78 cells. In the cell token rather than in
    /// characters, so it stays tied to the 7px advance the rest of the grid is
    /// built on.
    static let measure: CGFloat = HT.cw * 78

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(nodes) { node in
                MdBlockView(node: node, variant: variant)
                    // The document opens directly under its rule; every block
                    // after the first carries its own leading.
                    .padding(.top, node.id == nodes.first?.id ? 0 : gap(node.block))
            }
        }
        .frame(maxWidth: MarkdownDoc.measure, alignment: .leading)
    }

    private func gap(_ block: MdBlock) -> CGFloat {
        switch block {
        case .h1: return 0
        case .head(let level, _, _): return level == 2 ? HT.row2 : HT.row
        default: return HT.row
        }
    }
}

private struct MdBlockView: View {
    var node: MdNode
    var variant: MarkdownVariant

    private var drafting: Bool {
        if case .draft = variant { return true }
        return false
    }

    var body: some View {
        switch node.block {
        case .h1(let text):
            // 22px is the one step up the scale allows, and the case is left as
            // the agent wrote it -- the wordmark is lowercase on purpose and
            // uppercasing it here would overrule the brand from the wrong file.
            MdInline(text: text, font: HT.lead, ink: HT.inkBright)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .head(let level, let text, _):
            VStack(alignment: .leading, spacing: 0) {
                // Solid for a section, dashed for an item inside one: the depth
                // has to survive being printed 1-bit, and at one type size the
                // rule is the only channel left to carry it.
                if drafting { Rule(variant: level == 2 ? .solid : .dashed) }
                MdInline(text: text.uppercased(), ink: HT.inkBright)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .p(let text):
            MdInline(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .ul(let items):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    // The marker keeps the first cell, so a wrapped line hangs
                    // under the text rather than under the dot.
                    HStack(alignment: .top, spacing: HT.cw) {
                        Text("·")
                            .font(HT.body)
                            .foregroundStyle(HT.inkDim)
                            .frame(width: HT.cw, alignment: .leading)
                        MdInline(text: item)
                    }
                    .padding(.top, HT.s1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        case .hr:
            Rule()

        case .code(let body), .quote(let body):
            // The house format: real briefings quote their drafts rather than
            // fencing them, so the two draw identically.
            MdCodeBlock(text: body, heading: node.heading, variant: variant)
        }
    }
}

// MARK: - inline spans

/// One run of text with its inline marks resolved.
///
/// Built as an `AttributedString` rather than as concatenated `Text` values so
/// a link is a real link -- a run the window server will open -- instead of a
/// coloured span that does nothing when clicked.
struct MdInline: View {
    var text: String
    var font: Font = HT.body
    var ink: Color = HT.ink

    var body: some View {
        Text(attributed)
            .font(font)
            .foregroundStyle(ink)
            .lineSpacing(font == HT.lead ? 4 : 7)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for span in Markdown.inline(text) {
            switch span {
            case .text(let s):
                out.append(AttributedString(s))

            case .code(let s):
                // The raised surface, the way a terminal sets a literal apart.
                // No hue: this is a texture, not a state.
                var run = AttributedString(s)
                run.foregroundColor = HT.inkBright
                run.backgroundColor = HT.c0
                out.append(run)

            case .strong(let s):
                // Ink, never weight. Synthetic bold smears a bitmap face, which
                // is why every font-weight in this system is 400.
                var run = AttributedString(s)
                run.foregroundColor = HT.inkBright
                out.append(run)

            case .link(let label, let href):
                var run = AttributedString(label)
                run.underlineStyle = .single
                // Only where there is somewhere to go. An in-document `#`
                // anchor is a web address for a page this app does not have,
                // and a link that did nothing would be worse than plain text.
                if let url = URL(string: href),
                   let scheme = url.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    run.link = url
                }
                run.foregroundColor = HT.ink
                out.append(run)
            }
        }
        return out
    }
}

// MARK: - the fenced block

/// A fenced block, and -- in a briefing -- the strip that says what it is not.
private struct MdCodeBlock: View {
    /// The block's own text. Named `text` and not `body` because `body` is the
    /// view.
    var text: String
    /// The nearest `###` above this block, which is the draft's only name.
    var heading: String?
    var variant: MarkdownVariant

    @State private var copied = false
    @State private var copyToken = 0

    private var date: String? {
        if case .draft(let date) = variant { return date }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text)
                .font(HT.body)
                .lineSpacing(7)
                .foregroundStyle(HT.inkBright)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HT.cw)
                .padding(.vertical, HT.s2)

            if let date {
                Rectangle().fill(HT.lineFaint).frame(height: 1)
                HStack(spacing: HT.cw2) {
                    HTButton(title: copied ? "copied" : "copy",
                             variant: .ghost, size: .sm, caps: true) {
                        copy()
                    }
                    // Next to COPY because they are the two things to do with a
                    // draft: send it yourself, or decide it is not worth
                    // sending. A block with no heading of its own has no name,
                    // and something with no name cannot be dismissed by name --
                    // offering the control anyway would write a line no restore
                    // could ever find.
                    if let title = MdCodeBlock.draftTitle(heading) {
                        DismissControl(
                            entry: Dismissal(kind: .draft, title: title,
                                             lane: nil, date: date),
                            terse: true)
                    }
                    Text("draft only · the cmo never sends")
                        .font(HT.body)
                        .foregroundStyle(HT.inkDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, HT.cw)
            }
        }
        .overlay { Rectangle().strokeBorder(HT.lineFaint, lineWidth: 1) }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        copyToken &+= 1
        let mine = copyToken
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copyToken == mine { copied = false }
        }
    }

    /// A draft's name, from the heading above it.
    ///
    /// Briefings letter their drafts -- `### A. Reddit reply · r/example` -- and the
    /// letter is an ordinal within one day's document, not part of what the
    /// draft IS. Dismissal is matched on the title, so keeping the letter would
    /// make "the same draft" a different thing the moment the agent reordered
    /// its section.
    static func draftTitle(_ heading: String?) -> String? {
        guard let heading else { return nil }
        var text = Substring(heading)
        // `/^[A-Za-z][.)]\s+/`
        if let first = text.first, first.isLetter {
            let rest = text.dropFirst()
            if let mark = rest.first, mark == "." || mark == ")" {
                let after = rest.dropFirst()
                if let space = after.first, space == " " || space == "\t" {
                    text = after.drop { $0 == " " || $0 == "\t" }
                }
            }
        }
        let out = text.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? nil : out
    }
}
