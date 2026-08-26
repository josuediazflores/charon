import Foundation

/* The last document the collector actually sent, kept across launches.
 *
 * **The raw bytes, not the decoded tree.** A cold start against a Pi that is
 * asleep should draw the console it drew last night rather than a Connecting
 * panel, and the honest way to hold a payload is the way it arrived: re-decoded
 * on the way back out, through the same lenient decoder a live fetch uses, so a
 * cache written by an older build renders exactly as much as that build's
 * payload would have. Encoding the model back to JSON would mean a second
 * hand-written pass over forty types that could drift from the first.
 *
 * **What comes out of here is drawn as feedDown**, which is the whole point of
 * `hydrated`: these are last known values and every panel has to say so until a
 * live payload replaces them. See build decision 9.
 *
 * Demo mode never writes here. A fixture is not a reading, and rehydrating one
 * would open the app dim and offline over numbers that were invented anyway.
 */
enum TelemetryCache {

    /// The web's own key. One console, one cache, whichever program wrote it.
    private static let key = "hc-telemetry-v1"
    private static let atField = "at"
    private static let payloadField = "payload"

    static func save(_ raw: Data, at: Date) {
        UserDefaults.standard.set(
            [atField: at.timeIntervalSince1970, payloadField: raw],
            forKey: key)
    }

    /// The cached document and when it was received, or nil when there is none
    /// or it no longer decodes.
    static func load() -> (payload: TelemetryPayload, at: Date)? {
        guard let blob = UserDefaults.standard.dictionary(forKey: key),
              let raw = blob[payloadField] as? Data,
              let seconds = blob[atField] as? Double,
              let payload = try? MailJSON.decoder.decode(TelemetryPayload.self, from: raw)
        else { return nil }
        return (payload, Date(timeIntervalSince1970: seconds))
    }

    /// Dropped when the app is pointed somewhere else. A cache is a claim about
    /// one collector, and carrying it across a switch would draw the old Pi's
    /// numbers under the new one's address.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
