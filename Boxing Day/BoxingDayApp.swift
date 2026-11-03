import AppKit
import Sparkle
import SwiftUI

@main
struct BoxingDayApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    /// Sparkle reads SUFeedURL and SUPublicEDKey from Info.plist and checks
    /// for updates on its own schedule once the user allows it.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private let updateAvailability: UpdateAvailability

    init() {
        updateAvailability = UpdateAvailability(
            updater: updaterController.updater
        )
    }

    var body: some Scene {
        // Boxing Day works on one item at a time, so it has a single window.
        Window("Boxing Day", id: "main") {
            ContentView()
                .frame(minWidth: 520, minHeight: 560)
        }
        .defaultSize(width: 560, height: 680)
        .commands {
            PackageCommands()
            UpdateCommands(
                updater: updaterController.updater,
                availability: updateAvailability
            )
        }

        Settings {
            JamfSettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the only window quits, as with other single-window utilities.
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }
}
