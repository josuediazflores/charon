import AVFoundation
import Foundation
import Observation

/* The speaker: sentences in, one voice out -- ported from the web console's
 * speaker hook onto AVFoundation.
 *
 * **One queue, one pump, one player.** Sentences arrive from the extractor
 * faster than they can be said, so they queue, and a single async pump plays
 * them strictly in order: fetch the WAV, decode it, play it, next. Two
 * pipelines would let two sentences overlap the moment a fetch came back out of
 * order, and an assistant talking over itself is worse than one running a
 * sentence behind.
 *
 * **A nil from the tts route ends the turn's speech, not the feature.** Nil is
 * the route's word for 502/503 -- the Mac is asleep or tts is not configured --
 * and retrying per sentence would fire a doomed request every second for the
 * length of the answer. So the queue drops, `unavailable` goes up for the view
 * to draw as a dim word, and the next `cancel()` (a new turn, a barge-in, the
 * toggle) clears the slate and tries again.
 *
 * **Cancel stops the sound AND drops the queue.** Barge-in means "stop
 * talking", not "finish these four sentences first" -- a cancel that only
 * silenced the current buffer would have the voice resume mid-answer over the
 * reader's next question.
 *
 * Two things in the web version are deliberately absent. `unlock()` existed for
 * the browser's autoplay policy, which a native app does not have; and the
 * `speechSynthesis` scaffold was a dev flag for proving queue timing without
 * the Mac, which is not the shipped voice and has no reason to be built twice.
 */

@MainActor
@Observable
final class Speaker {

    /// Audio is playing right now. What the presence word reads.
    private(set) var speaking = false

    /// This turn's speech gave up on the Mac. A dim word, never a fault: the
    /// text lane is whole and the answer is on screen.
    private(set) var unavailable = false

    /// The one canned line that plays ON failure rather than instead of
    /// synthesis. The shelf is in the bundle, so "the Mac's asleep" can be said
    /// out loud by the very voice that just went away.
    private static let deadLine = "The Mac's asleep, so it's text only for now."

    @ObservationIgnored private var store: ConsoleStore?
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var pumping = false
    /// Bumped by every cancel. An await that comes back to a different
    /// generation belongs to a speech that no longer exists and must not play,
    /// enqueue, or mark anything.
    @ObservationIgnored private var gen = 0
    /// `unavailable`, readable synchronously inside the pump.
    @ObservationIgnored private var dead = false
    /// Consecutive synthesis misses. One failed sentence is that sentence's
    /// problem; two in a row is an outage. See the pump.
    @ObservationIgnored private var misses = 0
    @ObservationIgnored private var inflight: Task<Data?, Never>?
    /// Sentence N+1's synthesis, started while N plays. See the pump.
    @ObservationIgnored private var prefetch: (sentence: String, task: Task<Data?, Never>)?
    @ObservationIgnored private var player: AVAudioPlayer?
    /// Held only so ARC does not take the failure line away mid-sentence.
    @ObservationIgnored private var deadPlayer: AVAudioPlayer?
    @ObservationIgnored private var playDone: CheckedContinuation<Void, Never>?
    @ObservationIgnored private let bridge = PlayerBridge()

    init() {
        bridge.onFinish = { [weak self] in
            Task { @MainActor in self?.finishPlayback() }
        }
    }

    /// Point it at the collector. Re-pointed rather than reconstructed, because
    /// the connection can move under a page that is already open.
    func bind(_ store: ConsoleStore?) { self.store = store }

    // MARK: - the public shape

    /// One complete sentence onto the queue. Trimmed; empty is ignored; ignored
    /// entirely while the turn's speech is marked unavailable.
    func enqueue(_ sentence: String) {
        guard !dead else { return }
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queue.append(text)
        pump()
    }

    /// Stop the current audio and drop everything queued. Also clears
    /// `unavailable`, so the next turn gets to try the Mac again.
    func cancel() {
        gen &+= 1
        queue.removeAll()
        dead = false
        misses = 0
        inflight?.cancel()
        inflight = nil
        // The prefetched sentence is queued audio by another name; barge-in
        // means it must die with the queue, or the next turn opens with a stale
        // line.
        prefetch?.task.cancel()
        prefetch = nil
        player?.stop()
        player = nil
        // `stop()` does not call the delegate, so the pump's await is unblocked
        // here rather than orphaned.
        finishPlayback()
        unavailable = false
        speaking = false
    }

    /// Fire-and-forget warm ping, so the Mac's model is loading while the turn
    /// is still being asked. Errors are the callee's to swallow.
    func warm() { store?.jarvisWarmTts() }

    // MARK: - the pump

    private func pump() {
        guard !pumping else { return }
        pumping = true
        let mine = gen
        Task { await run(mine) }
    }

