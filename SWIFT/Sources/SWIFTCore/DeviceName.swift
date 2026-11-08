import Foundation

/// How a device name is chosen and when a later announcement may replace it.
///
/// A name someone typed wins. Otherwise the Bluetooth name wins over the
/// system device name, and the model is only a last resort. A later
/// announcement that is only the model at the end of a longer name — "Pixel 8"
/// after "rai pixel 8" — does not replace the longer name.
public enum DeviceName {
    public static let unnamed = "Nearby phone"

    /// A saved Bluetooth accessory is not a phone. Controllers, headsets, and
    /// speakers stay in Bluetooth settings even when they are nowhere nearby.
    public static func isPossiblePhoneName(_ name: String) -> Bool {
        let folded = fold(name)
        guard !folded.isEmpty else { return false }
        let accessories = [
            "controller", "gamepad", "xbox", "headset", "headphone", "airpod",
            "earbud", "buds", "keyboard", "mouse", "trackpad", "speaker",
            "soundcore", "handsfree", "watch",
        ]
        return !accessories.contains { folded.contains($0) }
    }

    public static func choose(custom: String?, bluetooth: String?, system: String?, model: String?) -> String {
        clean(custom) ?? clean(bluetooth) ?? clean(system) ?? clean(model) ?? "Android"
    }

    /// The name to show for a peer. An alias the person saved on this Mac wins.
    public static func display(existing: String?, advertised: String?, bluetooth: String?, alias: String?) -> String {
        if let alias = clean(alias) { return alias }
        let existing = trusted(existing)
        let advertised = clean(advertised)
        let bluetooth = clean(bluetooth)
        if let advertised {
            if let existing, isShorterPiece(advertised, of: existing) { return existing }
            if let bluetooth, isShorterPiece(advertised, of: bluetooth) { return bluetooth }
            return advertised
        }
        if let bluetooth { return bluetooth }
        if let existing { return existing }
        return unnamed
    }

    /// True when `candidate` is the model-shaped ending of a longer name.
    /// "Pixel 8" is the ending of "rai pixel 8". It is not the ending of
    /// "Pixel 8 Pro", so two different phones stay distinct.
    public static func isShorterPiece(_ candidate: String, of longer: String) -> Bool {
        let short = fold(candidate)
        let long = fold(longer)
        guard short.count >= 3, short.count < long.count, long.hasSuffix(short) else { return false }
        let split = long.index(long.endIndex, offsetBy: -short.count)
        guard split > long.startIndex else { return false }
        return long[long.index(before: split)] == " "
    }

    private static func trusted(_ value: String?) -> String? {
        guard let value = clean(value), value != unnamed else { return nil }
        return value
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fold(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
