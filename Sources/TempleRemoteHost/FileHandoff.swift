import Darwin
import Foundation

/// A file dropped or pasted onto a tab on a host. The agent there reads
/// files on its own machine, so a path on this Mac means nothing to it:
/// the file is copied to the host first, and the host's path is what the
/// tab types.
///
/// - Each copy gets a folder of its own, made by `mktemp -d` in the host's
///   temporary folder (`$TMPDIR`, else `/tmp`): never the project (nothing
///   lands in a repository), cleaned by the host as any temporary file,
///   and the file keeps its own name there. No folder is shared between
///   copies, so there is none for another account to prepare or swap.
/// - The bytes travel on the query's stdin, never a command line, over the
///   tab's own master; the host checks the length that arrived, and a path
///   is typed only for a whole file.
public enum FileHandoff {
    /// The largest file copied. Agents read images and text; anything
    /// near this is not something an agent is shown whole.
    public static let maximumBytes = 100 << 20

    public enum Result: Sendable, Equatable {
        /// On the host, whole, at this path.
        case copied(path: String)
        /// Nothing usable is on the host; why, said plainly.
        case failed(String)
    }

    /// Arguments: a nonce (in the folder's name), the file's name on the
    /// host (a safe token), the byte count, the folder to use when `TMPDIR`
    /// can't be (`/tmp`); the bytes on stdin. Prints `temple-copied <path>`,
    /// or `temple-copy-refused <folder>`, `temple-copy-unwritable <folder>`
    /// or `temple-copy-short <arrived>` when nothing usable was left.
    ///
    /// A temporary folder is trusted only when it is an absolute path of
    /// plain characters, and it and every folder above it (resolved) is
    /// owned by root or the account and either writable by nobody else
    /// (neither group nor others) or sticky, with no ACL granting anything
    /// on macOS (a deny entry is harmless): nobody
    /// else can then rename or replace anything on the copy's path. `mktemp -d`
    /// then makes the copy's folder, the account's, atomically (an inherited
    /// setgid is cleared); it is entered and checked again by its resolved
    /// path, owner, mode 0700 and (on macOS) the absence of an ACL, failing
    /// closed, and every write is relative to it.
    /// The file is written as `.part` and renamed once its length is right;
    /// a copy cut off is removed (`trap`).
    static let writeScript = #"""
    umask 077
    u=$(id -u)
    mac=; [ "$(uname)" = Darwin ] && mac=1
    safe() { [ -n "$(find "$1" -maxdepth 0 -type d \( -user 0 -o -user "$u" \) \( \( ! -perm -020 ! -perm -002 \) -o -perm -1000 \) 2>/dev/null)" ] \
      && { [ -z "$mac" ] || { l=$(ls -lde "$1" 2>/dev/null) && ! printf '%s\n' "$l" | sed 1d | grep -q ' allow '; }; }; }
    trusted() { p=$(cd "$1" 2>/dev/null && pwd -P) || return 1; r=$p
      while :; do safe "$p" || return 1; [ "$p" = / ] && break; p=$(dirname "$p"); done; printf '%s' "$r"; }
    b=${TMPDIR:-}
    case $b in /*) ;; *) b= ;; esac
    case $b in *[!A-Za-z0-9._/-]*) b= ;; esac
    while :; do case $b in */) b=${b%/} ;; *) break ;; esac; done
    rb=; [ -n "$b" ] && rb=$(trusted "$b")
    if [ -z "$rb" ]; then b=$4; rb=$(trusted "$b") || { printf 'temple-copy-refused %s\n' "$b"; exit 0; }; fi
    b=$rb
    d=$(mktemp -d "$b/temple-$1-XXXXXXXX" 2>/dev/null) || { printf 'temple-copy-unwritable %s\n' "$b"; exit 0; }
    gone() { cd / 2>/dev/null; rm -rf "$d"; }
    chmod g-s,go-rwx "$d" 2>/dev/null
    ok=; cd "$d" 2>/dev/null && [ "$(pwd -P)" = "$b/${d##*/}" ] && [ -n "$(find . -maxdepth 0 -user "$u" -perm 700 2>/dev/null)" ] && ok=1
    if [ -n "$ok" ] && [ -n "$mac" ]; then chmod -N . 2>/dev/null; [ "$(ls -lde . 2>/dev/null | wc -l | tr -d ' \t')" = 1 ] || ok=; fi
    [ -n "$ok" ] || { gone; printf 'temple-copy-refused %s\n' "$b"; exit 0; }
    trap 'gone; exit 1' HUP INT TERM PIPE
    cat > "$2.part" 2>/dev/null || { gone; printf 'temple-copy-unwritable %s\n' "$b"; exit 0; }
    n=$(wc -c < "$2.part" | tr -d ' \t')
    [ "$n" = "$3" ] || { gone; printf 'temple-copy-short %s\n' "$n"; exit 0; }
    mv "$2.part" "$2" 2>/dev/null || { gone; printf 'temple-copy-unwritable %s\n' "$b"; exit 0; }
    trap - HUP INT TERM PIPE
    printf 'temple-copied %s/%s\n' "$d" "$2"
    """#

    /// Where copies go when the host's `TMPDIR` can't be trusted; a test
    /// points it at a folder of its own.
    nonisolated(unsafe) static var fallbackFolder = "/tmp"

    /// The file's name on the host: its own, with anything but letters,
    /// digits, `.`, `_` and `-` turned into `-` (no quoting on the host, no
    /// `..`, nothing a prompt would split), at most 100 bytes. The name and
    /// its extension are made safe apart, so `日本語.png` stays a `.png`.
    public static func hostFileName(_ name: String) -> String {
        func safe(_ text: String) -> String {
            var mapped = String(text.unicodeScalars.map { scalar -> Character in
                let v = scalar.value
                let ok = (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5a) || (v >= 0x61 && v <= 0x7a)
                    || v == 0x2e || v == 0x5f || v == 0x2d
                return ok ? Character(scalar) : "-"
            })
            while mapped.contains("--") { mapped = mapped.replacingOccurrences(of: "--", with: "-") }
            while let first = mapped.first, first == "." || first == "-" { mapped.removeFirst() }
            while let last = mapped.last, last == "." || last == "-" { mapped.removeLast() }
            return mapped
        }
        let ns = name as NSString
        var ext = safe(ns.pathExtension)
        if ext.count > 10 { ext = "" }
        var stem = safe(ext.isEmpty && !ns.pathExtension.isEmpty ? name : ns.deletingPathExtension)
        if stem.isEmpty { stem = "file" }
        let suffix = ext.isEmpty ? "" : "." + ext
        return String(stem.prefix(100 - suffix.count)) + suffix
    }

    /// How long a copy of `bytes` may take: a slow link's worth, never
    /// less than a quarter minute.
    static func deadline(for bytes: Int) -> TimeInterval {
        15 + Double(bytes) / Double(128 << 10)
    }

    /// Copies the file at `url` (on this Mac) to the host. Folders, and
    /// files over `maximumBytes`, are refused before anything is sent.
    public static func copy(_ url: URL, host: String, using exec: RemoteExec) async -> Result {
        let name = url.lastPathComponent
        let data: Data
        do {
            // A link is copied as what it points at, and only a regular file
            // is read (a pipe would never end), at most one byte past the
            // limit, into memory of its own (a mapped log truncated
            // meanwhile would crash the read).
            let target = url.resolvingSymlinksInPath()
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values.isDirectory == true { return .failed(Reason.folder(name)) }
            guard values.isRegularFile == true else { return .failed(Reason.unreadable(name)) }
            if let size = values.fileSize, size > maximumBytes { return .failed(Reason.tooLarge(name)) }
            // Opened without waiting and checked by the descriptor itself, so
            // a file swapped for a pipe since the check above is not read.
            let fd = open(target.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return .failed(Reason.unreadable(name)) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .failed(Reason.unreadable(name)) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        } catch {
            return .failed(Reason.unreadable(name))
        }
        return await copy(data, named: name, host: host, using: exec)
    }

    public static func copy(_ data: Data, named name: String, host: String, using exec: RemoteExec) async -> Result {
        guard data.count <= maximumBytes else { return .failed(Reason.tooLarge(name)) }
        guard !Task.isCancelled else { return .failed(Reason.cancelled) }
        let folder = RemoteQuoting.nonce()
        let hostName = hostFileName(name)
        precondition(RemoteQuoting.isSafeToken(hostName))
        do {
            let output = try await exec.run(script: writeScript,
                                            args: [folder, hostName, String(data.count), fallbackFolder],
                                            input: data, deadline: deadline(for: data.count))
            return parse(output, folder: folder, name: hostName, size: data.count, host: host)
        } catch is CancellationError {
            return .failed(Reason.cancelled)
        } catch RemoteExecError.deadline {
            return .failed(Reason.timedOut(host))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The script's one answer line. A path is believed only from a
    /// command that ended well, absolute, in this copy's own folder and
    /// under its own name.
    static func parse(_ output: RemoteOutput, folder: String, name: String, size: Int, host: String) -> Result {
        for line in output.stdout.split(separator: "\n").map(String.init) {
            if let path = line.dropPrefix("temple-copied ") {
                let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                guard output.status == 0, path.hasPrefix("/"), path.hasSuffix("/\(name)"),
                      parent.hasPrefix("temple-\(folder)-") else { break }
                return .copied(path: path)
            }
            if let folder = line.dropPrefix("temple-copy-refused ") { return .failed(Reason.untrusted(folder, host)) }
            if let folder = line.dropPrefix("temple-copy-unwritable ") { return .failed(Reason.unwritable(folder, host)) }
            if let short = line.dropPrefix("temple-copy-short "), let arrived = Int(short) {
                return .failed(Reason.short(arrived: arrived, of: size, host))
            }
        }
        if !output.reachedCommand, let line = output.firstErrorLine { return .failed(line) }
        return .failed(Reason.noAnswer(host))
    }

    /// Why a copy failed, as the tab says it: a sentence each, naming
    /// what the person can do when there is something.
    public enum Reason {
        static func folder(_ name: String) -> String { "\(name) is a folder. Open it and drag the files you want." }
        static func tooLarge(_ name: String) -> String {
            "\(name) is larger than \(maximumBytes >> 20) MB. Temple copies files up to \(maximumBytes >> 20) MB."
        }
        static func unreadable(_ name: String) -> String { "\(name) couldn't be read on this Mac." }
        static func untrusted(_ folder: String, _ host: String) -> String {
            "\(folder) on \(host) can be changed by other accounts, so Temple won't put your files there. "
                + "On \(host), set TMPDIR to a folder only you can write to, then try again."
        }
        static func unwritable(_ folder: String, _ host: String) -> String {
            "The file couldn't be written in \(folder) on \(host). Its disk may be full."
        }
        static func short(arrived: Int, of size: Int, _ host: String) -> String {
            let format = { (bytes: Int) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
            return "Only \(format(arrived)) of \(format(size)) arrived, so the partial copy on \(host) was removed. "
                + "Try again."
        }
        static func timedOut(_ host: String) -> String {
            "The copy didn't finish in time. Check that \(host) is reachable, then try again."
        }
        static let cancelled = "The copy was stopped."
        static func noAnswer(_ host: String) -> String { "Temple couldn't confirm the copy reached \(host). Try again." }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
