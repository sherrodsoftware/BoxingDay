import AppKit
import UniformTypeIdentifiers

enum ErrorReportExporter {
    static func save(message: String, suggestedFileName: String) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = suggestedFileName

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            do {
                try text(for: message).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                presentSaveError(error)
            }
        }
    }

    static func text(for message: String) -> String {
        message.hasSuffix("\n") ? message : message + "\n"
    }

    private static func presentSaveError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could Not Save Error Report"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
