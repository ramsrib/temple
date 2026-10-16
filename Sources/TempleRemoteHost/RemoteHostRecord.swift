import Foundation
import TempleCore

/// A host Temple may reach over ssh: an alias from `~/.ssh/config`, or one
/// entered in Temple with its connection details. The record holds strings
/// ssh takes as options and nothing secret: no password, no key material,
/// only the path of an identity file the user typed.
///
/// The list of records is the user's decision and the only thing persisted
/// (`temple.settings.remoteHosts`); being in the list is what enables a host.
/// What a test found is never written here.
public struct RemoteHostRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        /// An alias in `~/.ssh/config`, reached by that alias alone.
        case config
        /// Entered in Temple; reached by its name plus `-o` options.
        case temple
    }

    /// The host's identity in Temple (`HostID`), fixed once saved.
    public var name: String
    public var source: Source
    public var address: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var proxyJump: String?

    public var id: String { name }
    public var host: HostID { HostID(rawValue: name) }

    public init(name: String, source: Source, address: String? = nil, user: String? = nil, port: Int? = nil,
                identityFile: String? = nil, proxyJump: String? = nil) {
        self.name = name; self.source = source; self.address = address; self.user = user
        self.port = port; self.identityFile = identityFile; self.proxyJump = proxyJump
    }

    /// An alias from `~/.ssh/config`, enabled in Temple.
    public static func config(_ alias: String) -> RemoteHostRecord {
        RemoteHostRecord(name: alias, source: .config)
    }

    private enum CodingKeys: String, CodingKey {
        case name, source, address, user, port, identityFile, proxyJump
    }

    /// Explicit, so a field added later never makes older JSON unreadable
    /// (AGENTS.md: a stored-property default does not make synthesized
    /// `Decodable` tolerant of a missing key). An entry without `source` is a
    /// config alias.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .config
        address = try container.decodeIfPresent(String.self, forKey: .address)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
        proxyJump = try container.decodeIfPresent(String.self, forKey: .proxyJump)
    }

    /// The same host as an ssh config block, for people who want it in their
    /// own file. Temple never writes there itself.
    public var sshConfigBlock: String {
        var lines = ["Host \(name)"]
        if let address { lines.append("    HostName \(address)") }
        if let user { lines.append("    User \(user)") }
        if let port { lines.append("    Port \(port)") }
        if let identityFile { lines.append("    IdentityFile \(SSHConnection.optionValue(identityFile))") }
        if let proxyJump { lines.append("    ProxyJump \(proxyJump)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `user@address`, or the parts there are.
    public var summary: String {
        guard source == .temple else { return name }
        var text = address ?? name
        if let user { text = "\(user)@\(text)" }
        if let port { text += ":\(port)" }
        return text
    }
}

/// The persisted list: one JSON array under one key. An entry this build
/// cannot read is kept as it was and written back untouched, so a newer or
/// damaged entry never takes the rest of the list with it.
public struct RemoteHostList: Equatable, Sendable {
    public var records: [RemoteHostRecord]
    /// Entries that did not decode, as their JSON bytes, in order.
    public var unreadable: [Data]

    public init(records: [RemoteHostRecord] = [], unreadable: [Data] = []) {
        self.records = records; self.unreadable = unreadable
    }

    public static func decode(_ data: Data?) -> RemoteHostList {
        guard let data, let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return RemoteHostList()
        }
        var list = RemoteHostList()
        var seen: Set<String> = []
        for element in array {
            guard let bytes = try? JSONSerialization.data(withJSONObject: element, options: [.sortedKeys, .fragmentsAllowed]) else { continue }
            if let record = try? JSONDecoder().decode(RemoteHostRecord.self, from: bytes), !record.name.isEmpty {
                // A second entry for a name is the same host: dropped, so a
                // Remove can never leave a copy behind to come back.
                if seen.insert(record.name).inserted { list.records.append(record) }
            } else {
                list.unreadable.append(bytes)
            }
        }
        return list
    }

    public func encode() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var elements: [Any] = records.compactMap { record in
            (try? encoder.encode(record)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        }
        elements += unreadable.compactMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        return (try? JSONSerialization.data(withJSONObject: elements, options: [.sortedKeys])) ?? Data("[]".utf8)
    }
}

/// The Add host / Edit form: text as typed, checked into a record.
public struct RemoteHostForm: Equatable, Sendable {
    public enum Field: Hashable, Sendable { case name, address, user, port, identityFile, proxyJump }

    public var name = ""
    public var address = ""
    public var user = ""
    public var port = ""
    public var identityFile = ""
    public var proxyJump = ""

    public init() {}

    public init(_ record: RemoteHostRecord) {
        name = record.name
        address = record.address ?? ""
        user = record.user ?? ""
        port = record.port.map(String.init) ?? ""
        identityFile = record.identityFile ?? ""
        proxyJump = record.proxyJump ?? ""
    }

    /// The record, or what is wrong with each field. `editing` is the name
    /// of the record being edited (its name is fixed and not re-checked);
    /// `existing` the names Temple already has, `configAliases` those in
    /// `~/.ssh/config`.
    public func validate(editing: String?, existing: Set<String>, configAliases: Set<String>)
        -> Result<RemoteHostRecord, Problems> {
        var problems: [Field: String] = [:]
        let name = trimmed(self.name)
        if let editing {
            if name != editing { problems[.name] = "The name can't be changed later." }
        } else if name.isEmpty {
            problems[.name] = "Give the host a name."
        } else if name.hasPrefix("-") {
            problems[.name] = "A name can't start with a dash."
        } else if !RemoteQuoting.isSafeToken(name) {
            problems[.name] = "Use letters, digits, dots, dashes and underscores."
        } else if configAliases.contains(name) {
            problems[.name] = "~/.ssh/config already has a host named \(name). Turn it on under From ~/.ssh/config instead."
        } else if existing.contains(name) {
            problems[.name] = "Temple already has a host named \(name)."
        }

        let address = trimmed(self.address)
        if address.isEmpty {
            problems[.address] = "Enter the host's address."
        } else if !Self.isPlainWord(address) {
            problems[.address] = "An address can't contain spaces or start with a dash."
        }
        let user = trimmed(self.user)
        if !user.isEmpty, !Self.isPlainWord(user) {
            problems[.user] = "A user name can't contain spaces or start with a dash."
        }
        let portText = trimmed(self.port)
        var port: Int?
        if !portText.isEmpty {
            if let value = Int(portText), (1...65_535).contains(value), portText.allSatisfy(\.isASCII) {
                port = value
            } else {
                problems[.port] = "A port is a number from 1 to 65535."
            }
        }
        let identity = trimmed(self.identityFile)
        if !identity.isEmpty, identity.contains(where: { $0 == "\"" || $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true }) {
            problems[.identityFile] = "Temple can't pass a path with a double quote or a line break to ssh."
        }
        let jump = trimmed(self.proxyJump)
        if !jump.isEmpty, !Self.isPlainWord(jump, allowComma: true) {
            problems[.proxyJump] = "A jump host can't contain spaces or start with a dash."
        }
        guard problems.isEmpty else { return .failure(Problems(byField: problems)) }
        return .success(RemoteHostRecord(name: name, source: .temple, address: address,
                                         user: user.isEmpty ? nil : user, port: port,
                                         identityFile: identity.isEmpty ? nil : identity,
                                         proxyJump: jump.isEmpty ? nil : jump))
    }

    public struct Problems: Error, Equatable, Sendable {
        public let byField: [Field: String]
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }

    /// One ssh word: no whitespace, no control characters, no quotes, not an
    /// option. (`-o` values are tokenized by ssh, so a space would split it.)
    static func isPlainWord(_ text: String, allowComma: Bool = true) -> Bool {
        guard !text.hasPrefix("-") else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && !CharacterSet.controlCharacters.contains(scalar)
                && scalar != "\"" && scalar != "'" && scalar != "\\" && scalar != "#"
        }
    }
}
