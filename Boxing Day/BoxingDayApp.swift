import SwiftUI

@main
struct AppToPkgApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, minHeight: 560)
        }
        .defaultSize(width: 560, height: 680)

        Settings {
            JamfSettingsView()
        }
    }
}
