import CoreText
import Foundation
import TempleCore

/// A Settings text field. Each one edits a draft and writes the store only on
/// commit (Return, or focus leaving it).
enum SettingsField: Hashable {
    case command(Agent)
    case arguments(Agent)
    case fontFamily
    case fontSize
}

/// What the user has typed but not committed, per field.
///
/// A field with no entry shows the committed value; an entry exists only while
/// the text differs from it. Typing never reaches `SettingsStore` — the store's
/// writes re-probe binaries and re-apply the terminal appearance, which is
/// exactly what must not happen per keystroke (SettingsResponsivenessTests).
struct SettingsDrafts: Equatable {
    private var edits: [SettingsField: String] = [:]

    func text(_ field: SettingsField, committed: String) -> String {
        edits[field] ?? committed
    }

    mutating func edit(_ field: SettingsField, to text: String, committed: String) {
        edits[field] = text == committed ? nil : text
    }

    func isEdited(_ field: SettingsField) -> Bool { edits[field] != nil }

    /// Esc: back to the committed value. False when there was nothing to revert.
    @discardableResult
    mutating func revert(_ field: SettingsField) -> Bool {
        edits.removeValue(forKey: field) != nil
    }

    /// The pending text, removed — what a commit writes.
    mutating func take(_ field: SettingsField) -> String? {
        edits.removeValue(forKey: field)
    }
}

/// The commit half: reads the committed value for a field and writes a draft
/// into the store, then asks the toolchain to re-check what changed.
@MainActor
struct SettingsEditor {
    let store: SettingsStore
    let toolchain: ToolchainModel

    static let fontSizeRange: ClosedRange<Double> = 9...24

    func committed(_ field: SettingsField) -> String {
        switch field {
        case .command(let agent): return store.overridePath(for: agent)
        case .arguments(let agent): return store.extraArgsText(for: agent)
        case .fontFamily: return store.fontFamily
        case .fontSize: return String(Int(store.fontSize.rounded()))
        }
    }

    /// Commit the pending draft for `field`, if there is one. Returns whether
    /// the store was written.
    @discardableResult
    func commit(_ field: SettingsField, drafts: inout SettingsDrafts) -> Bool {
        guard let text = drafts.take(field) else { return false }
        return write(field, text)
    }

    /// Write `text` as the committed value — used by commit and by the Command
    /// field's clear button, which empties and commits in one click.
    @discardableResult
    func write(_ field: SettingsField, _ text: String) -> Bool {
        switch field {
        case .command(let agent):
            // Whitespace around a pasted path is never part of it.
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path != store.overridePath(for: agent) else { return false }
            store.setOverridePath(path, for: agent)
            toolchain.recheckUserSettings()
        case .arguments(let agent):
            guard text != store.extraArgsText(for: agent) else { return false }
            store.setExtraArgsText(text, for: agent)
            toolchain.recheckUserSettings()
        case .fontFamily:
            // A trailing space would make the family unfindable, silently.
            let family = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard family != store.fontFamily else { return false }
            store.fontFamily = family      // AppModel applies it to the terminals
        case .fontSize:
            guard let size = Double(text.trimmingCharacters(in: .whitespaces)) else { return false }
            let clamped = min(max(size.rounded(), Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
            guard clamped != store.fontSize else { return false }
            store.fontSize = clamped
        }
        return true
    }

    /// Arguments back to the shipped default (the key is forgotten, not
    /// overwritten — see `SettingsStore.resetExtraArgs`).
    func resetArguments(_ agent: Agent, drafts: inout SettingsDrafts) {
        drafts.revert(.arguments(agent))
        guard !store.extraArgsAreShipped(for: agent) else { return }
        store.resetExtraArgs(for: agent)
        toolchain.recheckUserSettings()
    }
}

/// Whether the terminal can find a font family — the *detected* layer applied
/// to the font field. Asks Core Text the same question Ghostty's discovery
/// asks (a descriptor with only the family-name attribute, matched against the
/// installed fonts); when that finds nothing, Ghostty logs "font-family … not
/// found" and renders with its built-in font (Vendor/ghostty
/// src/font/SharedGridSet.zig). Never a guess at why it's missing.
enum FontFamilyCheck {
    /// Nil when there is nothing to say: an empty family (the terminal's own
    /// default by definition) or one that is installed.
    static func verdict(for family: String,
                        isInstalled: (String) -> Bool = FontFamilyCheck.isInstalled) -> FontFamilyVerdict? {
        let name = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isInstalled(name) else { return nil }
        return .notInstalled
    }

    static func isInstalled(_ family: String) -> Bool {
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: family] as CFDictionary)
        let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
        guard let matches = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] else {
            return false
        }
        return !matches.isEmpty
    }
}

enum FontFamilyVerdict: Equatable {
    case notInstalled
}
