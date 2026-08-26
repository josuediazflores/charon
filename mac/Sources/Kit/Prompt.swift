import SwiftUI
import AppKit

/* ── Prompt ────────────────────────────────────────────────────────────
   operator@halftone:~$ halftone telemetry --follow █

   A shell prompt line. Use it as an empty state, as the affordance above a
   command field, or as the last line of a log -- anywhere the reader should
   understand that something is waiting for input rather than merely idle.
*/

struct Prompt: View {
    var user: String = "operator"
    var host: String = "halftone"
    var path: String = "~"
    /// The command after the sigil. Omit for a bare waiting prompt.
    var command: String? = nil
    var cursor: Bool = false
    /// Hollow cursor, for a prompt that does not have focus.
    var cursorHollow: Bool = false
    /// Render as root: red, ending in `#` rather than `$`.
    var root: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            (Text(user).foregroundStyle(root ? HT.fault : HT.nominal)
                + Text("@").foregroundStyle(HT.inkDim)
                + Text(host).foregroundStyle(HT.signal)
                + Text(":").foregroundStyle(HT.inkDim)
                + Text(path).foregroundStyle(HT.c4))
                .lineLimit(1)
                .fixedSize()

            Text(root ? "#" : "$")
                .foregroundStyle(root ? HT.fault : HT.inkDim)
                .padding(.trailing, HT.cw)
                .fixedSize()

            if let command {
                Text(command)
                    .foregroundStyle(HT.inkBright)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if cursor { BlinkCursor(hollow: cursorHollow) }

            Spacer(minLength: 0)
        }
        .font(HT.body)
        .frame(height: HT.row)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(user)@\(host):\(path)\(root ? "#" : "$") \(command ?? "")"))
    }
}

/// A solid block on a square wave: 530ms lit, 530ms dark, no fade.
///
/// `steps` is the whole point -- an eased fade reads as a web animation, not
/// as a terminal. It is one of exactly two things that move in this console,
/// and it stops under Reduce Motion, where the design system zeroes the blink
/// duration and the block is simply left on.
struct BlinkCursor: View {
    var hollow: Bool = false

    @State private var on = true
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        Group {
            if hollow {
                Rectangle().strokeBorder(HT.prompt, lineWidth: 1)
            } else {
                Rectangle().fill(HT.prompt)
            }
        }
        .frame(width: HT.cw, height: 13)
        .opacity(on ? 1 : 0)
        // text-bottom: the block sits on the line the glyphs sit on.
        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
        .onReceive(
            Timer.publish(every: HT.blinkHalf, on: .main, in: .common).autoconnect()
        ) { _ in
            if reduceMotion { on = true } else { on.toggle() }
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        ) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if reduceMotion { on = true }
        }
        .accessibilityHidden(true)
    }
}
