import AVFoundation
import SwiftUI

struct BriefPlaybackView: View {
    let store: ConsoleStore
    let brief: DailyBrief
    @State private var playback = BriefPlayback()

    var body: some View {
        VStack(spacing: 9) {
            Button {
                playback.toggle(store: store, brief: brief)
            } label: {
                HStack(spacing: 8) {
                    if playback.loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                    }
                    Text(playback.label).fontWeight(.semibold)
                }
                .padding(.horizontal, 18).frame(height: 40)
                .foregroundStyle(FocusInk.ground)
                .background(FocusInk.text, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(playback.loading || brief.spokenText.isEmpty || store is DemoStore)
            if store is DemoStore {
                Text("Connect to your Pi for narrated briefs.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let message = playback.error {
                Text(message).multilineTextAlignment(.center)
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onDisappear { playback.stop() }
        .onChange(of: brief.spokenText) { playback.stop() }
        .onChange(of: brief.date) { playback.stop() }
    }
}

@Observable @MainActor
private final class BriefPlayback: NSObject, @preconcurrency AVAudioPlayerDelegate {
    private(set) var loading = false
    private(set) var playing = false
    private var finished = false
    private(set) var error: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var download: Task<Void, Never>?

    var label: String {
        if loading { return "Preparing audio" }
        if playing { return "Pause brief" }
        if finished { return "Replay brief" }
        return player == nil ? "Play brief" : "Resume brief"
    }

    func toggle(store: ConsoleStore, brief: DailyBrief) {
        error = nil
        if playing {
            player?.pause()
            playing = false
        } else if let player {
            if finished { player.currentTime = 0 }
            play(player)
        } else if !loading {
            loading = true
            download = Task {
                do {
                    let data = try await store.dailyBriefAudio(day: brief.date, spoken: brief.spokenText)
                    try Task.checkCancellation()
                    let sound = try AVAudioPlayer(data: data)
                    sound.delegate = self
                    player = sound
                    play(sound)
                } catch {
                    if Task.isCancelled { return }
                    self.error = error.localizedDescription
                }
                loading = false
                download = nil
            }
        }
    }

    private func play(_ sound: AVAudioPlayer) {
        finished = false
        playing = sound.play()
        if !playing {
            player = nil
            error = "Could not play the recording."
        }
    }

    func stop() {
        download?.cancel()
        download = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        loading = false
        playing = false
        finished = false
        error = nil
    }

    func audioPlayerDidFinishPlaying(_ sound: AVAudioPlayer, successfully flag: Bool) {
        guard sound === player else { return }
        playing = false
        finished = flag
        if !flag {
            player = nil
            error = "Playback was interrupted. Try again."
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ sound: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(sound, successfully: false)
    }
}
