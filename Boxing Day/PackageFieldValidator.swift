import Foundation

enum PackageFieldValidator {
    static func identifierError(_ identifier: String) -> String? {
        guard !identifier.isEmpty else {
            return "Enter a package identifier."
        }
        guard identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return "The identifier cannot begin or end with whitespace."
        }

        let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty }) else {
            return "Use a reverse-domain identifier such as com.example.app.pkg."
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        for component in components {
            let text = String(component)
            guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  text.first?.isLetter == true || text.first?.isNumber == true,
                  text.last?.isLetter == true || text.last?.isNumber == true
            else {
                return "Each identifier section may contain letters, numbers, or interior hyphens."
            }
        }

        return nil
    }

    static func versionError(_ version: String) -> String? {
        guard !version.isEmpty else {
            return "Enter a package version."
        }
        guard version == version.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return "The version cannot begin or end with whitespace."
        }

        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".+-_")
        )
        guard version.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "Use only letters, numbers, periods, hyphens, underscores, or plus signs."
        }

        return nil
    }
}
