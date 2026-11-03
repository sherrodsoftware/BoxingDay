import SwiftUI

/// Actions the focused window offers to the menu bar. A nil action means
/// the command is unavailable, and its menu item is disabled.
struct PackageCommandActions {
    var chooseFile: (() -> Void)?
    var build: (() -> Void)?
    var upload: (() -> Void)?
    var reveal: (() -> Void)?
}

extension FocusedValues {
    @Entry var packageCommands: PackageCommandActions?
}

struct PackageCommands: Commands {
    @FocusedValue(\.packageCommands) private var actions

    var body: some Commands {
        // Boxing Day works in a single window, so Open… takes the place of
        // New Window in the File menu.
        CommandGroup(replacing: .newItem) {
            Button("Open…") { actions?.chooseFile?() }
                .keyboardShortcut("o")
                .disabled(actions?.chooseFile == nil)
        }

        CommandMenu("Package") {
            Button("Build Package…") { actions?.build?() }
                .keyboardShortcut("b")
                .disabled(actions?.build == nil)

            Button("Upload to Jamf Pro…") { actions?.upload?() }
                .keyboardShortcut("u")
                .disabled(actions?.upload == nil)

            Divider()

            Button("Reveal in Finder") { actions?.reveal?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.reveal == nil)
        }
    }
}
