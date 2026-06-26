import Foundation

/// Compact localized-string helper for AppKit code paths (SwiftUI `Text`
/// localizes automatically from the String Catalog). Looks keys up in
/// `Localizable.xcstrings`.
func loc(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}
