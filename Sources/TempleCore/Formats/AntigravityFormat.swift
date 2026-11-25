import Foundation

/// The Antigravity CLI (`agy`, ADR-043). Its sessions are SQLite databases,
/// not text, so no transport hands this format a file's bytes: a host's
/// store queries the databases and hands it one JSON record per
/// conversation (`Record`), whose fields are the columns and blobs exactly
/// as stored. Everything that interprets them — which conversation it is,
/// whether it is a session, its folder, title and first prompt — is here,
/// pure, so a host that reads the same columns another way (a remote
/// `sqlite3`) gets the same answers. SESSION-FORMATS.md has the store.
public struct AntigravityFormat: TranscriptFormat {
    public init() {}
    public var agent: Agent { .antigravity }

    /// `conversations/<uuid>.db`. The conversation's id is its database's
    /// name, lowercased as `agy` writes it.
    public func name(path: String) -> TranscriptName? {
        let last = TranscriptText.lastComponent(path)
        guard last.hasSuffix(".db") else { return nil }
        let stem = String(last.dropLast(3))
        guard UUID(uuidString: stem) != nil else { return nil }
        return TranscriptName(threadID: stem.lowercased())
    }

    /// One line: the record. Its size is bounded by the store (the first
    /// prompt's payload is the only large field).
    public var identityScan: IdentityScan { .firstLine(maxBytes: Self.recordBytes) }
    public static let recordBytes = 4 * 1024 * 1024

    /// The ids the conversation's own database records
    /// (`trajectory_meta.cascade_id`): verified when one of them is the id
    /// asked for, a mismatch when it records only others, incomplete when it
    /// records none (a database `agy` is still creating).
    public func identity(lines: some Sequence<Data>, expecting id: String) -> TranscriptVerification {
        guard let line = lines.first(where: { _ in true }), let record = Record(line) else { return .incomplete }
        let ids = record.ids.map { $0.lowercased() }
        if ids.isEmpty { return .incomplete }
        return ids.contains(id.lowercased()) ? .verified : .mismatch
    }

    public func facts(_ bytes: TranscriptBytes, name: TranscriptName?, locator: TranscriptLocator,
                      modifiedAt: Date, shared: SharedFacts) -> TranscriptFacts {
        guard bytes.tail == nil, let record = Record(bytes.head),
              let id = name?.threadID ?? record.ids.first?.lowercased() else { return .unparseable }
        let summary = record.summary
        // A subagent's conversation runs inside its parent (ADR-024).
        if let parent = summary?.parent, !parent.isEmpty { return .unparseable }
        let prompt = record.firstUserStep.flatMap(Self.userStep)
        // Nothing was ever asked: a conversation `/clear` or a slash command
        // left behind, with nothing to resume. Hidden, never absent: its
        // database is still a file the listing sees.
        if prompt == nil, (summary?.stepCount ?? 0) == 0 { return .unparseable }
        let lastModified = summary.flatMap { Self.date($0.lastModified) }
        let promptText = prompt?.text.map { TranscriptText.cleanTitle($0) }.flatMap { $0.isEmpty ? nil : $0 }
        // No row yet, or the row as it was before the first prompt (no
        // steps, no title): `agy` has not named it yet.
        let named = summary.map { !($0.title.isEmpty && $0.stepCount == 0) } ?? false
        // Until its summary row is written (a moment after the database),
        // the conversation's title is not known: `agy` names it as the first
        // prompt is sent. The prompt is a display hint meanwhile, never a
        // title fact a fill could keep in place of that name.
        return .summary(TranscriptSummary(
            id: id, agent: .antigravity, locator: locator, modifiedAt: modifiedAt,
            cwd: summary.flatMap { Self.folder($0.workspaceURIs) },
            firstPrompt: named ? promptText : nil,
            createdAt: prompt?.at,
            lastEntryAt: lastModified.map { min($0, modifiedAt) },
            recordedTitle: summary.flatMap { TranscriptText.cleanTitle($0.title) }.flatMap { $0.isEmpty ? nil : $0 },
            laterPromptHint: named ? nil : promptText))
    }

    // MARK: The record

    /// What a store read for one conversation. Field names are the store's
    /// columns; times are the column text as `agy` wrote it.
    public struct Record: Codable, Equatable, Sendable {
        /// `trajectory_meta.cascade_id`, every row.
        public var ids: [String]
        /// The conversation's `conversation_summaries` row, if it has one yet.
        public var summary: Summary?
        /// The first `steps` row with `step_type` 14 (user input): its
        /// `step_payload`, base64.
        public var firstUserStep: String?

        public struct Summary: Codable, Equatable, Sendable {
            public var title: String
            public var workspaceURIs: String
            public var parent: String
            public var stepCount: Int
            public var lastModified: String
            public init(title: String, workspaceURIs: String, parent: String, stepCount: Int, lastModified: String) {
                self.title = title; self.workspaceURIs = workspaceURIs; self.parent = parent
                self.stepCount = stepCount; self.lastModified = lastModified
            }
        }

