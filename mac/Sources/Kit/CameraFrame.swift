import SwiftUI
import AppKit

/* ── CameraFrame ───────────────────────────────────────────────────────
   DOG CAM · PI 5                                         ▲▲▲ LIVE
   ┌─────────────────────────────────────────────────────────────┐
   │                     the still                               │
   └─────────────────────────────────────────────────────────────┘
   21:14:37 · next in 7s
   stillness                                          STILL · 42M

   A still from a camera, refreshed on an interval.

   **Fetched, not linked.** The monitor's route on the collector wants a bearer
   header, which no image view can send, so the frame comes through URLSession
   with `.reloadIgnoringLocalCacheData` -- which is also why there is no `?t=`
   cache-buster in the URL here: the request says "do not serve me a copy"
   outright rather than lying about the address to trick a cache.

   **Whether there is a feed at all is the caller's decision**, taken from the
   JSON (`frame.available`), never from whether an image happened to load. A
   frame that fails after that falls to NO SIGNAL and the next poll gets to
   prove itself.
*/

struct CameraVerdictSpec {
    var label: String
    var value: String
    var tone: Tone

    init(label: String, value: String, tone: Tone = .default) {
        self.label = label
        self.value = value
        self.tone = tone
    }
}

struct CameraFrame: View {
    var label: String = "Camera"
    /// The still to poll. Nil renders the no-signal state, which is what this
    /// draws until a feed is actually wired up.
    var src: URL? = nil
    /// Bearer for the collector. Nil in demo mode.
    var bearer: String? = nil
    var state: CameraState = .offline
    /// Timestamp of the frame on screen, pre-formatted.
    var stamp: String? = nil
    var showCountdown: Bool = true
    /// The reading the frame is being captured to produce.
    var verdict: CameraVerdictSpec? = nil
    /// A still every 10s is roughly the cheapest useful cadence for a Pi-class
    /// board: one JPEG decode per cycle rather than a continuous encode.
    var refreshSeconds: Int = 10
    var aspect: CGFloat = 4 / 3
    var scale: CGFloat = 3

    @State private var tick = 0
    @State private var remaining = 10
    @State private var image: NSImage?
    @State private var failed = false

    private struct LoadKey: Equatable {
        var url: URL?
        var tick: Int
    }

    private var dead: Bool { src == nil || failed }

    private var lamp: (level: Int, tone: Tone) {
        switch state {
        case .live: return (3, .nominal)
        case .stale: return (1, .caution)
        case .offline: return (0, .fault)
        }
    }

    private var stateInk: Color {
        switch state {
        case .live: return HT.nominal
        case .stale: return HT.caution
        case .offline: return HT.fault
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            viewport
            foot
            if let verdict { verdictLine(verdict) }
        }
        .background(Color.clear)
        .task(id: LoadKey(url: src, tick: tick)) { await load() }
        .onReceive(
            Timer.publish(every: 1, on: .main, in: .common).autoconnect()
        ) { _ in
            guard src != nil, refreshSeconds > 0 else { return }
            if remaining <= 1 {
                remaining = refreshSeconds
                tick &+= 1
            } else {
                remaining -= 1
            }
        }
        .onAppear { remaining = refreshSeconds }
    }

    // MARK: - head

    private var head: some View {
        HStack(spacing: HT.cw) {
            Text(label.uppercased())
                .font(HT.body)
                .foregroundStyle(HT.inkMid)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: HT.cw)
            StatusLamp(level: lamp.level, of: 3, tone: lamp.tone)
            Text(state.rawValue.uppercased())
                .font(HT.body)
                .foregroundStyle(stateInk)
                .fixedSize()
        }
        .frame(height: HT.row)
    }

    // MARK: - viewport

    private var viewport: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image, !dead {
                    Image(nsImage: image)
                        .resizable()
                        // Cover, not fill: a camera whose aspect does not match
                        // the panel is cropped rather than stretched. A
                        // stretched dog is a misreading of the scene.
                        .aspectRatio(contentMode: .fill)
                } else {
                    // No-signal static is pushed well below the dither
                    // threshold, so only the brightest noise peaks survive as
                    // sparse dots. A mid-grey field would come back half white
                    // and shout louder than every real reading on the page.
                    DitherPlate(pattern: .noise,
                                scale: dead ? scale + 1 : scale,
                                brightness: dead ? -0.34 : 0,
                                contrast: dead ? 0.85 : 1.15,
                                aspect: aspect)
                }
            }
            .clipped()
            .overlay {
                if dead {
                    Text("No signal")
                        .font(HT.body)
                        .tracking(1)
                        .textCase(.uppercase)
                        .foregroundStyle(HT.fault)
                        .padding(.horizontal, HT.cw2)
                        .frame(height: HT.row)
                        // A mask: it has to put the static out to be read.
                        .background(HT.groundMask)
                        .overlay { Rectangle().strokeBorder(HT.fault, lineWidth: 1) }
                        .allowsHitTesting(false)
                }
            }
            .overlay { Rectangle().strokeBorder(HT.line, lineWidth: 1) }
    }

    // MARK: - foot

    private var foot: some View {
        HStack(spacing: HT.cw) {
            Text(stamp ?? "--:--:--")
                .foregroundStyle(HT.inkDim)
            Spacer(minLength: HT.cw)
            Text(footRight)
                .foregroundStyle(HT.inkFaint)
                .fixedSize()
        }
        .font(HT.body)
        .lineLimit(1)
        .frame(height: HT.row)
    }

    private var footRight: String {
        if failed { return "frame failed to load" }
        if src == nil { return "every \(refreshSeconds)s when wired" }
        return showCountdown ? "next in \(remaining)s" : ""
    }

    private func verdictLine(_ v: CameraVerdictSpec) -> some View {
        HStack(spacing: HT.cw) {
            Text(v.label.lowercased())
                .foregroundStyle(HT.inkMid)
            Text(v.value.uppercased())
                .foregroundStyle(v.tone.ink ?? HT.inkBright)
            Spacer(minLength: 0)
        }
        .font(HT.body)
        .lineLimit(1)
        .padding(.top, HT.s1)
        .frame(height: HT.row + HT.s1)
    }

    // MARK: - the fetch

    private func load() async {
        guard let src else {
            image = nil
            failed = false
            return
        }
        var request = URLRequest(url: src)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                failed = true
                return
            }
            guard let decoded = NSImage(data: data) else {
                failed = true
                return
            }
            image = decoded
            failed = false
        } catch {
            // Cleared on the next successful poll: one bad frame does not latch
            // the panel to NO SIGNAL for good.
            failed = true
        }
    }
}
