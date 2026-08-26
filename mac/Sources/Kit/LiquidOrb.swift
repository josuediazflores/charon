import AppKit
import MetalKit
import SwiftUI
import simd

/* ── LiquidOrbView ─────────────────────────────────────────────────────
      ▪ ▪▫▪ ▫▪
    ▪▫▪ ▪▪▫ ▪▫▪
   ▪▪ ▫▪▪ ▪▫ ▪▪▫
    ▫▪ ▪▫▪▪ ▫▪▪
      ▪▫ ▪▪▫

   `OrbView`, upgraded to the real thing.

   Same contract, same footprint, same job: `activity` is the only prop that
   carries meaning, the ink is passed rather than derived, the art is hidden
   from assistive tech and the word underneath does the reporting. What changes
   is what draws it. Instead of a field sampled per character cell and
   quantised to letterforms, this is a GPU fluid -- the voiceWave preset of
   `LiquidOrb.metal`, a slow membrane wave inside a dark glass sphere --
   pixelated to blocks, thresholded against an 8x8 Bayer matrix and printed in
   one flat ink. Not a colour of it survives to the screen. See the shader's own
   header for what is vendored and why the screen stage lives in the same file.

   Picked by the user on 2026-08-23 out of an eleven-preset, ten-pattern fitting
   session, and ported here from the web console's orb renderer so the
   Mac and the browser draw the same assistant. **The two must not drift.** The
   numbers below are that file's numbers; a change to either is a change to
   both.

   **The character orb is the floor, not an apology.** It draws whenever there
   is no Metal, when the shader will not compile, and for the fraction of a
   second at first appearance before the pipeline exists. It is the same orb at
   the same size, so nothing on the page moves when the swap happens.
*/

// MARK: - the field recipe
//
// **The one place in this app where a raw hex is legal, and these are not
// colours.** They are a luminance field: twelve stops the fluid shades itself
// with, which decide where a dot falls and never what anything looks like. The
// glow slot is the single exception, and it is overwritten every frame with
// the `ink` the caller passed. Nothing here is a UI colour, nothing here is a
// token, and nothing here may be reused as either.

/// voiceWave, amber variant, exactly as the web console carries it.
private enum Field {
    static let radius: Float = 0.7
    static let zoom: Float = 0.36
    static let warp: Float = 2.6
    static let ridgeAmt: Float = 0.46
    static let sharp: Float = 2.2
    static let shade: Float = 0.08
    static let sheen: Float = 0.22
    static let gloss: Float = 0.36
    static let glassOpacity: Float = 0.48
    static let shellMidAlpha: Float = 0.18
    static let shellEdgeAlpha: Float = 0.2
    static let exposure: Float = 1.35
    /// The flow the shader switches on. `flowIndex` in the web preset, `style`
    /// in the uniform block, 19 either way.
    static let flowIndex: Float = 19
    static let edgeSoftness: Float = 0.005
    static let bandDensity: Float = 2
    static let chromaticShift: Float = 0.42
    static let metalScale: Float = 0.77
    static let metalStretch: Float = 0.23
    static let metalAngle: Float = 65
    static let metalRoughness: Float = 0.22
    static let metalDepth: Float = 0.25
}

/// How fast the membrane moves at rest. The upstream preset's own speed;
/// activity multiplies it, never replaces it.
private let baseSpeed: Double = 0.95

/// A field stop, as the shader wants it. Not `Color`: these never reach a view,
/// and routing them through the colour system would put them one appearance
/// change away from being resolved as UI.
private func stop(_ hex: UInt32) -> SIMD4<Float> {
    SIMD4<Float>(
        Float((hex >> 16) & 0xff) / 255,
        Float((hex >> 8) & 0xff) / 255,
        Float(hex & 0xff) / 255,
        1
    )
}

// MARK: - the uniform block

