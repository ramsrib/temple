/// Where a session's recorded working directory came from.
public enum DirectorySource: String, Codable, Sendable {
    case tab
    case transcript
}