        public init(ids: [String], summary: Summary?, firstUserStep: String?) {
            self.ids = ids; self.summary = summary; self.firstUserStep = firstUserStep
        }

        public init?(_ data: Data) {
            guard let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
            self = record
        }

        /// The line a store hands over: compact JSON, no newline inside.
        public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    }

    // MARK: Interpreting the columns

    /// The folder from `workspace_uris`, a JSON array of `file://` URLs.
    /// Only a conversation with exactly one folder has one: which of several
    /// is the conversation's own is not known (SESSION-FORMATS).
    public static func folder(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let uris = (try? JSONSerialization.jsonObject(with: data)) as? [String], uris.count == 1,
              let url = URL(string: uris[0]), url.scheme == "file" else { return nil }
        // The URL's own text, decoded: `URL(string:)` never touches the disk.
        let path = url.path
        return path.isEmpty ? nil : path
    }

    /// `agy`'s time columns: `2026-11-24 20:55:44.515956+00:00`. The zero
    /// time (`0001-01-01 …`) is how it writes "never".
    static func date(_ text: String) -> Date? {
        guard !text.hasPrefix("0001-01-01") else { return nil }
        let iso = text.replacingOccurrences(of: " ", with: "T")
        if let date = TranscriptText.parseDate(iso) { return date }
        // More than three fractional digits: keep milliseconds.
        if let dot = iso.firstIndex(of: "."), let zone = iso[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let fraction = iso[iso.index(after: dot)..<zone].prefix(3)
            return TranscriptText.parseDate(String(iso[..<dot]) + "." + fraction + String(iso[zone...]))
        }
        return nil
    }

    /// A first user step (base64, as `Record` holds it): its prompt as a
    /// title would show it (nil when it has none), and when it was sent.
    /// Nil for bytes that are not a whole step.
    public static func firstPrompt(_ base64: String) -> (prompt: String?, at: Date?)? {
        guard let step = userStep(base64) else { return nil }
        let prompt = step.text.map { TranscriptText.cleanTitle($0) }.flatMap { $0.isEmpty ? nil : $0 }
        return (prompt, step.at)
    }

    /// A user-input step's payload: field 19 (the input), whose field 2 is
    /// the text; field 5.1 the time (seconds, nanos). SESSION-FORMATS.md.
    static func userStep(_ base64: String) -> (text: String?, at: Date?)? {
        guard let payload = Data(base64Encoded: base64), let fields = Protobuf.fields(payload) else { return nil }
        var text: String?
        var at: Date?
        for field in fields {
            switch (field.number, field.value) {
            case (19, .bytes(let input)):
                if text == nil, let inner = Protobuf.fields(input) {
                    for f in inner where f.number == 2 {
                        if case .bytes(let raw) = f.value { text = String(data: raw, encoding: .utf8); break }
                    }
                }
            case (5, .bytes(let meta)):
                if at == nil, let inner = Protobuf.fields(meta) {
                    for f in inner where f.number == 1 {
                        if case .bytes(let stamp) = f.value { at = Protobuf.timestamp(stamp); break }
                    }
                }
            default: break
            }
        }
        return (text, at)
    }
}

/// Just enough of the protobuf wire format to walk a message's fields.
enum Protobuf {
    enum Value: Equatable { case varint(UInt64), bytes(Data), fixed64(UInt64), fixed32(UInt32) }
    struct Field: Equatable { let number: Int; let value: Value }

    /// Every field of one message, or nil when the bytes are not a whole,
    /// well-formed message (groups are not supported and fail it).
    static func fields(_ data: Data) -> [Field]? {
        let bytes = [UInt8](data)
        var index = 0
        var fields: [Field] = []
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]; index += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let key = varint() else { return nil }
            let number = Int(key >> 3)
            guard number > 0 else { return nil }
            switch key & 7 {
            case 0:
                guard let v = varint() else { return nil }
                fields.append(Field(number: number, value: .varint(v)))
            case 1:
                guard index + 8 <= bytes.count else { return nil }
                var v: UInt64 = 0
                for i in 0..<8 { v |= UInt64(bytes[index + i]) << (8 * UInt64(i)) }
                index += 8
                fields.append(Field(number: number, value: .fixed64(v)))
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - index) else { return nil }
                let end = index + Int(length)
                fields.append(Field(number: number, value: .bytes(Data(bytes[index..<end]))))
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return nil }
                var v: UInt32 = 0
                for i in 0..<4 { v |= UInt32(bytes[index + i]) << (8 * UInt32(i)) }
                index += 4
                fields.append(Field(number: number, value: .fixed32(v)))
            default:
                return nil
            }
        }
        return fields
    }

    /// A `google.protobuf.Timestamp`: 1 seconds, 2 nanos.
    static func timestamp(_ data: Data) -> Date? {
        guard let fields = fields(data) else { return nil }
        var seconds: UInt64?
        var nanos: UInt64 = 0
        for field in fields {
            if case .varint(let v) = field.value {
                if field.number == 1 { seconds = v } else if field.number == 2 { nanos = v }
            }
        }
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
    }
}
