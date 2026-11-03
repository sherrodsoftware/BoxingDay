import AppKit
import UniformTypeIdentifiers

enum ErrorReportExporter {
    static func save(message: String, suggestedFileName: String) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = suggestedFileName

        savePanel.presentAttachedToKeyWindow { url in
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
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension NSSavePanel {
    /// Presents the panel as a sheet on the key window, so only that window
    /// is blocked, and calls `completion` with the chosen URL. Falls back to
    /// a standalone panel when there is no key window.
    func presentAttachedToKeyWindow(completion: @escaping (URL) -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .OK, let url else { return }
            completion(url)
        }
        if let window = NSApp.keyWindow {
            beginSheetModal(for: window, completionHandler: handler)
        } else {
            begin(completionHandler: handler)
        }
    }
}
