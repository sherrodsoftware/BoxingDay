import Combine
import Sparkle
import SwiftUI

/// Publishes whether Sparkle can start a user-initiated update check, so
/// the menu item is disabled while a check is already in progress.
@MainActor
@Observable
final class UpdateAvailability {
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var cancellable: AnyCancellable?

    init(updater: SPUUpdater) {
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
    }
}

/// Adds "Check for Updates…" below "About Boxing Day" in the app menu.
struct UpdateCommands: Commands {
    let updater: SPUUpdater
    let availability: UpdateAvailability

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesMenuItem(updater: updater, availability: availability)
        }
    }
}

/// A View, so Observation tracks `canCheckForUpdates` and the item's enabled
/// state follows Sparkle while a check is running.
private struct CheckForUpdatesMenuItem: View {
    let updater: SPUUpdater
    let availability: UpdateAvailability

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!availability.canCheckForUpdates)
    }
}
