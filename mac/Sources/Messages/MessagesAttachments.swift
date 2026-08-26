import AVKit
import AppKit
import SwiftUI

/* The photographs, inside the bubbles.
 *
 * **This app never opens `~/Library/Messages`.** It is sandboxed and could
 * not; the Mac that can is Charon Bridge, which is a different program with
 * Full Disk Access and no window. So every tile here talks to the Pi and only
 * to the Pi -- either the bytes are already there, in which case this is a
 * fetch, or they are not, in which case `fetch` files a want and the Bridge
 * next door answers it a few seconds later. That indirection is not a
 * workaround; it is the same rule the rest of the channel keeps, which is that
 * nothing on this side reads the database.
 *
 * Four tiles and one rule for choosing between them: what the row said it was,
 * and whether the Pi says it holds the bytes. A photograph it holds is drawn.
 * One it does not is a line offering to ask. A video is a line either way,
 * because a still frame of a video is a thing this app would have to invent.
 * And a file Messages has aged off the Mac is a line that says so and offers
 * nothing, which is the only honest tile of the four.
 *
 * HEIC is drawn as HEIC. Nothing transcodes anywhere in this system -- the
 * Bridge sends what the camera wrote and `NSImage` decodes it here, which is
 * one of the few things a Mac app gets for free that a browser does not.
 */

/// How wide and tall a drawn photograph may be inside a bubble.
private let tileMax: CGFloat = 280
/// How often a tile looks again after asking for a file, and for how long.
/// Two seconds is the Bridge's own poll plus the time to read a file off a
/// laptop's disk; three minutes is longer than a Mac that is awake will ever
/// take and shorter than a person will wait for one that is asleep.
private let fetchEvery: Duration = .seconds(2)
private let fetchFor = 90
/// The same 160 ms an arriving bubble fades in over. One arrival, one speed.
private let arrival: Animation = .easeOut(duration: 0.16)

// MARK: - the cache

/// Fetched attachments, kept between launches.
///
/// `~/Library/Caches/<bundle>/messages-attachments/<key>-<n>`, which inside
/// the sandbox is the app's own container and outside it is the same path
/// under a real home directory. Caches rather than Application Support on
/// purpose: every byte in here is a copy of something the Pi holds, so the
/// worst a purge costs is one round trip.
///
/// Named by the key and the position and nothing else, which is what makes the
/// name safe: neither half of it ever came from a filename. The extension is
/// put back only when a file is handed to another program, and it is put back
/// from the name the collector already sanitised.
enum AttachmentCache {

    static let room: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory,
                                                    in: .userDomainMask).first
        else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? "com.example.charon"
        let room = caches
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("messages-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: room,
                                                 withIntermediateDirectories: true)
        return room
    }()

    static func file(_ key: String, _ n: Int) -> URL? {
        room?.appendingPathComponent("\(key)-\(n)")
    }

    static func read(_ key: String, _ n: Int) -> Data? {
        guard let file = file(key, n) else { return nil }
        return try? Data(contentsOf: file)
    }

    static func write(_ data: Data, key: String, n: Int) {
        guard let file = file(key, n) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// The same bytes under a name another program will understand.
    ///
    /// AVKit and the Finder both work off an extension, and the cache
    /// deliberately has none -- a filename in a path is a filename somebody
    /// else chose. So a copy is made when a file is handed over, named from
    /// the string the collector already rebuilt from a safe alphabet, in this
    /// process's own temporary directory.
    static func handoff(_ data: Data, named: String, key: String, n: Int) -> URL? {
        let safe = safeName(named, key: key, n: n)
        let room = FileManager.default.temporaryDirectory
            .appendingPathComponent("charon-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: room,
                                                 withIntermediateDirectories: true)
        let file = room.appendingPathComponent(safe)
        if let held = try? Data(contentsOf: file), held == data { return file }
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }

    /// A filename this app is willing to put in a path. The collector's own
    /// alphabet, kept a third time, because the string arrives over a wire and
    /// a name is only as safe as the last program to look at it.
    static func safeName(_ raw: String, key: String, n: Int) -> String {
        var out = ""
        var dashed = false
        for character in raw {
            if character.isASCII,
               character.isLetter || character.isNumber
                   || character == "." || character == "_" || character == "-" {
                out.append(character)
                dashed = false
            } else if !dashed {
                out.append("-")
                dashed = true
            }
        }
        while let first = out.first, first == "-" || first == "." { out.removeFirst() }
        while let last = out.last, last == "-" || last == "." { out.removeLast() }
        if out.count > 100 { out = String(out.prefix(100)) }
        return out.isEmpty ? "\(key)-\(n)" : out
    }
}

// MARK: - the tiles

