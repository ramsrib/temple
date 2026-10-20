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
        // Which side, from the device-dependent bits (IOLLEvent.h's
        // NX_DEVICER*KEYMASK): `macos-option-as-alt = left` needs to tell
        // the right ⌥ from the left, or both are Alt.
        let raw = flags.rawValue
        if raw & 0x0000_0004 != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & 0x0000_2000 != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & 0x0000_0040 != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & 0x0000_0010 != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    /// Build a ghostty key event (without text/composing — the caller sets those).
    /// `translationMods` are the modifiers that produced the event's text, when
    /// libghostty took some away (⌥ under `macos-option-as-alt`): only those
    /// count as consumed, so the rest are encoded as modifiers.
    func ghosttyKeyEvent(_ action: ghostty_input_action_e,
                         translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(keyCode)
        ev.text = nil
        ev.composing = false
        ev.mods = NSEvent.ghosttyMods(modifierFlags)
        // Control and command never contribute to text translation; assume the
        // rest do (matches Ghostty's long-standing heuristic).
        ev.consumed_mods = NSEvent.ghosttyMods((translationMods ?? modifierFlags).subtracting([.control, .command]))
        ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let scalar = chars.unicodeScalars.first {
                ev.unshifted_codepoint = scalar.value
            }
        }
        return ev
    }

    /// This event as it reads with `mods` in place of its own shift, control,
    /// option and command: what the input system should compose text from
    /// once libghostty has said which modifiers are the terminal's
    /// (`ghostty_surface_key_translation_mods`). With ⌥ taken as Alt, ⌥P
    /// composes "p", not "π", and the core sends it as Alt-p. Ported from
    /// Ghostty's SurfaceView_AppKit `keyDown`.
    func ghosttyTranslationEvent(mods: NSEvent.ModifierFlags) -> NSEvent {
        let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let flags = modifierFlags.subtracting(relevant).union(mods.intersection(relevant))
        guard flags != modifierFlags else { return self }
        return NSEvent.keyEvent(
            with: type, location: locationInWindow, modifierFlags: flags,
            timestamp: timestamp, windowNumber: windowNumber, context: nil,
            characters: characters(byApplyingModifiers: flags) ?? "",
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? "",
            isARepeat: isARepeat, keyCode: keyCode) ?? self
    }

    /// Ghostty's mods bitmask back to AppKit's flags (the inverse of `ghosttyMods`).
    static func modifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        if mods.rawValue & GHOSTTY_MODS_CAPS.rawValue != 0 { flags.insert(.capsLock) }
        return flags
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

    /// Text that may ride along with a key event — nil when ghostty must encode
    /// the key from keycode + mods instead.
    ///
    /// Control text is always dropped. libghostty treats a key event carrying
    /// text as "the modifiers were consumed producing that text", so attaching
    /// Return's "\r" makes it drop Shift and encode a bare CR — Claude Code and
    /// Codex then see a submit, not the kitty-protocol `CSI 13;2u` they read as
    /// "insert a newline". Same for ctrl+enter, ctrl+tab, and friends. Upstream
    /// Ghostty drops control text in `keyAction` for exactly this reason.
    static func ghosttyKeyText(_ text: String?) -> String? {
        guard let text, let first = text.unicodeScalars.first else { return nil }
        if first.value < 0x20 || first.value == 0x7F { return nil }   // ghostty's isControl
        return text
    }
}
