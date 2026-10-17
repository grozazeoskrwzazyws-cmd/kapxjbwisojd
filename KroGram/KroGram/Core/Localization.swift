// Copyright © 2026 Kro. KroGram original materials.

import Foundation

/// Looks up a localized string by key (ar/en `Localizable.strings`).
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
