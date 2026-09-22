import Foundation

/// English key, value from `en.lproj` / `es.lproj` according to the system language.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
