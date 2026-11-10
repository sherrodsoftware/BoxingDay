import AppKit
import Sparkle
import SwiftUI

@main
struct BoxingDayApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    /// Sparkle reads SUFeedURL and SUPublicEDKey from Info.plist and checks
    /// for updates on its own schedule once the user allows it. It starts
    /// from the app delegate rather than here: starting during App init
    /// lets Sparkle's permission prompt appear before SwiftUI opens the main
    /// window, and the window then never opens.
    static let updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private let updateAvailability = UpdateAvailability(
        updater: updaterController.updater
    )

    var body: some Scene {
        // Boxing Day works on one item at a time, so it has a single window.
        Window("Boxing Day", id: "main") {
            ContentView()
                .frame(minWidth: 520, minHeight: 560)
        }
        .defaultSize(width: 560, height: 680)
        .commands {
            // Matches the About panel in Version Report: copyright and a
            // link to the Sherrod Software website below the version.
            CommandGroup(replacing: .appInfo) {
                Button("About Boxing Day") {
                    let credits = NSMutableAttributedString()
                    let smallFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                    credits.append(NSAttributedString(
                        string: "© Sherrod Software\n",
                        attributes: [.font: smallFont]
                    ))
                    credits.append(NSAttributedString(
                        string: "www.sherrodsoftware.com",
                        attributes: [
                            .font: smallFont,
                            .link: URL(string: "https://www.sherrodsoftware.com")!
                        ]
                    ))
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Boxing Day",
                        .credits: credits
                    ])
                }
            }
            PackageCommands()
            UpdateCommands(
                updater: Self.updaterController.updater,
                availability: updateAvailability
            )
            // Boxing Day has no Help Book; its documentation is the README.
            CommandGroup(replacing: .help) {
                Button("Boxing Day Help") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/sherrodsoftware/BoxingDay")!
                    )
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Settings {
            JamfSettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wait one run loop turn so SwiftUI has opened the main window
        // before Sparkle can show its first-run permission prompt.
        DispatchQueue.main.async {
            BoxingDayApp.updaterController.startUpdater()
        }
    }

    /// Closing the only window quits, as with other single-window utilities.
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }
}