    private func run(_ mine: Int) async {
        while !queue.isEmpty, gen == mine, !dead {
            let sentence = queue[0]

            // **The current sentence's audio, prefetched if the last loop
            // iteration started it, fetched now if not.** Playback stays
            // strictly ordered -- that is the one-pump rule and it does not bend
            // -- and what overlaps is only sentence N's playback with sentence
            // N+1's synthesis, which is the overlap a 4-6x realtime voice exists
            // to win.
            let pending: Task<Data?, Never>
            if let held = prefetch, held.sentence == sentence {
                pending = held.task
            } else {
                pending = synth(sentence)
            }
            prefetch = nil
            inflight = pending
            var blob = await pending.value
            inflight = nil
            // Generation before interpretation: a cancelled fetch also returns
            // nil, and reading that as "the Mac is down" would mark a healthy
            // service unavailable on every barge-in.
            if gen != mine { break }

            // **One miss gets a retry; a lone failure after that gets skipped;
            // only two in a row is an outage.** Any-null-ends-the-turn was
            // written for "the Mac is asleep" and it turned one crashed sentence
            // into a briefing that stopped at sentence four of ten.
            if blob == nil {
                let retry = synth(sentence)
                inflight = retry
                blob = await retry.value
                inflight = nil
                if gen != mine { break }
            }
            if blob != nil {
                misses = 0
            } else if misses == 0 {
                misses = 1
                queue.removeFirst()
                continue
            }
            guard let data = blob else {
                dead = true
                unavailable = true
                queue.removeAll()
                sayDeadLine(mine)
                break
            }
            queue.removeFirst()

            // Kick the NEXT sentence's synthesis before this one starts playing.
            // One ahead and no further: a deeper lookahead would race barge-in
            // with a queue of already-paid-for audio, and one is enough to hide
            // the round trip behind multi-second playback.
            if let next = queue.first {
                prefetch = (sentence: next, task: synth(next))
            }

            // One undecodable WAV skips one sentence. Not `dead`: the next fetch
            // is the test of whether the service is actually in trouble.
            guard let sound = try? AVAudioPlayer(data: data) else { continue }
            if gen != mine { break }

            speaking = true
            await play(sound)
        }

        pumping = false
        if gen == mine { speaking = false }
        // A cancel mid-await may have let new sentences queue behind a pump that
        // was already exiting. They are real; hand them a fresh pump.
        if !queue.isEmpty, !dead { pump() }
    }

    private func synth(_ sentence: String) -> Task<Data?, Never> {
        Task { [weak self] in await self?.fetchAudio(sentence) ?? nil }
    }

    /// The shelf first, the Mac second. A canned file that fails to read falls
    /// through to synthesis rather than to silence -- the shelf is an
    /// optimisation, never a gate.
    private func fetchAudio(_ sentence: String) async -> Data? {
        if let shelved = Speaker.canned(sentence) { return shelved }
        guard let store else { return nil }
        return await store.jarvisTts(text: sentence)
    }

    private func play(_ sound: AVAudioPlayer) async {
        sound.delegate = bridge
        player = sound
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            playDone = continuation
            if !sound.play() { finishPlayback() }
        }
        if player === sound { player = nil }
    }

    private func finishPlayback() {
        guard let continuation = playDone else { return }
        playDone = nil
        continuation.resume()
    }

    private func sayDeadLine(_ mine: Int) {
        guard gen == mine,
              let data = Speaker.canned(Speaker.deadLine),
              let sound = try? AVAudioPlayer(data: data)
        else { return }
        deadPlayer = sound
        sound.play()
    }

    // MARK: - the canned shelf

    /* Pre-synthesized sentences, generated once by the tts service and shipped
       in the bundle. The pump checks this shelf before spending a synth round
       trip, so any sentence Jarvis says verbatim -- the greetings and
       acknowledgments his standing instructions offer him -- plays at once, and
       keeps playing when the Mac is asleep, because these never touch the
       collector at all.

       Keyed by EXACT sentence text, the extractor's own unit, which is what
       makes the lookup honest: the generator splits phrases with the same
       terminator rule the extractor uses, so a canned line and a spoken line can
       only collide when they are the same words. */

    @ObservationIgnored
    private static let shelf: [String: String] = {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json",
                                        subdirectory: "Canned"),
              let data = try? Data(contentsOf: url),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = doc["entries"] as? [String: String]
        else { return [:] }
        return entries
    }()

    private static func canned(_ sentence: String) -> Data? {
        guard let file = shelf[sentence],
              let url = Bundle.main.url(forResource: file, withExtension: nil,
                                        subdirectory: "Canned")
        else { return nil }
        return try? Data(contentsOf: url)
    }
}

/// `AVAudioPlayer` reports the end of a sound to a delegate rather than to a
/// continuation, so one object stands between the two. A natural end arrives
/// here; a `stop()` does not, which is why `cancel()` resumes the pump itself.
private final class PlayerBridge: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish?()
    }
}
