import AppKit
import SwiftUI

/* ── the masthead's art slot ───────────────────────────────────────────
     ▒▓██████████▓▒      operator@halftone
      ░▓████████▓░       ───────────────────────────
       ░▒▓████▓▒░        collector ..... up 4h 51m

   What stands to the left of the identity block, as a preference.

   Overview shipped with a turning Earth nailed into that slot. This is the
   seam that lets it be something else, and it draws the line at what
   "something else" may be: four things this design system already knows how to
   draw, plus a picture of the reader's own -- and **none**, which is not an
   absence of a choice but a real answer, because the identity column standing
   on its own is exactly what the masthead already does on a window under 720.

   **The width is a column count, not a size.** Everything in the slot is set on
   the character grid: the globe and the orb are preformatted at `cols`
   characters and their height falls out of the cell's own 7x11 aspect, the
   plate is drawn square at the same point width, and the picture is scaled to
   that same width. So one number moves all five, and the art stays in step with
   the type beside it rather than drifting off the grid.

   **The picture is a copy, not a link.** A sandboxed app that stored a path
   would need a security-scoped bookmark to open it again next launch, and a
   masthead that went blank because a folder was renamed is a worse feature than
   no feature. So the file is taken into this app's own container at the moment
   it is picked, and what is stored is the name of that copy.

   **Nothing new moves.** The globe and the orb animate because they always did,
   on their own clocks, and both stop dead under Reduce Motion. The plate is
   static -- it is a still dither by construction -- and a picture is a picture.
*/

enum MastheadArt: String, CaseIterable, Identifiable {
    /// The turning Earth. What Overview shipped with.
    case globe
    /// The assistant's sphere, borrowed off the Jarvis page and recoloured:
    /// there it is gold because it is Jarvis, and here it is not Jarvis.
    case orb
    /// The one-bit dither plate. The system's own mark, and the only art in the
    /// list that holds still.
    case sphere
    /// A picture of the reader's own, from `MastheadImage`.
    case image
    /// No art at all.
    case none

    var id: String { rawValue }

    /// What the setting calls it. The raw value itself, unlike `GroundFamily`
    /// -- these five are already single lowercase words, and inventing prettier
    /// labels for them would put a second vocabulary between the listbox and
    /// the preference for no reading gained.
    var label: String { rawValue }

    /// The one out of the box.
    static let fallback: MastheadArt = .globe

    /// The five names, in declaration order, for the listbox.
    static let labels: [String] = allCases.map(\.label)

    /// The art a name belongs to, or nil. Nil-returning for the same reason
    /// `GroundFamily.named` is: a listbox that grows a sixth name somebody
    /// forgot a case for should do nothing rather than land on the first one.
    static func named(_ label: String) -> MastheadArt? {
        allCases.first { $0.label == label }
    }

    /// What this Mac last chose, validated. Read here rather than only in
    /// `ConsoleSettings` so a raw value this build has no case for lands on the
    /// default instead of being written back out as itself.
    static var stored: MastheadArt {
        MastheadArt(rawValue: UserDefaults.standard.string(forKey: "mastheadArt") ?? "")
            ?? fallback
    }

    /// How agitated the orb's surface is in a masthead: barely.
    ///
    /// A constant, and deliberately not wired to anything. On the Jarvis page
    /// the number is a reading -- the assistant is busy -- and there is nothing
    /// for it to be a reading *of* up here. So it is set low enough that the
    /// surface drifts rather than boils, and the orb says the same thing the
    /// globe says: the console is running.
    static let calm: Double = 0.15

    /// This art at this width, ready for the identity slot -- or nil, which is
    /// what `none` is and what a `Masthead` already understands: the slot goes
    /// away and the identity column stands alone, exactly as it does under 720.
    ///
    /// The caller passes the two other preferences in rather than reading them
    /// here, so every read of the settings object happens inside the view body
    /// that draws this -- which is the whole of the live binding. A read taken
    /// in here would be a read SwiftUI's observation could not see.
    func view(cols: Int, imageFile: String?) -> AnyView? {
        switch self {
        case .globe:
            return AnyView(GlobeView(cols: cols))
        case .orb:
            return AnyView(OrbView(cols: cols, activity: MastheadArt.calm,
                                   ink: HT.signal, label: "Orb"))
        case .sphere:
            return AnyView(MastheadPlate(cols: cols))
        case .image:
            return AnyView(MastheadPicture(name: imageFile ?? "", cols: cols))
        case .none:
            return nil
        }
    }
}

// MARK: - the plate

/// The dither plate at the art column's width, square.
///
/// Square because the other two are: a globe or an orb `cols` characters wide
/// comes out `cols * 7` points tall as well, since the cell is 7x11 and the row
/// count is `cols * 7 / 11`. So one number gives all three the same footprint
/// and switching between them does not move the identity block beside them.
private struct MastheadPlate: View {
    var cols: Int

    var body: some View {
        let side = CGFloat(cols) * HT.cw
        DitherPlate(pattern: .sphere, scale: 3, aspect: 1)
            .frame(width: side, height: side)
    }
}

// MARK: - the picture

