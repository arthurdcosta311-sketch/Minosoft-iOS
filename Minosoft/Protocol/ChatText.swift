import Foundation

/// Kane's slice: pulls plain text out of a Minecraft chat component —
/// a plain string, or the JSON object tree ("text" / "translate" / "extra").
/// Enough for MOTDs, system chat and kick reasons; full formatting lands
/// with Pip's chat UI milestone.
enum ChatText {
    static func extract(_ json: String) -> String {
        guard let data = json.data(using: .utf8) else { return "" }
        if let string = try? JSONSerialization.jsonObject(with: data) as? String {
            return string
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return "" }
        return describe(object)
    }

    private static func describe(_ any: Any) -> String {
        if let string = any as? String { return string }
        guard let object = any as? [String: Any] else { return "" }
        var out = ""
        if let text = object["text"] as? String {
            out += text
        } else if let translate = object["translate"] as? String {
            out += translate
        }
        if let extra = object["extra"] as? [Any] {
            out += extra.map(describe).joined()
        }
        return out
    }
}


extension ChatText {
    /// 1.20.3+ carries chat components as NBT text components, not JSON.
    /// A component is a string, a compound ("text"/"translate" + "extra"),
    /// or a list of components.
    static func extract(_ nbt: NBTValue) -> String {
        switch nbt {
        case .string(let string):
            return string
        case .compound(let fields):
            var out = fields["text"]?.stringValue ?? fields["translate"]?.stringValue ?? ""
            if case .list(let extras)? = fields["extra"] {
                for extra in extras {
                    out += extract(extra)
                }
            }
            return out
        case .list(let items):
            return items.map(extract).joined()
        default:
            return ""
        }
    }
}