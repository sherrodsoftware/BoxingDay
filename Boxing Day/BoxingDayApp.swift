import AppKit
import SwiftUI

@main
struct BoxingDayApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // Boxing Day works on one item at a time, so it has a single window.
        Window("Boxing Day", id: "main") {
            ContentView()
                .frame(minWidth: 520, minHeight: 560)
        }
        .defaultSize(width: 560, height: 680)
        .commands {
            PackageCommands()
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
