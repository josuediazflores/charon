import Foundation

/* Presentation only, ported from the web console's formatting helpers.
 *
 * Relative times are computed at render, never baked into a payload: a
 * relative string carried in the document is wrong the moment that document is
 * cached or a poll runs late.
 */

enum Fmt {

    // MARK: - clocks

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The collector stamps some records in local time with no zone at all
    /// (`2026-08-16T09:14:22`), which neither ISO8601DateFormatter mode will
    /// take. Read as local, which is what the writer meant.
    private static let naiveLocal: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    private static let naiveLocalMinutes: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.timeZone = .current
        return f
    }()

    static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        if let d = isoWithFraction.date(from: iso) { return d }
        if let d = isoPlain.date(from: iso) { return d }
        if let d = naiveLocal.date(from: iso) { return d }
        if let d = naiveLocalMinutes.date(from: iso) { return d }
        return nil
    }

    // MARK: - numbers

    static func num(_ n: Int?) -> String {
        guard let n else { return "—" }
        return n.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// A percentage the collector already computed: "31.0%". One decimal by
    /// default, because a block rate quoted to the whole number moves by a
    /// point between two polls and reads as news.
    static func pct(_ n: Double?, _ digits: Int = 1) -> String {
        guard let n else { return "—" }
        return String(format: "%.\(max(0, digits))f%%", n)
    }

    /// A number with nothing done to it: no grouping, no fixed decimals, and no
    /// trailing zero on a whole one.
    ///
    /// For the readings the reference interpolates straight into a template
    /// (`${n.rtt_ms}ms`), where JavaScript prints 12.3 as "12.3" and 12 as
    /// "12". Swift's own interpolation would put a ".0" on the second, and a
    /// round trip of exactly 12ms would read as more precision than was
    /// measured.
    static func raw(_ n: Double?) -> String {
        guard let n else { return "—" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int(n)) }
        return String(n)
    }

    /// "37.5°C". One decimal always, so a column of them is a column.
    static func temp(_ c: Double?) -> String {
        guard let c else { return "—" }
        return String(format: "%.1f°C", c)
    }

    /// A file size in the units a mail client says them in: 812 B, 41 KB,
    /// 3.2 MB. Powers of 1024, because that is what an IMAP RFC822.SIZE counts.
    static func bytes(_ n: Int?) -> String {
        guard let n else { return "—" }
        if n < 1024 { return "\(n) B" }
        let kb = Double(n) / 1024
        if kb < 1024 { return "\(Int(kb.rounded())) KB" }
        return String(format: "%.1f MB", kb / 1024)
    }

    /// Compact duration: 42d 11h, 15h 02m, 7m, 30s.
    static func dur(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let s = Int(max(0, seconds.rounded(.down)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 {
            return "\(s / 3600)h " + String(format: "%02d", (s % 3600) / 60) + "m"
        }
        return "\(s / 86400)d " + String(format: "%02d", (s % 86400) / 3600) + "h"
    }

    /// "4m", "2h 05m", "3d 04h" from an ISO timestamp, at render time.
    static func relTime(_ iso: String?, now: Date = Date()) -> String {
        guard let t = date(iso) else { return "—" }
        return dur(now.timeIntervalSince(t))
    }

    /// The calendar day and the minute, in local time: "2026-08-16 09:14".
    /// Falls back to the string itself: a header this cannot parse is still
    /// worth showing verbatim.
    static func stamp(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        guard let at = date(iso) else { return iso }
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        return String(format: "%04d-%02d-%02d %02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// HH:MM. The seconds are in the file and mean nothing to a reader.
    static func hhmm(_ iso: String?) -> String {
        guard let at = date(iso) else { return "--:--" }
        let c = Calendar.current.dateComponents([.hour, .minute], from: at)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// HH:MM:SS, for a camera frame's stamp. Eight characters always, including
    /// when there is nothing to stamp: a gutter that collapses on the one frame
    /// with no timestamp would shift the line beside it.
    static func clock(_ iso: String?) -> String {
        guard let at = date(iso) else { return "--:--:--" }
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: at)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// The day, spelled out, for a page head: "Thursday 18 August".
    ///
    /// **Pinned to en_GB** and to the locale's own template rather than to a
    /// literal pattern, which is what the web does through `toLocaleDateString`
    /// -- day before month, no year, and no comma. (SPEC-CONSOLE's prose writes
    /// the example with a comma; ICU does not put one there for en-GB in either
    /// program, and matching the reference beats matching its description.)
    private static let longDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()

    static func longDate(_ at: Date = Date()) -> String { longDay.string(from: at) }

    /// Local ISO seconds, the stamp the collector writes and the demo store
    /// mints. Not counted back from a fixed module load: two drafts written a
    /// minute apart must not carry the same second, or a reader that tells
    /// drafts apart by their stamp sees one draft written twice.
    static func stampNow(_ at: Date = Date()) -> String {
        let c = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: at)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    // MARK: - identity

    /// Two characters standing for a sender.
    ///
    /// Initials where the header carried a name, the first two letters of the
    /// local part where it carried only an address, and `#` where it carried a
    /// bare phone number. Never three wide: the cell is a fixed column in both
    /// views, and the disc centres whatever it is given.
    static func initials(_ who: String?) -> String {
        let raw = (who ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return "··" }

        // A bare address gives up its local part; a display name is used whole,
        // and "Mira Vale <m@example.edu>" is a display name by that test.
        let source: String
        if !raw.contains(" ") && raw.contains("@") {
            source = String(raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)[0])
        } else {
            source = raw
        }

        // A number has no initials. Every US mobile the bridge has never met a
        // contact for starts +1, so the first two digits made a whole column of
        // discs that all read "14" -- a hue per number telling them apart and a
        // pair of letters insisting they were the same person. `#` says what
        // the disc actually knows: this one arrived as a number.
        let digits = source.filter { !"+()-. ".contains($0) }
        if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return "#" }

        let words = source
            .split(whereSeparator: { " \t\n._+-".contains($0) })
            .map(String.init)
            .filter { !$0.isEmpty }

        let first = words.first.map(Array.init) ?? []
        let second = words.count > 1 ? Array(words[1]) : []

        let two: String
        if !second.isEmpty {
            two = String([first.first, second.first].compactMap { $0 })
        } else {
            two = String(first.prefix(2))
        }
        return two.isEmpty ? "··" : two.uppercased()
    }

    /// A hue per sender, hashed from whatever the header carried.
    ///
    /// Clamped to the arc the console already lives on: 96 to 204 is green
    /// through cyan, so fifty strangers read as one quiet palette rather than
    /// as a bag of sweets. FNV-1a, in 32-bit wraparound arithmetic, to match
    /// the web implementation's `Math.imul` exactly -- the same address has to
    /// give the same disc in both programs, forever.
    static func senderHue(_ who: String?) -> Double {
        let s = (who ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var h = Int32(bitPattern: 2166136261)
        for unit in s.utf16 {
            h ^= Int32(unit)
            h = h &* 16777619
        }
        return Double(96 + Int(h.magnitude % 109))
    }
}
