import Foundation

/// Settings saved by a newer Pulse can name things this version doesn't know, such as a module or
/// alert added later. Strict decoding would fail the whole settings, and `SettingsStore` would then
/// start over from the defaults. These helpers skip the unknown parts instead.

/// One element that decodes to nil instead of failing.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// The elements that decode; the rest are left out.
    func decodeLenientArray<Element: Decodable>(_: [Element].Type, forKey key: Key) throws -> [Element] {
        try decode([Lenient<Element>].self, forKey: key).compactMap(\.value)
    }

    /// Like `decodeLenientArray`, as a set.
    func decodeLenientSet<Element: Decodable & Hashable>(_: Set<Element>.Type, forKey key: Key) throws -> Set<Element> {
        Set(try decodeLenientArray([Element].self, forKey: key))
    }

    /// Nil when missing, and also when present but unreadable.
    func decodeLenientIfPresent<Value: Decodable>(_: Value.Type, forKey key: Key) -> Value? {
        (try? decodeIfPresent(Value.self, forKey: key)) ?? nil
    }
}
