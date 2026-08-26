import Foundation

/* The staleness rule, in one place -- ported from the web console.
 *
 * Without this file the rule ("what does a stale panel look like?") lives in
 * eight views and drifts within a week. Every visual decision about source
 * health is derived here and consumed only through `SourcePanel`.
 *
 * The governing constraint, from the design system's own conventions: a
 * coloured Panel frame means *this block is the thing in trouble*. It is not
 * decoration, and a wall of green frames makes a real red one invisible.
 */

enum FeedLevel { case live, stale, failed, standby, unknown }

/// How many pips are lit, out of how many, and in what colour.
struct Lamp: Equatable {
    var level: Int
    var of: Int
    var tone: Tone
}

struct Health {
    var level: FeedLevel

    /// The frame colour, or `.default` for no frame colour at all.
    ///
    /// `.standby` never appears here on purpose: a source that was never
    /// configured is not a source in trouble, and neither is a healthy one --
    /// which is why `live` also comes back `.default`.
    var panelTone: Tone

    var lamp: Lamp

    /// Short words for the strip's lead, or nil for none. Left as a plain
    /// string because the mail list has read it as one since v1; its colour is
    /// `pillTone` beside it.
    var pill: String?
    var pillTone: Tone

    /// The sentence after it, or nil.
    var note: String?

    /// True when values may be shown but must be visually demoted. Dimming is
    /// the only safe treatment for a stale number.
    var dim: Bool

    /// True when any element asserting a *trend* must be removed entirely.
    ///
    /// Deliberately a separate flag from `dim`, because they are different
    /// instructions and not two strengths of the same one. A stale number
    /// dimmed still reads as "this was true a while ago", which is honest. A
    /// stale sparkline dimmed still reads as "here is what the last fourteen
    /// days did", which is not -- the window it draws is the window it no
    /// longer has. A value gets demoted; a trend gets deleted.
    var hideDelta: Bool

    init(level: FeedLevel,
         panelTone: Tone = .default,
         lamp: Lamp = Lamp(level: 0, of: 3, tone: .standby),
         pill: String? = nil,
         pillTone: Tone = .default,
         note: String? = nil,
         dim: Bool,
         hideDelta: Bool = true) {
        self.level = level
        self.panelTone = panelTone
        self.lamp = lamp
        self.pill = pill
        self.pillTone = pillTone
        self.note = note
        self.dim = dim
        self.hideDelta = hideDelta
    }
}

enum HealthRule {

    /// How old, in the words a panel says it in.
    ///
    /// Not private: the Hardware and Overview panels both say an age in a
    /// sentence health() does not write for them, and two spellings of "3h ago"
    /// in one console is exactly the drift this file exists to stop.
    static func ageWords(_ age: Double?) -> String {
        guard let age else { return "age unknown" }
        if age < 60 { return "\(Int(age.rounded(.down)))s ago" }
        if age < 3600 { return "\(Int((age / 60).rounded(.down)))m ago" }
        if age < 86400 { return "\(Int((age / 3600).rounded(.down)))h ago" }
        return "\(Int((age / 86400).rounded(.down)))d ago"
    }

    private static func level(for status: SourceStatus) -> FeedLevel {
        switch status {
        case .ok: return .live
        case .degraded, .stale: return .stale
        case .dormant: return .standby
        case .error: return .failed
        }
    }

    /// Health for one source. `feedDown` overrides everything: when the
    /// collector itself is unreachable no individual source has failed -- they
    /// are all merely unknown, and painting eight fault frames would be both
    /// wrong and unreadable.
    static func health(_ env: (any SourceEnvelopeShape)?, feedDown: Bool) -> Health {
        guard !feedDown, let env else {
            return Health(
                level: .unknown,
                panelTone: .default,
                lamp: Lamp(level: 0, of: 3, tone: .standby),
                pill: nil, pillTone: .default,
                note: "console offline · showing last known values",
                dim: true, hideDelta: true)
        }

        switch level(for: env.status) {
        case .live:
            return Health(
                level: .live,
                // No frame colour on a healthy panel, on purpose. The lamp
                // already reports health, and colouring every good panel green
                // is what makes a genuinely bad one disappear.
                panelTone: .default,
                lamp: Lamp(level: 3, of: 3, tone: .nominal),
                pill: nil, pillTone: .default, note: nil,
                dim: false,
                // The only branch where a trend may be drawn at all: this is
                // the one state in which the window a sparkline claims is the
                // window the data actually covers.
                hideDelta: false)

        case .stale:
            // Prefer the reason the collector gave over our own age arithmetic.
            // When a source is stale because the upstream admitted it, `age_s`
            // is the age of a fresh fetch of bad news, and rendering it reads
            // as "this just happened" over an outage hours old.
            if let reason = env.staleReason {
                return Health(
                    level: .stale,
                    panelTone: .caution,
                    lamp: Lamp(level: 1, of: 3, tone: .caution),
                    pill: reason, pillTone: .caution,
                    // Deliberately NOT "last good ...": in the semantic case
                    // the source answered promptly, with bad news. Saying the
                    // transport is healthy is the useful half.
                    note: "source answered \(ageWords(env.ageS)) · its data is not current",
                    dim: true, hideDelta: true)
            }
            return Health(
                level: .stale,
                panelTone: .caution,
                lamp: Lamp(level: 1, of: 3, tone: .caution),
                pill: "stale \(ageWords(env.ageS))", pillTone: .caution,
                note: env.fetchedAt != nil ? "last good \(ageWords(env.ageS))" : "no reading yet",
                dim: true, hideDelta: true)

        case .failed:
            return Health(
                level: .failed,
                panelTone: .fault,
                lamp: Lamp(level: 0, of: 3, tone: .fault),
                pill: "failed", pillTone: .fault,
                note: env.error?.message ?? "source unreachable",
                dim: true, hideDelta: true)

        case .standby:
            return Health(
                level: .standby,
                // Deliberately none. Never configured is not in trouble.
                panelTone: .default,
                lamp: Lamp(level: 0, of: 3, tone: .standby),
                pill: "not wired", pillTone: .standby,
                note: env.error?.message,
                dim: true, hideDelta: true)

        case .unknown:
            return Health(
                level: .unknown,
                panelTone: .default,
                lamp: Lamp(level: 0, of: 3, tone: .standby),
                pill: nil, pillTone: .default, note: nil,
                dim: true, hideDelta: true)
        }
    }
}
