import SwiftUI

/* One window, one ground to the edges.
 *
 * The window is named for whatever tab is showing -- `ConsoleShellView` sets
 * that, because it is the only thing that knows -- and the title bar is painted
 * out so the band the traffic lights sit in is the same ground as the rail
 * under it. That ground is the window's own backdrop, mounted by `WindowChrome`
 * in ConsoleShellView.swift; the scene hands the pane through rather than
 * filling it a second time.
 *
 * The product is still `HalftoneMail` and the bundle id still
 * `com.example.charon`: renaming either would orphan the token in the
 * Keychain. Only the name on the outside changed.
 */

@main
struct HalftoneMailApp: App {
    var body: some Scene {
        WindowGroup("Halftone") {
            ConsoleShellView()
                .background(Color.clear)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Nothing in this app makes a second document, and a New Window
            // item that mints a second poller against the same collector is
            // worse than no item at all.
            CommandGroup(replacing: .newItem) { }
        }
    }
}
