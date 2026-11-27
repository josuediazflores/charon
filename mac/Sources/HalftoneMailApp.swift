import SwiftUI

// The scene keeps the native window controls. The sidebar provides their backdrop.
@main
struct HalftoneMailApp: App {
    var body: some Scene {
        WindowGroup("Halftone") {
            ConsoleShellView()
                .background(Color.clear)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Nothing in this app makes a second document, and a New Window
            // item that mints a second poller against the same collector is
            // worse than no item at all.
            CommandGroup(replacing: .newItem) { }
            ConsoleCommands()
        }
    }
}

extension FocusedValues {
    @Entry var consoleModel: MailModel?
    @Entry var destinationPickerOpen: Binding<Bool>?
}

private struct ConsoleCommands: Commands {
    @FocusedValue(\.consoleModel) private var model
    @FocusedBinding(\.destinationPickerOpen) private var pickerOpen

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Go to Destination…") { pickerOpen?.toggle() }
                .keyboardShortcut("k")
                .disabled(pickerOpen == nil || model?.showingConnection == true)
            Button("Refresh") { Task { await model?.refresh() } }
                .keyboardShortcut("r")
                .disabled(model == nil || model?.showingConnection == true)
        }
    }
}
