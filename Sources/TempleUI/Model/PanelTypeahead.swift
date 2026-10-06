import Foundation

/// What was typed into a ⌘K / ⌘N panel before its field held the keyboard
/// (`AppModel.bufferPanelTyping`).
public struct PanelTypeahead: Equatable, Sendable {
    /// The panel's field has held the keyboard since the panel opened; keys
    /// go to it directly.
    public var fieldReady = false
    /// Text typed before then, in order.
    public var pending = ""

    /// The text a key types, or nil for one that types nothing: control
    /// characters (Return, Tab, Esc, ⌫) and the function-key range AppKit
    /// reports arrows, Home, F-keys and Forward Delete in.
    static func typedText(_ characters: String) -> String? {
        guard !characters.isEmpty else { return nil }
        let types = characters.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }
        return types ? characters : nil
    }
}