/// Everything one row has attached, under whatever it said.
///
/// Inside the bubble rather than beside it, because an attachment is part of
/// the message and not a note about it -- the same reason the text is in there.
struct AttachmentTiles: View {

    let key: String
    let attachments: [MessageAttachment]
    let model: MailModel
    /// Show one photograph big. The pane owns that view, because "as wide as
    /// the pane" is not something a bubble can be.
    var onLift: (LiftedAttachment) -> Void
    /// A photograph landed and the bubble it is in just got four hundred
    /// points taller. The log owns the scroll, so it is the log that is told.
    var onGrow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(attachments) { attachment in
                AttachmentTile(key: key, attachment: attachment, model: model,
                               onLift: onLift, onGrow: onGrow)
            }
        }
    }
}

/// One photograph shown at the size of the pane, and what it is called.
struct LiftedAttachment: Equatable, Identifiable {
    var key: String
    var n: Int
    var name: String
    var image: NSImage

    var id: String { "\(key)-\(n)" }

    static func == (a: LiftedAttachment, b: LiftedAttachment) -> Bool { a.id == b.id }
}

struct AttachmentTile: View {

    let key: String
    let attachment: MessageAttachment
    let model: MailModel
    var onLift: (LiftedAttachment) -> Void
    var onGrow: () -> Void

    /// What this tile is doing, which is not quite what the record says: the
    /// record's `stored` is the Pi's answer at the moment the thread was read,
    /// and a tile that has just asked for a file is ahead of it.
    private enum Stage: Equatable { case idle, asking, here, refused }

    @State private var stage: Stage = .idle
    @State private var bytes: Data?
    @State private var image: NSImage?
    @State private var hover = false
    @State private var watching: URL?
    @State private var poll: Task<Void, Never>?

    var body: some View {
        content
            .task(id: "\(key)-\(attachment.n)-\(attachment.stored)") { await open() }
            .onDisappear { poll?.cancel() }
            .sheet(item: Binding(get: { watching.map(Playing.init) },
                                 set: { if $0 == nil { watching = nil } })) { playing in
                VideoSheet(file: playing.url) { watching = nil }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let image, attachment.kind == .image {
            Button {
                onLift(LiftedAttachment(key: key, n: attachment.n,
                                        name: attachment.filename, image: image))
            } label: {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: tileMax, maxHeight: tileMax)
                    // The bubble's own corner, so a photograph sits in it
                    // rather than on it.
                    .clipShape(RoundedRectangle(cornerRadius: M.r, style: .continuous))
                    .accessibilityLabel(attachment.filename)
            }
            .buttonStyle(.plain)
            .transition(.opacity)
            .animation(arrival, value: image)
        } else {
            line
        }
    }

    // MARK: the quiet line