/// The imported picture, drawn plain.
///
/// **No dithering, no frame, no treatment.** Everything else in this console is
/// put through the house's own ramp, and this one thing deliberately is not: a
/// picture somebody chose is a picture, and a version of it halftoned into the
/// ink ramp would be this app's opinion of their photograph.
///
/// Scaled to the art column's width and no further -- the height follows the
/// picture's own aspect, so a wide one is short and a tall one is tall, and
/// neither is cropped or stretched.
///
/// A file that is not there falls back to the globe. That covers three cases
/// with one answer: nothing has been picked yet, the copy was deleted out from
/// under the app, or the stored name is unreadable. Settings says which.
private struct MastheadPicture: View {
    var name: String
    var cols: Int

    var body: some View {
        let stamp = MastheadImage.stamp(name)
        if let picture = MastheadImage.picture(name, stamp: stamp),
           picture.size.width > 0, picture.size.height > 0 {
            let width = CGFloat(cols) * HT.cw
            Image(nsImage: picture)
                .resizable()
                .aspectRatio(picture.size, contentMode: .fit)
                .frame(width: width,
                       height: (width * picture.size.height / picture.size.width).rounded())
                // Hidden, like the plate and unlike the globe: those two are
                // this system's own drawings and can be named honestly, and
                // there is no honest label for a picture nobody described. The
                // identity block beside it is the reading.
                .accessibilityHidden(true)
        } else {
            GlobeView(cols: cols)
        }
    }
}

// MARK: - the picture on disk

/// Where an imported picture lives, and how it gets there.
///
/// One folder, one file. The folder is inside this app's own Application
/// Support container -- which for a sandboxed app is inside the container, not
/// in the user's Library -- so nothing here is reachable by anything else and
/// nothing here needs an entitlement. The single entitled act in the whole
/// feature is the open panel, and that is the user choosing a file.
enum MastheadImage {

    /// The folder. A subfolder rather than Application Support itself, because
    /// `adopt` sweeps whatever it finds beside the file it just wrote -- and a
    /// sweep at the root of Application Support would one day delete something
    /// another part of this app had put there.
    static var folder: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Masthead", isDirectory: true)
    }

    /// The file a stored name refers to.
    ///
    /// **A name, never a path.** What is stored is a filename inside the one
    /// folder above, so anything with a separator in it -- however it got into
    /// the preference -- is refused rather than resolved.
    static func url(_ name: String) -> URL? {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent else { return nil }
        return folder?.appendingPathComponent(name, isDirectory: false)
    }

    /// The file's own modification date, as a string, or "" when there is no
    /// such file.
    ///
    /// This is both halves of "is it still there" and "is it still the same
    /// one". The name is stable on purpose -- one picture at a time -- so the
    /// name alone cannot tell a replacement from the file it replaced, and a
    /// view keyed on the name alone would go on drawing the old picture.
    static func stamp(_ name: String) -> String {
        guard let url = url(name),
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let when = values.contentModificationDate else { return "" }
        return "\(when.timeIntervalSinceReferenceDate)"
    }

    /// The decoded picture, held.
    ///
    /// A memo of exactly one, not a cache with a policy: there is one picture in
    /// this app and the masthead's body runs on every poll. Keyed on the name
    /// **and** the stamp, so replacing the file under the same name is a
    /// different key and is read again.
    ///
    /// `nonisolated(unsafe)` and not a lock, for the same reason `Ground`'s
    /// cache is: it is touched from view bodies and from Settings, both of which
    /// are the main actor.
    private nonisolated(unsafe) static var memo: (key: String, picture: NSImage)?

    static func picture(_ name: String, stamp: String) -> NSImage? {
        guard !stamp.isEmpty, let url = url(name) else { return nil }
        let key = "\(name)|\(stamp)"
        if let memo, memo.key == key { return memo.picture }
        guard let picture = NSImage(contentsOf: url) else { return nil }
        memo = (key, picture)
        return picture
    }

    /// Take a copy of the file somebody picked, and hand back its name.
    ///
    /// The name is this app's, not the source's: one picture at a time means one
    /// filename, and keeping the reader's own would leave the container growing
    /// a collection of every picture ever tried. The extension is carried over
    /// so the copy is still recognisably what it was, which is also why the
    /// sweep at the end exists -- a JPEG picked after a PNG lands under a
    /// different name, and the PNG would otherwise sit there forever.
    static func adopt(_ source: URL) throws -> String {
        guard let folder else { throw MastheadImageFault.noFolder }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let ext = source.pathExtension.lowercased()
        let name = ext.isEmpty ? "masthead" : "masthead.\(ext)"
        let destination = folder.appendingPathComponent(name, isDirectory: false)

        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)

        for stale in (try? fm.contentsOfDirectory(at: folder,
                                                  includingPropertiesForKeys: nil)) ?? []
        where stale.lastPathComponent != name {
            try? fm.removeItem(at: stale)
        }
        return name
    }
}

/// The one thing that can go wrong before the copy is even attempted.
enum MastheadImageFault: LocalizedError {
    case noFolder

    var errorDescription: String? {
        switch self {
        case .noFolder:
            return "this app has no Application Support folder to copy it into"
        }
    }
}
