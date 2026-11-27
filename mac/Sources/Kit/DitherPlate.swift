import AppKit
import SwiftUI
import CoreGraphics

/* ── DitherPlate ───────────────────────────────────────────────────────
   One-bit rendering of a generated field, at a chunky dot size.

   **Static.** The web component repaints from a canvas on every prop change
   and the dot grid is what it is; here the field is painted once per size and
   held as an image, which is build decision 5. Nothing about it moves, and
   nothing about it is random -- seed 7, every launch.

   Decorative. It has no reading in it, which is exactly why it can be the one
   block on the Overview that is only texture.
*/

struct DitherPlate: View {
    var pattern: DitherPattern = .sphere
    var algorithm: DitherAlgorithm = .atkinson
    /// Rendered dot size, in points. Higher is chunkier and cheaper to look at.
    var scale: CGFloat = 3
    var threshold: Float = 128
    var brightness: Float = 0
    var contrast: Float = 1
    var seed: UInt32 = 7
    /// Box aspect, width / height.
    var aspect: CGFloat = 16 / 9
    var inverted: Bool = false
    /// Text block set into the bottom-left corner. Newlines are kept.
    var caption: String? = nil

    @State private var plate: CGImage?
    @State private var boxWidth: CGFloat = 0

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let plate {
                    Image(decorative: plate, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .antialiased(false)
                } else {
                    // Standing in for the plate until it is rendered, so the
                    // box does not flash the page through a hole the shape of
                    // an image that is about to be opaque.
                    HT.groundMask
                }
            }
            .overlay(alignment: .bottomLeading) { captionBlock }
            .clipped()
            .htMeasureWidth { boxWidth = $0 }
            .onChange(of: boxWidth) { render() }
            .onAppear { render() }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var captionBlock: some View {
        if let caption {
            Text(caption)
                .font(HT.body)
                .foregroundStyle(HT.inkBright)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, HT.cw)
                .padding(.vertical, HT.s1)
                // A mask: the caption is legible because it puts the plate out.
                .background(HT.groundMask)
                .padding(HT.cw)
        }
    }

    private func render() {
        guard boxWidth > 0 else { return }
        let w = Swift.max(1, Int((boxWidth / scale).rounded()))
        let h = Swift.max(1, Int((CGFloat(w) / aspect).rounded()))
        if let plate, plate.width == w, plate.height == h { return }

        var lum = [Float](repeating: 0, count: w * h)
        Dither.paintField(&lum, w, h, pattern, seed)
        if brightness != 0 || contrast != 1 { Dither.adjust(&lum, brightness, contrast) }
        Dither.apply(&lum, w, h, algorithm, threshold)

        var bytes = [UInt8](repeating: 0, count: w * h)
        for i in 0..<lum.count {
            let lit = lum[i] > 127
            bytes[i] = (lit != inverted) ? 255 : 0
        }
        plate = DitherPlate.image(from: bytes, width: w, height: h)
    }

    /// An 8-bit grey buffer as a CGImage. One byte per dot, drawn with no
    /// interpolation, so the dots stay square at any size the panel takes.
    static func image(from bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, bytes.count == width * height else { return nil }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }

    /// The same, in colour and on transparent. Four bytes per dot, premultiplied
    /// -- which for a plate that is either an opaque dot or nothing at all means
    /// the lit dots carry their own colour and the rest are four zeroes.
    static func image(from bytes: [UInt8], width: Int, height: Int,
                      channels: Int) -> CGImage? {
        guard channels == 4, width > 0, height > 0,
              bytes.count == width * height * 4 else { return nil }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }
}