/* Field for field, `struct Uniforms` in `LiquidOrb.metal`.
 *
 * **The Metal struct is the authority, not this one.** The order below is the
 * order the shader declares, which is what makes the two agree: Swift lays a
 * struct of trivial fields out in declaration order at natural alignment, and
 * MSL does the same, so `float2` at 0, thirty scalars behind it and the first
 * `float4` landing on 128 comes out identical on both sides. It is exactly 512
 * bytes, and the assert in `draw` says so out loud, because the failure mode of
 * getting this wrong is not a crash -- it is a sphere that renders slightly
 * wrong forever and nobody can say why.
 *
 * Small enough for `setFragmentBytes`, so there is no buffer to manage and no
 * frame to synchronise against.
 */
private struct OrbUniforms {
    var size = SIMD2<Float>(1, 1)
    /// Pre-integrated on the CPU. See `Coordinator.draw`.
    var time: Float = 0
    /// **Stays 1, always.** The shader multiplies `time * speed`, so a moving
    /// speed replays the whole history at the new rate and the membrane jumps
    /// every time the presence word changes. Pace lives in the integration.
    var speed: Float = 1
    var radius = Field.radius
    var zoom = Field.zoom
    var warp = Field.warp
    var ridgeAmt = Field.ridgeAmt
    var sharp = Field.sharp
    var shade = Field.shade
    var sheen = Field.sheen
    var gloss = Field.gloss
    var shellMidAlpha = Field.shellMidAlpha
    var shellEdgeAlpha = Field.shellEdgeAlpha
    var exposure = Field.exposure
    var style = Field.flowIndex
    var edgeSoftness = Field.edgeSoftness
    /// Off. The rim glow is the one part of the preset that would put light
    /// outside the silhouette, and outside the silhouette is the page.
    var edgeGlow: Float = 0
    /// Zero: the palette ramp below is the vendored block's, and this flow
    /// never reads it.
    var paletteCount: Float = 0
    var glassEnabled: Float = 1
    var glassOpacity = Field.glassOpacity
    /// Written per frame from activity.
    var contourDeform: Float = 0.1
    var bandDensity = Field.bandDensity
    var chromaticShift = Field.chromaticShift
    var metalScale = Field.metalScale
    var metalStretch = Field.metalStretch
    var metalAngle = Field.metalAngle
    var metalOffset: Float = 0
    var metalPhase: Float = 0
    var metalEvolution: Float = 1
    var metalRoughness = Field.metalRoughness
    var metalDepth = Field.metalDepth

    var colorA = stop(0x0E0703)
    var colorB = stop(0xE8752C)
    var colorC = stop(0xFFC352)
    var colorD = stop(0xB34A16)
    var highlightColor = stop(0xFFE9C8)
    var shellInner = stop(0xFFFFFF)
    var shellMid = stop(0xFFB86B)
    var shellEdge = stop(0xFF9A4A)
    var sheenColor = stop(0xFFF4E2)
    var specColor = stop(0xFFE0B8)
    /// Never composited -- the layer is transparent and the app's ground shows
    /// through. Written because the struct has the slot.
    var canvasColor = stop(0x000000)
    /// **The ink, and the only slot that is one.** Overwritten every frame with
    /// the caller's colour; the value here is just the web preset's default.
    var glowColor = stop(0xE8752C)

    /// The legacy palette ramp the vendored uniform block requires. This flow
    /// never reads a stop of it, but the struct is twenty-four `float4`s and
    /// every one has to be written or the tail is uninitialised memory.
    var paletteStop0 = stop(0xF7FBFF)
    var paletteStop1 = stop(0xEFF6FD)
    var paletteStop2 = stop(0xE0EEF9)
    var paletteStop3 = stop(0xD4E6F7)
    var paletteStop4 = stop(0xBBD5F3)
    var paletteStop5 = stop(0xA6C7F0)
    var paletteStop6 = stop(0x87B0EB)
    var paletteStop7 = stop(0x6F9EE8)
    var paletteStop8 = stop(0x6F9EE8)
    var paletteStop9 = stop(0x6F9EE8)
    var paletteStop10 = stop(0x6F9EE8)
    var paletteStop11 = stop(0x6F9EE8)
}

// MARK: - the device, once

