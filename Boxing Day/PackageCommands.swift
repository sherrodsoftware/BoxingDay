import SwiftUI

extension FocusedValues {
    /// The focused window's model. The menu bar reads availability from it
    /// and calls its actions; a model reference compares by identity, so
    /// the menus refresh only when the model changes what they read.
    @Entry var packagingModel: PackagingModel?
}

struct PackageCommands: Commands {
    @FocusedValue(\.packagingModel) private var model

    var body: some Commands {
        // Boxing Day works in a single window, so Open… takes the place of
        // New Window in the File menu.
        CommandGroup(replacing: .newItem) {
            OpenMenuItem(model: model)
        }

        CommandMenu("Package") {
            BuildPackageMenuItem(model: model)
            UploadMenuItem(model: model)
            Divider()
            RevealInFinderMenuItem(model: model)
        }
    }
}

// Each menu item is a View so that Observation tracks what it reads and
// updates its enabled state as the model changes.

private struct OpenMenuItem: View {
    let model: PackagingModel?

    var body: some View {
        Button("Open…") { model?.chooseFile() }
            .keyboardShortcut("o")
            .disabled(!(model?.canChooseFile ?? false))
    }
}

private struct BuildPackageMenuItem: View {
    let model: PackagingModel?

    var body: some View {
        Button("Build Package…") { model?.chooseBuildDestination() }
            .keyboardShortcut("b")
            .disabled(!(model?.canBuildFromMenu ?? false))
    }
}

private struct UploadMenuItem: View {
    let model: PackagingModel?

    var body: some View {
        Button("Upload to Jamf Pro…") { model?.presentUpload() }
            .keyboardShortcut("u")
            .disabled(!(model?.canUpload ?? false))
    }
}

private struct RevealInFinderMenuItem: View {
    let model: PackagingModel?

    var body: some View {
        Button("Reveal in Finder") { model?.revealCompletedPackage() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!(model?.canRevealCompletedPackage ?? false))
    }
}