/* ── DitherPane ────────────────────────────────────────────────────────
   The same dither, filling a pane instead of standing in a box, and printed
   in two inks.

   **The pane is the argument, and that is the whole difference.** `DitherPlate`
   fits an aspect box and lets the dot be whatever the box makes it; the chat
   landing wants the opposite -- a fixed dot over however much room the window
   happens to give it. So the grid is `ceil(pane / scale)` dots drawn at exactly
   `scale` points each: a plate may crop by up to one dot at the far edge and
   never stretches. A single plate scaled to fit two different panes is the one
   thing this file will not do; it is how a 3pt dot becomes 1.5pt.

   **Two inks, split on the field's own value.** The dither throws the value
   away -- a dot is on or it is off -- so the plate would be one flat colour and
   the lobe at the top would read as a denser patch of the same grey rather than
   as light. Keeping the pre-dither value and printing the dots above a
   threshold in a second ink puts the tone back without putting a second
   grey-level anywhere near the type: still one-bit per dot, still square, and
   the core of the glow separates from its own floor.

   **Static, and this branch means it.** Painted once per size, per family, and
   never again. Nothing here has a timer, an animation or a random number in it.
*/
struct DitherPane: View {
    var pattern: DitherPattern = .glow
    var algorithm: DitherAlgorithm = .bayer
    /// Rendered dot size, in points. One dot, `scale` points square, 1:1.
    var scale: CGFloat = 3
    var seed: UInt32 = 7
    /// Where the two inks part, on the field's own 0..1 scale. A lit dot at or
    /// above this is `ink`; one below it is `dim`.
    var split: Double = 0.22
    /// The lit ink and the field ink. Both are read off the ground family at
    /// render time rather than stated, so all five families keep working.
    var ink: Color = HT.inkMid
    var dim: Color = HT.line

    @State private var plate: CGImage?
    @State private var grid: CGSize = .zero
    @State private var pane: CGSize = .zero
    /// What the plate on screen was painted for. The size and the family, so a
    /// pane that did not move does not repaint and a family that did, does.
    @State private var painted: String = ""

    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                if let plate {
                    Image(decorative: plate, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .antialiased(false)
                        .frame(width: grid.width * scale, height: grid.height * scale)
                }
            }
            .clipped()
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { size(geo.size) }
                        .onChange(of: Ground.family) { render() }
                        .onChange(of: Ground.shared.glass) { render() }
                        .onChange(of: geo.size) { _, next in size(next) }
                }
            )
            .accessibilityHidden(true)
    }

    private func size(_ next: CGSize) {
        pane = next
        render()
    }

    private func render() {
        guard pane.width > 0, pane.height > 0, scale > 0 else { return }
        let w = Swift.max(1, Int((pane.width / scale).rounded(.up)))
        let h = Swift.max(1, Int((pane.height / scale).rounded(.up)))
        let key = "\(w)x\(h)/\(Ground.family.rawValue)/\(Ground.shared.glass)"
        if key == painted { return }
        painted = key

        var lum = [Float](repeating: 0, count: w * h)
        Dither.paintField(&lum, w, h, pattern, seed)
        // The field, kept before the dither eats it. This is the whole of the
        // two-tone: what is drawn is the one-bit answer, and which ink draws it
        // is the value that answer came from.
        let field = lum
        Dither.apply(&lum, w, h, algorithm, 128)

        let hot = DitherPane.rgb(ink)
        let cold = DitherPane.rgb(dim)
        let edge = Float(split * 255)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<lum.count where lum[i] > 127 {
            let c = field[i] >= edge ? hot : cold
            let at = i * 4
            bytes[at] = c.0
            bytes[at + 1] = c.1
            bytes[at + 2] = c.2
            bytes[at + 3] = 255
        }
        grid = CGSize(width: CGFloat(w), height: CGFloat(h))
        plate = DitherPlate.image(from: bytes, width: w, height: h, channels: 4)
    }

    /// A token as three sRGB bytes. Through `NSColor` because that is the one
    /// route that resolves a SwiftUI colour to components; sRGB by name because
    /// the palettes are stated in sRGB hex and a plate in the display's own
    /// space would print a different colour from the type beside it.
    private static func rgb(_ color: Color) -> (UInt8, UInt8, UInt8) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return (255, 255, 255) }
        return (UInt8(Swift.max(0, Swift.min(255, c.redComponent * 255)).rounded()),
                UInt8(Swift.max(0, Swift.min(255, c.greenComponent * 255)).rounded()),
                UInt8(Swift.max(0, Swift.min(255, c.blueComponent * 255)).rounded()))
    }
}