/* The GPU objects, built once for the process and shared by every orb on the
 * page -- of which there is currently one.
 *
 * **The shader is compiled at runtime, from a bundled `.metal` file, on
 * purpose.** Xcode 26 moved the Metal compiler into a separately downloaded
 * component (`xcodebuild -downloadComponent MetalToolchain`), so a `.metal`
 * file in the Compile Sources phase makes the whole app un-buildable on a
 * machine that has not fetched it -- for one decorative sphere. The runtime
 * compiler is part of the OS and is always there. The cost is one
 * `makeLibrary(source:)`, measured at ~240ms cold and ~800ms including the
 * pipeline; the OS caches both by source hash, so it is ~0ms on every launch
 * after the first for a given build.
 *
 * That is why this is off the main thread and why the character orb draws until
 * it lands: a cold start must not beachball the Jarvis tab, and a swap nobody
 * ever sees is cheaper than a spinner everybody does.
 */
private enum LiquidOrbGPU {

    struct Ready {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
    }

    /// `nil` means the character orb has the job. Started on first `await`,
    /// awaited by every later caller, run exactly once.
    static func load() async -> Ready? { await job.value }

    private static let job = Task<Ready?, Never>.detached(priority: .userInitiated) {
        build()
    }

    private static func build() -> Ready? {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return fail("no Metal device")
        }
        guard let url = Bundle.main.url(forResource: "LiquidOrb", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            return fail("LiquidOrb.metal is not in the bundle")
        }
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard let vertex = library.makeFunction(name: "vs_main"),
                  let fragment = library.makeFunction(name: "fs_bayer")
            else {
                return fail("shader compiled without vs_main/fs_bayer")
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertex
            desc.fragmentFunction = fragment
            // No blend state: the orb is the only thing in the pass, it writes
            // premultiplied, and the layer composites it over the window.
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipeline = try device.makeRenderPipelineState(descriptor: desc)
            guard let queue = device.makeCommandQueue() else {
                return fail("no command queue")
            }
            return Ready(device: device, queue: queue, pipeline: pipeline)
        } catch {
            return fail(error.localizedDescription)
        }
    }

    /// **Says so once, in the log.** Every Mac this app runs on has Metal, so
    /// this path is correctness rather than expectation -- and a fallback that
    /// happened silently cost the web console a debugging session the day it
    /// shipped.
    private static func fail(_ why: String) -> Ready? {
        NSLog("jarvis orb: liquid render unavailable (\(why)); character orb on duty")
        return nil
    }
}

// MARK: - the view

struct LiquidOrbView: View {
    /// How agitated the surface is, 0 to 1. The same number `OrbView` takes.
    var activity: Double = 0
    /// One flat colour, and the only colour the reader sees. Passed rather than
    /// derived from a tone on purpose: the caller decides what the colour MEANS
    /// (the Jarvis hero maps it off `Presence` -- gold at rest, blue for a turn
    /// in flight, red for a fault) and this file has no opinion about any of it,
    /// exactly as it has none about what "queued" means to `activity`. A change
    /// of ink morphs (~1/3 s, in the coordinator) rather than cutting.
    var ink: Color = HT.ink
    var label: String = "Assistant presence"

    @State private var gpu: LiquidOrbGPU.Ready?
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Whether this window is on a screen at all. Read from the environment for
    /// the reason `GlobeView` gives.
    @Environment(\.consoleVisible) private var visible

    /// The character orb's exact footprint, arrived at the character orb's way:
    /// 28 cells across, and the rows that follow from the 7x11 em box. **The
    /// 198 is not a typo and not a rounding slip** -- taking the same number
    /// rather than a square 196 is what stops the wordmark under the orb
    /// hopping two pixels the moment the renderer swaps.
    private var cols: Int { 28 }
    private var side: CGFloat { CGFloat(cols) * HT.cw }
    private var tall: CGFloat { CGFloat(Swift.max(1, Int(((Double(cols) * 7) / 11).rounded()))) * 11 }

