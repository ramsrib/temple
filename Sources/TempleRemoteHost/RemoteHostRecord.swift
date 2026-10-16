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
            // A hand-edited entry that fails the form's grammar is kept,
            // never handed to ssh.
            if let record = try? JSONDecoder().decode(RemoteHostRecord.self, from: bytes), !record.name.isEmpty,
               HostGrammar.isUsable(record) {
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

        var address = trimmed(self.address)
        if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        if address.isEmpty {
            problems[.address] = "Enter the host's address."
        } else if !HostGrammar.isAddress(address) {
            problems[.address] = "Enter a host name, an IPv4 address or an IPv6 address."
        }
        let user = trimmed(self.user)
        if !user.isEmpty, !HostGrammar.isUser(user) {
            problems[.user] = "A user name can use letters, digits, dots, dashes and underscores, and can't start with a dash."
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
        if !jump.isEmpty, !HostGrammar.isJumpList(jump) {
            problems[.proxyJump] = "A jump host is [user@]host[:port], several separated by commas."
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
}

/// What may reach ssh as a host, user or jump host. Strict on purpose:
/// ssh substitutes these into shell text when a config, the user's or the
/// system's, has a `ProxyCommand` with `%h`, `%r` or `%p`. Quoting the `-o`
/// value protects ssh's own tokenizer, not that shell, so nothing a shell
/// could read as syntax gets through: a host name (letters, digits, dashes
/// and underscores in dot-separated labels), an IPv4 address, or an IPv6
/// address (bare, or in brackets inside a jump host).
public enum HostGrammar {
    public static func isAddress(_ text: String) -> Bool {
        isHostName(text) || isIPv6(text)
    }

    /// Labels of `[A-Za-z0-9_-]`, none empty or dash-led, 253 bytes at most.
    /// An IPv4 address is one of these.
    static func isHostName(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 253 else { return false }
        var name = Substring(text)
        if name.hasSuffix(".") { name = name.dropLast() }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-")
                && label.utf8.allSatisfy { isAlphanumeric($0) || $0 == 0x2d || $0 == 0x5f }
        }
    }

    /// An IPv6 address as `inet_pton` reads it (no zone: `%` is ssh's token
    /// character).
    static func isIPv6(_ text: String) -> Bool {
        guard text.contains(":"), text.utf8.allSatisfy({ isHex($0) || $0 == 0x3a || $0 == 0x2e }) else { return false }
        var address = in6_addr()
        return inet_pton(AF_INET6, text, &address) == 1
    }

    /// A login name: `[A-Za-z0-9._-]`, not dash-led.
    public static func isUser(_ text: String) -> Bool {
        !text.isEmpty && !text.hasPrefix("-") && text.utf8.count <= 64
            && text.utf8.allSatisfy { isAlphanumeric($0) || $0 == 0x2e || $0 == 0x5f || $0 == 0x2d }
    }

    /// `ProxyJump`: `[user@]host[:port]`, comma-separated; an IPv6 host in
    /// brackets.
    public static func isJumpList(_ text: String) -> Bool {
        let hops = text.split(separator: ",", omittingEmptySubsequences: false)
        return !hops.isEmpty && hops.allSatisfy { isJump(String($0)) }
    }

    static func isJump(_ hop: String) -> Bool {
        var rest = Substring(hop)
        if let at = rest.lastIndex(of: "@") {
            guard isUser(String(rest[..<at])) else { return false }
            rest = rest[rest.index(after: at)...]
        }
        var host: Substring
        var port: Substring?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return false }
            host = rest[rest.index(after: rest.startIndex)..<close]
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return false }
                port = after.dropFirst()
            }
            guard isIPv6(String(host)) else { return false }
        } else {
            let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return false }
            host = parts[0]
            port = parts.count == 2 ? parts[1] : nil
            guard isHostName(String(host)) else { return false }
        }
        if let port {
            guard let number = Int(port), (1...65_535).contains(number), port.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
            else { return false }
        }
        return true
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }

    /// A stored record ssh may be given: a config alias as it is (ssh reads
    /// the user's own config for it); a host entered in Temple only when
    /// every field passes the grammar the form enforces.
    public static func isUsable(_ record: RemoteHostRecord) -> Bool {
        guard record.source == .temple else { return true }
        guard RemoteQuoting.isSafeToken(record.name), !record.name.hasPrefix("-"),
              let address = record.address, isAddress(address) else { return false }
        if let user = record.user, !isUser(user) { return false }
        if let port = record.port, !(1...65_535).contains(port) { return false }
        if let jump = record.proxyJump, !isJumpList(jump) { return false }
        if let identity = record.identityFile,
           identity.contains(where: { $0 == "\"" || $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true }) { return false }
        return true
    }
}
