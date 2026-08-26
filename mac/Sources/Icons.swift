import SwiftUI

/* The mail app's glyph set, ported path-for-path from the web console's
 * mail kit.
 *
 * One 16pt box, one stroke weight (1.25), one join. Drawn rather than typed for
 * the reason the web version draws them: a ✦ or a ✉ borrowed from a fallback
 * face would be the one shape in the app that did not match the others, and an
 * emoji would be worse. SF Symbols are not used for the distinctive ones for
 * the same reason -- these are the console's own shapes.
 *
 * Nothing here carries a colour. Every glyph paints in the foreground style it
 * inherits, so this file cannot drift the palette even by accident.
 */

enum IconName: String {
    case mail, mailOpen, reply, sparkle, archive, unread
    case left, right, down, clip, star, pencil
    case alert, fault, send, close, back, gear
    /// The iMessage channel's three, drawn on the same 16 box at the same 1.25:
    /// two overlapping bubbles, one bubble, and a push pin.
    case messages, sms, pin
    /// The composer's send and the log's way back to the bottom. A shaft and a
    /// head, on the same 16 box: `send` is the mail client's paper plane and
    /// this is the messaging app's arrow, which is the shape a person already
    /// reads as "this line goes now".
    ///
    /// `arrowUp` is the one glyph in this file drawn at 1.5 rather than 1.25,
    /// because it stands alone on a filled 26pt disc rather than beside a word
    /// on a dark ground. `arrowDown` stands beside a word and keeps the 1.25.
    case arrowUp, arrowDown
}

/// A 16-unit path scaled to the box it is asked for.
///
/// The shape stores the glyph's *name* rather than its builder closure: a
/// `Shape` is `Sendable` by conformance, and a stored `(inout Path) -> Void`
/// makes it one that only pretends to be. The lookup is a switch over an enum
/// and costs nothing.
private struct Glyph: Shape {
    let name: IconName
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if filled {
            Glyphs.fill(name)?(&p)
        } else {
            Glyphs.stroke(name)(&p)
        }
        let s = min(rect.width, rect.height) / 16
        return p.applying(CGAffineTransform(scaleX: s, y: s))
    }
}

private extension Path {
    mutating func poly(_ pts: [(CGFloat, CGFloat)], closed: Bool = false) {
        guard let head = pts.first else { return }
        move(to: CGPoint(x: head.0, y: head.1))
        for pt in pts.dropFirst() { addLine(to: CGPoint(x: pt.0, y: pt.1)) }
        if closed { closeSubpath() }
    }

    /// A semicircular elbow between two points, which is what every arc in the
    /// paperclip actually is: in each case the SVG's chord length equals the
    /// arc's diameter. `bulge` picks which side it swells to.
    mutating func semi(from a: CGPoint, to b: CGPoint, clockwise: Bool) {
        let centre = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let radius = hypot(b.x - a.x, b.y - a.y) / 2
        let start = Angle(radians: atan2(a.y - centre.y, a.x - centre.x))
        let end = Angle(radians: atan2(b.y - centre.y, b.x - centre.x))
        move(to: a)
        addArc(center: centre, radius: radius,
               startAngle: start, endAngle: end, clockwise: clockwise)
    }

    mutating func roundedBox(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
        addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h),
                       cornerSize: CGSize(width: r, height: r))
    }
}

private enum Glyphs {