    var body: some View {
        Group {
            if let gpu {
                LiquidOrbSurface(
                    gpu: gpu,
                    activity: Swift.min(1, Swift.max(0, activity)),
                    ink: LiquidOrbSurface.rgb(ink),
                    still: reduceMotion,
                    running: visible
                )
                .frame(width: side, height: tall)
            } else {
                OrbView(cols: cols, activity: activity, ink: ink, label: label)
            }
        }
        // Runs once per appearance and resolves instantly after the first: the
        // work behind it is a single shared Task whose value is already there.
        .task { gpu = await LiquidOrbGPU.load() }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        ) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - the surface

/* The Metal view, and the frame loop.
 *
 * **Nothing here is a SwiftUI animation and nothing here may become one.** The
 * house rule is that the console's only motion is explicitly stepped or
 * explicitly driven; this is the second kind, a display-link loop that
 * integrates its own clock, and it is the whole of the movement on this page.
 *
 * Every prop arrives through the coordinator rather than through a rebuild.
 * Presence changes several times a minute and the ink is read from a `Color`
 * that can resolve differently under an appearance change; a representable that
 * tore down its device for either would spend 800ms rebuilding a pipeline to
 * draw the same sphere a shade later.
 */
private struct LiquidOrbSurface: NSViewRepresentable {
    let gpu: LiquidOrbGPU.Ready
    let activity: Double
    let ink: SIMD3<Float>
    let still: Bool
    let running: Bool