    private var line: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { at, word in
                if at > 0 {
                    Text("·").font(Face.body).foregroundStyle(M.lineStrong)
                }
                Text(word).font(Face.body).foregroundStyle(ink)
            }
            if let act {
                Text("·").font(Face.body).foregroundStyle(M.lineStrong)
                Text(act)
                    .font(Face.body)
                    .foregroundStyle(hover ? M.inkBright : M.inkMid)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: M.rSm, style: .continuous)
            .fill(M.raised))
        .contentShape(RoundedRectangle(cornerRadius: M.rSm, style: .continuous))
        .onHover { hover = act != nil && $0 }
        .animation(M.move, value: hover)
        .onTapGesture {
            guard let word = act else { return }
            Task { await perform(word) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(words.joined(separator: ", "))
    }

    /// The words before the verb. What kind of thing it is, then the name when
    /// the name is worth reading, then how big it is.
    ///
    /// A photograph's name is not worth reading -- `IMG_0412.heic` is the
    /// camera talking -- so it is left out and the size stands alone. A file's
    /// is the whole of what it is.
    private var words: [String] {
        if attachment.missing { return [noun, "not on this Mac"] }
        var out = [noun]
        if attachment.kind != .image, !attachment.filename.isEmpty {
            out.append(attachment.filename)
        }
        if let size = attachment.totalBytes, size > 0 { out.append(Fmt.bytes(size)) }
        if stage == .asking { out.append("fetching…") }
        if stage == .refused { out.append("could not be fetched") }
        return out
    }

    private var noun: String {
        if attachment.isSticker { return "sticker" }
        switch attachment.kind {
        case .image: return "photo"
        case .video: return "video"
        case .file: return "file"
        }
    }

    private var ink: Color { attachment.missing ? M.inkDim : M.inkMid }

    /// The one word you can press, or none.
    private var act: String? {
        if attachment.missing || stage == .asking { return nil }
        if bytes == nil { return "fetch" }
        return attachment.kind == .video ? "play" : "open"
    }

    private func perform(_ word: String) async {
        switch word {
        case "fetch": await ask()
        case "play", "open": hand(over: word)
        default: break
        }
    }

    // MARK: what it does

    /// The bytes, if anybody already has them. The cache first, because the
    /// same photograph is drawn every time the thread is scrolled past it.
    private func open() async {
        guard !attachment.missing else { return }
        if bytes == nil, let held = AttachmentCache.read(key, attachment.n) {
            adopt(held)
            return
        }
        guard attachment.stored, bytes == nil else { return }
        if let fetched = await model.store.attachmentData(key: key, n: attachment.n) {
            AttachmentCache.write(fetched, key: key, n: attachment.n)
            adopt(fetched)
        }
    }

    /// Ask the Bridge for it, then keep looking until it turns up.
    ///
    /// The want is a request rather than the act: it lands in a spool on the
    /// Pi, the Bridge reads it on its next poll, and the bytes arrive a few
    /// seconds later. So the tile watches for them itself rather than waiting
    /// for the thread's own ten-second refresh -- a tap should not take ten
    /// seconds to show anything.
    private func ask() async {
        stage = .asking
        guard await model.store.wantAttachment(key: key, n: attachment.n) else {
            stage = .refused
            return
        }
        poll?.cancel()
        poll = Task { @MainActor in
            for _ in 0..<fetchFor {
                try? await Task.sleep(for: fetchEvery)
                if Task.isCancelled { return }
                if let fetched = await model.store.attachmentData(key: key,
                                                                  n: attachment.n) {
                    AttachmentCache.write(fetched, key: key, n: attachment.n)
                    adopt(fetched)
                    return
                }
            }
            if stage == .asking { stage = .refused }
        }
    }

    private func adopt(_ data: Data) {
        bytes = data
        stage = .here
        guard attachment.kind == .image else { return }
        // Decoded here rather than in the body, so scrolling past a thread of
        // photographs is not a thread of decodes.
        image = NSImage(data: data)
        if image == nil {
            stage = .refused
            return
        }
        // A line became a picture, which is three hundred points of new
        // height under whatever was on screen. The log follows its own bottom
        // when a run arrives and this is the same event by another route.
        onGrow()
    }

    /// Out of this app and into another one. A copy under a name the Finder
    /// and AVKit will understand; the cache's own name has no extension on
    /// purpose.
    private func hand(over word: String) {
        guard let bytes,
              let file = AttachmentCache.handoff(bytes, named: attachment.filename,
                                                 key: key, n: attachment.n)
        else { return }
        if word == "play" {
            watching = file
        } else {
            NSWorkspace.shared.open(file)
        }
    }
}

/// A URL, wrapped so `.sheet(item:)` can key on it.
private struct Playing: Identifiable, Equatable {
    let url: URL
    var id: String { url.path }
}

/// One video, in a sheet, from a file this app already has.
///
/// AVKit's own controls and nothing else: a player skinned in Departure Mono
/// would be a worse player and a bigger one, and this is the one surface in
/// the app where the system's answer is better than ours.
private struct VideoSheet: View {
    let file: URL
    var onClose: () -> Void

    /// Made once and held. A player built in `body` is a new player on every
    /// redraw, which is a video that restarts itself.
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Spacer()
                HTButton(title: "close", variant: .quiet, size: .sm) { onClose() }
            }
            .padding(10)
        }
        .frame(width: 640, height: 420)
        .background(Ground.current.void)
        .onAppear { player = AVPlayer(url: file) }
        .onDisappear { player?.pause() }
        .onKeyPress(.escape) { onClose(); return .handled }
    }
}

// MARK: - the lifted photograph

/// One photograph, as big as the pane will allow.
///
/// An overlay rather than a window or a sheet. A bubble is capped at two
/// thirds of the log by design, and a photograph inside one is capped with it;
/// this is the only way to see it whole without leaving the conversation, and
/// leaving the conversation is the thing the cap was protecting.
struct LiftedAttachmentView: View {

    let lifted: LiftedAttachment
    var onClose: () -> Void

    @FocusState private var held: Bool

    var body: some View {
        ZStack {
            Ground.current.void.opacity(0.92)
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
            VStack(alignment: .leading, spacing: 6) {
                Image(nsImage: lifted.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: M.r, style: .continuous))
                HStack(spacing: 4) {
                    Text(lifted.name).font(Face.body).foregroundStyle(M.inkMid)
                    Text("·").font(Face.body).foregroundStyle(M.lineStrong)
                    Text("esc").font(Face.body).foregroundStyle(M.inkDim)
                }
                .lineLimit(1)
            }
            .padding(18)
            .onTapGesture { onClose() }
        }
        .focusable()
        .focused($held)
        .onKeyPress(.escape) { onClose(); return .handled }
        .onAppear { held = true }
        .transition(.opacity)
        .accessibilityLabel(lifted.name)
    }
}
