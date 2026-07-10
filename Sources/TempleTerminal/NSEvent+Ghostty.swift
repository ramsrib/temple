import AppKit
import GhosttyKit

// NSEvent → libghostty translation. Ported from Ghostty's macOS app
// (NSEvent+Extension.swift / Ghostty.Input.swift, MIT). libghostty consumes the
// raw macOS virtual keyCode and maps it internally, so no keycode table is
// needed here.
extension NSEvent {
    /// Translate AppKit modifier flags to ghostty's mods bitmask.
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    /// Build a ghostty key event (without text/composing — the caller sets those).
    func ghosttyKeyEvent(_ action: ghostty_input_action_e) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(keyCode)
        ev.text = nil
        ev.composing = false
        ev.mods = NSEvent.ghosttyMods(modifierFlags)
        // Control and command never contribute to text translation; assume the
        // rest do (matches Ghostty's long-standing heuristic).
        ev.consumed_mods = NSEvent.ghosttyMods(modifierFlags.subtracting([.control, .command]))
        ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let scalar = chars.unicodeScalars.first {
                ev.unshifted_codepoint = scalar.value
            }
        }
        return ev
    }

    /// The text to send for a key event, filtering control chars and function-key
    /// PUA values (ghostty encodes those itself).
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }
}