    /// The ink as the shader wants it: the sRGB components, encoded, exactly as
    /// the swatch declares them. **Deliberately not linearised.** The web
    /// renderer feeds what `getComputedStyle` reports and the drawable is read
    /// back in the same space, so `HT.c11` has to land on `0xFFCC55` and not on
    /// a gamma-corrected cousin of it -- the character orb is drawing the same
    /// gold two pixels away and a reader would see the difference immediately.
    static func rgb(_ color: Color) -> SIMD3<Float> {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else {
            return SIMD3<Float>(1, 1, 1)
        }
        return SIMD3<Float>(
            Float(srgb.redComponent),
            Float(srgb.greenComponent),
            Float(srgb.blueComponent)
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(gpu: gpu) }

    func makeNSView(context: Context) -> MTKView {
        let view = OrbMetalView(frame: .zero, device: gpu.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        // Transparent, both ways: the clear leaves nothing in the drawable, and
        // an opaque layer would composite that nothing as black.
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        // Driven by the view's own display link, not by invalidation.
        view.enableSetNeedsDisplay = false
        // The drawable is sized in `OrbMetalView`, which is the only place that
        // knows the backing scale.
        view.autoResizeDrawable = false
        update(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        update(view, context.coordinator)
    }

    private func update(_ view: MTKView, _ coordinator: Coordinator) {
        coordinator.activity = activity
        coordinator.ink = ink
        coordinator.still = still
        // **An orb nobody can see does not draw -- but it always HAS a
        // frame.** A window can mount occluded (launched behind another one)
        // and be revealed later; a Metal view paused before its first frame
        // is an empty rectangle, which is how the orb shipped invisible the
        // day this file landed. So a paused view still paints one explicit
        // frame per SwiftUI update: the reveal finds a posed membrane, the
        // way the character orb's static art is simply there. The phase is
        // kept, so resuming picks up where it left off.
        view.isPaused = !running
        if view.isPaused { view.draw() }
        // Reduced motion drifts at a twentieth of the resting pace -- roughly a
        // radian every twenty seconds -- so the frame rate can come down with
        // it without the drift becoming visible as steps. (The web keeps 60
        // here for a WebKit compositing bug that has no equivalent on this
        // side.)
        view.preferredFramesPerSecond = still ? 12 : 60
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private let gpu: LiquidOrbGPU.Ready
        private var uniforms = OrbUniforms()

        /// Written by `updateNSView`, read by the loop. Both are the main
        /// thread: `MTKView` drives its delegate off the display link on the
        /// main run loop.
        var activity: Double = 0
        var ink = SIMD3<Float>(1, 1, 1)
        var still = false

        /// **2.0 rather than 0.** At t=0 the field is an undifferentiated
        /// stipple; two seconds in it is a membrane posed mid-sphere, which is
        /// what somebody arriving on the page should find.
        private var phase: Double = 2.0
        private var smoothed: Double = 0
        /// The ink as drawn, trailing the ink as asked for. `nil` until the
        /// first frame, which seeds it directly -- a launch must not fade the
        /// gold in from anywhere.
        private var inkSmoothed: SIMD3<Float>?
        private var last = CACurrentMediaTime()

        init(gpu: LiquidOrbGPU.Ready) {
            self.gpu = gpu
            assert(MemoryLayout<OrbUniforms>.stride == 512,
                   "OrbUniforms no longer matches struct Uniforms in LiquidOrb.metal")
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard view.drawableSize.width > 0,
                  let target = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let buffer = gpu.queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: target)
            else { return }

            let now = CACurrentMediaTime()
            // Clamped, which is also what covers coming back from paused: a
            // window that was off screen for a minute resumes a tenth of a
            // second later in the animation, not a minute.
            let dt = Swift.min(now - last, 0.1)
            last = now

            /* Time is integrated here rather than scaled in the shader, so a
               change of pace bends the animation instead of teleporting it. */
            if still {
                // Gentler, not zero, and activity ignored. Reduce Motion is
                // about motion that demands attention, and this page has
                // already made the argument for the rest: idle activity is
                // 0.05 and not 0 because a sphere that stops dead reads as
                // broken rather than as resting.
                phase += dt * baseSpeed * 0.05
            } else {
                // Critically damped, about a third of a second to settle: the
                // same easing every other state change gets, so 'thinking'
                // arriving reads as him stirring rather than as a cut.
                smoothed += (activity - smoothed) * (1 - exp(-dt * 3))
                phase += dt * baseSpeed * (0.55 + 2.1 * smoothed)
            }

            uniforms.size = SIMD2<Float>(
                Float(view.drawableSize.width), Float(view.drawableSize.height))
            uniforms.time = Float(phase)
            uniforms.exposure = Field.exposure * Float(1 + 0.18 * smoothed)
            uniforms.contourDeform = Float(Swift.min(0.1 + 0.06 * smoothed, 0.16))

            /* The ink morphs on the same third-of-a-second easing as
               everything else, so a state change reads as the sphere turning
               colour rather than being swapped for a different sphere. This
               one keeps easing under Reduce Motion: a crossfade is
               comprehension rather than motion, and a hard cut is exactly the
               abrupt jump that setting asks to be spared. */
            var drawn = inkSmoothed ?? ink
            drawn += (ink - drawn) * Float(1 - exp(-dt * 3))
            inkSmoothed = drawn
            uniforms.glowColor = SIMD4<Float>(drawn, 1)

            encoder.setRenderPipelineState(gpu.pipeline)
            encoder.setFragmentBytes(
                &uniforms, length: MemoryLayout<OrbUniforms>.stride, index: 0)
            // One fullscreen triangle. `vs_main` builds it from the vertex id;
            // there is no vertex buffer.
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

/// The drawable's size, and the only thing that owns it.
///
/// **Capped at 2x.** The orb is a 1-bit halftone whose block size is derived
/// from the drawable, so a 3x backing would not draw it sharper -- it would
/// draw the same picture out of smaller dots, which is a different picture.
private final class OrbMetalView: MTKView {
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawable()
    }

    override func layout() {
        super.layout()
        syncDrawable()
    }

    private func syncDrawable() {
        let scale = Swift.min(window?.backingScaleFactor ?? 2, 2)
        layer?.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0, size.height > 0, size != drawableSize {
            drawableSize = size
            // The posed frame `update` promises a paused view. It cannot land
            // there: the view mounts at zero size, the explicit draw runs
            // before the first layout, and a zero drawable is the first guard
            // in the delegate -- so the promise is kept here instead, the
            // moment there is somewhere to put it.
            if isPaused { draw() }
        }
    }
}
