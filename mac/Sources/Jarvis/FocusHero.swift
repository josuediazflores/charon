import SwiftUI

struct FocusHero: View {
    var activity: Double = 1
    var ink: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.consoleVisible) private var visible

    private static let particles = FocusParticles()
    // Tilt the three tracks separately, as in the ringed planet in the reference.
    private static let rings: [(width: CGFloat, height: CGFloat, tilt: CGFloat)] = [
        (0.97, 0.37, -17), (0.93, 0.33, -20), (0.70, 0.27, -17)
    ]

    var body: some View {
        let still = reduceMotion || activity == 0
        TimelineView(.animation(minimumInterval: 1 / (10 + 20 * activity), paused: still || !visible)) { timeline in
            Canvas { context, size in
                var art = context
                art.translateBy(x: size.width / 2, y: size.height / 2)
                let diameter = min(size.height * 0.86, size.width * 0.40)
                let disc = CGRect(x: -diameter / 2, y: -diameter / 2, width: diameter, height: diameter)
                drawRings(in: art, size: size, front: false)
                art.fill(Path(ellipseIn: disc), with: .color(Color(hex: 0x191919)))
                if let frame = Self.particles.frame(at: still ? 0 : timeline.date.timeIntervalSinceReferenceDate) {
                    var surface = art
                    surface.addFilter(.colorMultiply(ink))
                    surface.draw(Image(decorative: frame, scale: 1), in: disc)
                }
                // Only the near half of each ring crosses the lit face.
                drawRings(in: art, size: size, front: true)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawRings(in art: GraphicsContext, size: CGSize, front: Bool) {
        for ring in Self.rings {
            var path = Path()
            let transform = CGAffineTransform(rotationAngle: ring.tilt * .pi / 180)
                .scaledBy(x: ring.width * size.width / 2, y: ring.height * size.height / 2)
            path.addArc(center: .zero, radius: 1,
                        startAngle: .degrees(front ? 0 : 180), endAngle: .degrees(front ? 180 : 360),
                        clockwise: false, transform: transform)
            art.stroke(path, with: .color(.white.opacity(front ? 0.9 : 0.78)),
                       lineWidth: max(0.5, size.width / 385))
        }
    }
}

/// Fixed samples on a rotating sphere, lit from the upper left.
private final class FocusParticles {
    private struct Particle {
        let y: Double
        let distance: Double
        let theta: Double
        let jitter: Double
        let mass: Double
        let glint: Double
    }

    private static let side = 224
    private static let radius = Double(side) / 2 - 2
    private static let period: TimeInterval = 24
    private static let framesPerLoop = Int(period) * 30
    private static let shimmerCycles = period / 1.5
    private static let gray = CGColorSpaceCreateDeviceGray()
    private let particles: [Particle]
    // Rasterize frames on demand so opening Conversation does not build the whole loop.
    private let frames = NSCache<NSNumber, CGImage>()

    init() {
        var seed: UInt32 = 421792
        func random() -> Double {
            seed = seed &* 1664525 &+ 1013904223
            return Double(seed) / 4_294_967_296
        }

        var points: [Particle] = []
        points.reserveCapacity(26_000)
        // A golden-angle spiral keeps the stipple even around the silhouette.
        let goldenAngle = Double.pi * (3 - sqrt(5.0))
        for index in 0..<26_000 {
            let latitude = 2 * (Double(index) + 0.5) / 26_000 - 1
            let theta = goldenAngle * Double(index) + (random() - 0.5) * 0.012
            let radius = Self.radius + random() * 0.4
            points.append(Particle(y: latitude * radius,
                                   distance: sqrt(1 - latitude * latitude) * radius,
                                   theta: theta, jitter: random() * 2 * .pi,
                                   mass: 70 + random() * 240, glint: 0.06 + random() * 0.08))
        }
        particles = points
    }

    func frame(at time: TimeInterval) -> CGImage? {
        let fraction = time.truncatingRemainder(dividingBy: Self.period) / Self.period
        let index = Int(fraction * Double(Self.framesPerLoop))
        let key = NSNumber(value: index)
        if let image = frames.object(forKey: key) { return image }

        let rotation = Double(index) / Double(Self.framesPerLoop) * 2 * .pi
        let shimmer = rotation * Self.shimmerCycles
        let side = Self.side
        var light = [UInt16](repeating: 0, count: side * side)
        for point in particles {
            let sway = sin(shimmer + point.jitter)
            let angle = point.theta + rotation + sway * 0.006
            let depth = point.distance * sin(angle)
            guard depth >= 0 else { continue }
            let longitude = point.distance * cos(angle)
            let x = Double(side - 1) / 2 + longitude
            let y = Double(side - 1) / 2 + point.y
            let left = Int(x), top = Int(y)
            let dx = x - Double(left), dy = y - Double(top)
            let diffuse = max(0, (-0.86 * longitude - 0.60 * point.y + 0.07 * depth) / Self.radius)
            let rim = pow(1 - min(1, depth / Self.radius), 3)
            let power = point.mass * (0.11 + 2.2 * diffuse + 0.46 * rim) * (1 + point.glint * sway)
            let base = top * side + left
            light[base] &+= UInt16((1 - dx) * (1 - dy) * power)
            light[base + 1] &+= UInt16(dx * (1 - dy) * power)
            light[base + side] &+= UInt16((1 - dx) * dy * power)
            light[base + side + 1] &+= UInt16(dx * dy * power)
        }

        var pixels = Data(count: side * side * 2)
        pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for (offset, intensity) in light.enumerated() {
                let alpha = UInt8(clamping: intensity)
                bytes[offset * 2] = alpha
                bytes[offset * 2 + 1] = alpha
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 16,
                                  bytesPerRow: side * 2, space: Self.gray,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        frames.setObject(image, forKey: key)
        return image
    }
}