    /// The stroked half of each glyph.
    static func stroke(_ name: IconName) -> (inout Path) -> Void {
        switch name {
        case .mail:
            return { p in
                p.roundedBox(1.75, 3.25, 12.5, 9.5, 2)
                p.poly([(2.4, 5.2), (8, 9), (13.6, 5.2)])
            }

        case .mailOpen:
            return { p in
                p.move(to: CGPoint(x: 2, y: 7))
                p.addLine(to: CGPoint(x: 8, y: 2.75))
                p.addLine(to: CGPoint(x: 14, y: 7))
                p.addLine(to: CGPoint(x: 14, y: 12.75))
                p.addQuadCurve(to: CGPoint(x: 12.5, y: 14.25),
                               control: CGPoint(x: 14, y: 14.25))
                p.addLine(to: CGPoint(x: 3.5, y: 14.25))
                p.addQuadCurve(to: CGPoint(x: 2, y: 12.75),
                               control: CGPoint(x: 2, y: 14.25))
                p.closeSubpath()
                p.poly([(2, 7), (8, 11), (14, 7)])
            }

        case .reply:
            return { p in
                p.poly([(6.25, 4), (2.5, 7.75), (6.25, 11.5)])
                // h5.35 then a quarter turn down, then v.5
                p.move(to: CGPoint(x: 2.9, y: 7.75))
                p.addLine(to: CGPoint(x: 8.25, y: 7.75))
                p.addArc(center: CGPoint(x: 8.25, y: 12.75), radius: 5,
                         startAngle: .degrees(-90), endAngle: .degrees(0),
                         clockwise: false)
                p.addLine(to: CGPoint(x: 13.25, y: 13.25))
            }

        case .sparkle:
            return { p in
                p.poly([(7, 2.5), (8.15, 5.6), (11.25, 6.75), (8.15, 7.9),
                        (7, 11), (5.85, 7.9), (2.75, 6.75), (5.85, 5.6)], closed: true)
                p.poly([(12, 9.75), (12.6, 11.4), (14.25, 12), (12.6, 12.6),
                        (12, 14.25), (11.4, 12.6), (9.75, 12), (11.4, 11.4)], closed: true)
            }

        case .archive:
            return { p in
                p.roundedBox(1.75, 2.75, 12.5, 3.25, 1)
                p.move(to: CGPoint(x: 3, y: 6.25))
                p.addLine(to: CGPoint(x: 3, y: 12.25))
                p.addQuadCurve(to: CGPoint(x: 4.25, y: 13.5),
                               control: CGPoint(x: 3, y: 13.5))
                p.addLine(to: CGPoint(x: 11.75, y: 13.5))
                p.addQuadCurve(to: CGPoint(x: 13, y: 12.25),
                               control: CGPoint(x: 13, y: 13.5))
                p.addLine(to: CGPoint(x: 13, y: 6.25))
                p.poly([(6.5, 9), (9.5, 9)])
            }

        case .unread:
            return { p in
                p.addEllipse(in: CGRect(x: 2.5, y: 2.5, width: 11, height: 11))
            }

        case .left:
            return { p in p.poly([(10, 3.5), (5.5, 8), (10, 12.5)]) }

        case .right:
            return { p in p.poly([(6, 3.5), (10.5, 8), (6, 12.5)]) }

        case .down:
            return { p in p.poly([(3.75, 6), (8, 10.25), (12.25, 6)]) }

        case .clip:
            return { p in
                // Three semicircular elbows joined by three straight runs. The
                // SVG's arcs are all 180 degrees -- the chord in each is the
                // diameter -- so they port exactly rather than approximately.
                p.move(to: CGPoint(x: 10.75, y: 7.25))
                p.addLine(to: CGPoint(x: 6.5, y: 11.5))
                p.semi(from: CGPoint(x: 6.5, y: 11.5),
                       to: CGPoint(x: 3.3, y: 8.3), clockwise: false)
                p.addLine(to: CGPoint(x: 8.3, y: 3.3))
                p.semi(from: CGPoint(x: 8.3, y: 3.3),
                       to: CGPoint(x: 10.55, y: 5.55), clockwise: false)
                p.addLine(to: CGPoint(x: 5.55, y: 10.55))
                p.semi(from: CGPoint(x: 5.55, y: 10.55),
                       to: CGPoint(x: 4.25, y: 9.3), clockwise: false)
                p.addLine(to: CGPoint(x: 8.5, y: 5.1))
            }

        case .star:
            return { p in
                p.poly([(8, 2.5), (9.7, 5.95), (13.5, 6.5), (10.75, 9.18),
                        (11.4, 12.97), (8, 11.18), (4.6, 12.97), (5.25, 9.18),
                        (2.5, 6.5), (6.3, 5.95)], closed: true)
            }

        case .pencil:
            return { p in
                p.poly([(11.25, 2.75), (13.25, 4.75), (6, 12), (3.25, 12.75), (4, 10)],
                       closed: true)
                p.poly([(9.9, 4.1), (11.9, 6.1)])
            }

        case .alert:
            return { p in
                p.poly([(8, 2.9), (14.25, 13.4), (1.75, 13.4)], closed: true)
                p.poly([(8, 6.6), (8, 9.7)])
            }

        case .fault:
            return { p in
                p.addEllipse(in: CGRect(x: 2.25, y: 2.25, width: 11.5, height: 11.5))
                p.poly([(6, 6), (10, 10)])
                p.poly([(10, 6), (6, 10)])
            }

        case .send:
            return { p in
                p.poly([(13.75, 2.25), (2.5, 6.75), (6.9, 8.6)], closed: true)
                p.poly([(6.9, 8.6), (8.75, 13), (13.75, 2.25)], closed: true)
            }

        case .close:
            return { p in
                p.poly([(4, 4), (12, 12)])
                p.poly([(12, 4), (4, 12)])
            }

        case .back:
            return { p in
                p.poly([(6.75, 3.5), (2.5, 8), (6.75, 12.5)])
                p.poly([(2.9, 8), (13.5, 8)])
            }

        case .messages:
            return { p in
                // Two bubbles, the back one cut where the front crosses it,
                // which is the only way depth reads in one bit. The front
                // bubble keeps the tail, so mail, messages and chat are one
                // family and still tell apart at 14px.
                p.move(to: CGPoint(x: 5.75, y: 6.25))
                p.addLine(to: CGPoint(x: 5.75, y: 3.9))
                p.addQuadCurve(to: CGPoint(x: 7.9, y: 1.75),
                               control: CGPoint(x: 5.75, y: 1.75))
                p.addLine(to: CGPoint(x: 12.1, y: 1.75))
                p.addQuadCurve(to: CGPoint(x: 14.25, y: 3.9),
                               control: CGPoint(x: 14.25, y: 1.75))
                p.addLine(to: CGPoint(x: 14.25, y: 6.1))
                p.addQuadCurve(to: CGPoint(x: 12.1, y: 8.25),
                               control: CGPoint(x: 14.25, y: 8.25))
                p.addLine(to: CGPoint(x: 10.75, y: 8.25))

                p.move(to: CGPoint(x: 3.9, y: 6.25))
                p.addLine(to: CGPoint(x: 8.1, y: 6.25))
                p.addQuadCurve(to: CGPoint(x: 10.25, y: 8.4),
                               control: CGPoint(x: 10.25, y: 6.25))
                p.addLine(to: CGPoint(x: 10.25, y: 10.35))
                p.addQuadCurve(to: CGPoint(x: 8.1, y: 12.5),
                               control: CGPoint(x: 10.25, y: 12.5))
                p.addLine(to: CGPoint(x: 4.9, y: 12.5))
                p.addLine(to: CGPoint(x: 1.75, y: 14.6))
                p.addLine(to: CGPoint(x: 1.75, y: 8.4))
                p.addQuadCurve(to: CGPoint(x: 3.9, y: 6.25),
                               control: CGPoint(x: 1.75, y: 6.25))
                p.closeSubpath()
            }

        case .sms:
            return { p in
                // One bubble: SMS, the channel the bridge does not own.
                p.move(to: CGPoint(x: 4.15, y: 3.05))
                p.addLine(to: CGPoint(x: 11.85, y: 3.05))
                p.addQuadCurve(to: CGPoint(x: 14, y: 5.2),
                               control: CGPoint(x: 14, y: 3.05))
                p.addLine(to: CGPoint(x: 14, y: 9.5))
                p.addQuadCurve(to: CGPoint(x: 11.85, y: 11.65),
                               control: CGPoint(x: 14, y: 11.65))
                p.addLine(to: CGPoint(x: 6.6, y: 11.65))
                p.addLine(to: CGPoint(x: 3.1, y: 14.2))
                p.addLine(to: CGPoint(x: 3.1, y: 5.2))
                p.addQuadCurve(to: CGPoint(x: 4.15, y: 3.05),
                               control: CGPoint(x: 3.1, y: 3.05))
                p.closeSubpath()
            }

        case .pin:
            return { p in
                // Cap, flared body, needle. Three strokes and no curve: at 12px
                // a drawn pinhead closes into a blob.
                p.poly([(5.2, 2.6), (10.8, 2.6)])
                p.poly([(6.4, 2.6), (6.4, 6.1), (4.3, 7.9), (11.7, 7.9),
                        (9.6, 6.1), (9.6, 2.6)])
                p.poly([(8, 7.9), (8, 13.4)])
            }

        case .arrowUp:
            return { p in
                p.poly([(8, 13), (8, 4.15)])
                p.poly([(4.05, 8.1), (8, 4.15), (11.95, 8.1)])
            }

        case .arrowDown:
            return { p in
                p.poly([(8, 3.15), (8, 12)])
                p.poly([(11.95, 8.05), (8, 12), (4.05, 8.05)])
            }

        case .gear:
            return { p in
                // Eight teeth on one radius rather than a toothed outline: a
                // real gear profile at 16px and 1.25 of stroke closes into a
                // blob. Every tooth runs the same 4.4 to 6.1 from the centre.
                p.addEllipse(in: CGRect(x: 3.3, y: 3.3, width: 9.4, height: 9.4))
                p.addEllipse(in: CGRect(x: 6.1, y: 6.1, width: 3.8, height: 3.8))
                p.poly([(8, 1.9), (8, 3.6)])
                p.poly([(8, 12.4), (8, 14.1)])
                p.poly([(1.9, 8), (3.6, 8)])
                p.poly([(12.4, 8), (14.1, 8)])
                p.poly([(3.68, 3.68), (4.88, 4.88)])
                p.poly([(11.12, 11.12), (12.32, 12.32)])
                p.poly([(12.32, 3.68), (11.12, 4.88)])
                p.poly([(4.88, 11.12), (3.68, 12.32)])
            }
        }
    }

    /// The filled half, where a glyph has one.
    static func fill(_ name: IconName) -> ((inout Path) -> Void)? {
        switch name {
        case .unread:
            return { p in p.addEllipse(in: CGRect(x: 5.75, y: 5.75, width: 4.5, height: 4.5)) }
        case .alert:
            return { p in p.addEllipse(in: CGRect(x: 7.45, y: 10.85, width: 1.1, height: 1.1)) }
        default:
            return nil
        }
    }
}

/// One glyph, at the size the call site asks for.
struct Icon: View {
    let name: IconName
    var size: CGFloat = 16
    /// The stroke, in the 16-unit box's own units. One weight for the whole
    /// set and a parameter rather than a constant only because `arrowUp` is
    /// drawn on a filled disc and needs 1.5 to read there. Nothing else in the
    /// app passes it.
    var weight: CGFloat = 1.25

    var body: some View {
        let scale = size / 16
        ZStack {
            Glyph(name: name, filled: false)
                .stroke(style: StrokeStyle(lineWidth: weight * scale,
                                           lineCap: .round, lineJoin: .round))
            if Glyphs.fill(name) != nil {
                Glyph(name: name, filled: true).fill()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
