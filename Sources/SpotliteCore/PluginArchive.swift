import Compression
import Foundation

/// Size limits for a plugin fetched from an address.
public struct PluginInstallLimits: Sendable, Equatable {
    /// Bytes downloaded for one archive.
    public var download: Int64 = 50 * 1024 * 1024
    /// Bytes written when extracting, and the size of the finished plugin folder.
    public var extracted: Int64 = 200 * 1024 * 1024
    public var entries = 10_000
    /// Bytes read for a manifest during an update check.
    public var manifest: Int64 = Int64(PluginStore.maxManifestBytes)

    public init() {}
}

/// Extracts zip archives without trusting them, in-process so every limit applies to
/// the bytes actually written. Only stored and deflated entries are read; encrypted,
/// multi-disk and ZIP64 archives are refused. Entries are checked before anything is
/// written: no absolute paths, no `..`, no duplicates. Symbolic links are created last,
/// so no entry is ever written through one, and must stay inside the archive.
public enum PluginArchive {

    public static func extract(_ archive: URL, to destination: URL,
                               limits: PluginInstallLimits = .init()) throws(PluginInstallError) {
        let data: Data
        do { data = try Data(contentsOf: archive, options: .alwaysMapped) }
        catch { throw .archive("Couldn’t read the downloaded archive.") }
        let entries = try centralDirectory(data, limits: limits)
        let files = FileManager.default
        do { try files.createDirectory(at: destination, withIntermediateDirectories: true) }
        catch { throw .archive("Couldn’t create a folder to extract into.") }

        var written: Int64 = 0
        var links: [(Entry, String)] = []
        for entry in entries {
            if Task.isCancelled { throw .cancelled }
            let url = destination.appendingPathComponent(entry.path)
            switch entry.kind {
            case .directory:
                do { try files.createDirectory(at: url, withIntermediateDirectories: true) }
                catch { throw .archive("Couldn’t create \(entry.path).") }
            case .file(let executable):
                do { try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
                catch { throw .archive("Couldn’t create the folder for \(entry.path).") }
                // O_EXCL and O_NOFOLLOW: never write over or through anything already there.
                let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, executable ? 0o755 : 0o644)
                guard fd >= 0 else { throw .archive("Couldn’t write \(entry.path): it appears twice or is not a plain name.") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try inflate(entry, from: data, limit: limits.extracted - written) { chunk throws(PluginInstallError) in
                    do { try handle.write(contentsOf: chunk) }
                    catch { throw .archive("Couldn’t write \(entry.path).") }
                }
                written += entry.size
            case .link:
                var target = Data()
                try inflate(entry, from: data, limit: 1024) { chunk throws(PluginInstallError) in target.append(chunk) }
                guard let text = String(data: target, encoding: .utf8), isContained(link: entry.path, target: text) else {
                    throw .archive("The archive has a link that points outside it: \(entry.path).")
                }
                links.append((entry, text))
            }
        }
        for (entry, target) in links {
            let url = destination.appendingPathComponent(entry.path)
            do {
                try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.createSymbolicLink(atPath: url.path, withDestinationPath: target)
            } catch { throw .archive("Couldn’t create the link \(entry.path).") }
        }
    }

    /// The commit a GitHub archive was made from: `git archive` stores it as the zip's
    /// comment.
    public static func comment(of archive: URL) -> String? {
        guard let data = try? Data(contentsOf: archive, options: .alwaysMapped),
              let end = endRecord(in: data) else { return nil }
        let length = Int(data.uint16(at: end + 20))
        guard length > 0, end + 22 + length <= data.count else { return nil }
        return String(data: data.subdata(in: (data.startIndex + end + 22)..<(data.startIndex + end + 22 + length)), encoding: .utf8)
    }

    /// Fails unless every item under `root` is a plain file or folder, or a link that
    /// resolves to something inside `root`, and the whole is within `limit` bytes.
    /// Run on the plugin's folder itself, since a link inside the archive can still
    /// point outside the folder that is installed.
    public static func verifyTree(_ root: URL, limit: Int64) throws(PluginInstallError) {
        guard let base = realPath(root) else { throw .archive("The plugin folder disappeared.") }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else {
            throw .archive("Couldn’t read the plugin folder.")
        }
        var total: Int64 = 0
        var count = 0
        for case let url as URL in walker {
            count += 1
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                throw .archive("Couldn’t read \(url.lastPathComponent).")
            }
            let name = String(url.path.dropFirst(root.path.count + 1))
            if values.isSymbolicLink == true {
                guard let resolved = realPath(url), resolved == base || resolved.hasPrefix(base + "/") else {
                    throw .archive("The link \(name) points outside the plugin’s folder, or nowhere.")
                }
            } else if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            } else if values.isDirectory != true {
                throw .archive("\(name) is neither a file nor a folder.")
            }
            guard total <= limit, count <= 100_000 else {
                throw .archive("The plugin is larger than \(megabytes(limit)).")
            }
        }
    }

    static func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether a relative link target, resolved from the link's folder, stays in the archive.
    static func isContained(link path: String, target: String) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\0") else { return false }
        var depth = path.split(separator: "/").count - 1
        for part in target.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": depth -= 1
            default: depth += 1
            }
            if depth < 0 { return false }
        }
        return true
    }

    // MARK: - Reading

    struct Entry {
        enum Kind: Equatable {
            case directory
            case file(executable: Bool)
            case link
        }
        let path: String
        let kind: Kind
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int64
        let size: Int64
        let headerOffset: Int
    }

    private static func endRecord(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var offset = data.count - 22
        while offset >= lowest {
            if data.uint32(at: offset) == 0x0605_4B50,
               offset + 22 + Int(data.uint16(at: offset + 20)) == data.count { return offset }
            offset -= 1
        }
        return nil
    }

    static func centralDirectory(_ data: Data, limits: PluginInstallLimits) throws(PluginInstallError) -> [Entry] {
        guard data.count >= 4, data.uint32(at: 0) == 0x0403_4B50 || data.uint32(at: 0) == 0x0605_4B50 else {
            throw .archive("The download is not a zip archive. For a git repository, use an address ending in .git.")
        }
        guard let end = endRecord(in: data) else { throw .archive("The zip archive is incomplete.") }
        let disk = data.uint16(at: end + 4), directoryDisk = data.uint16(at: end + 6)
        let count = Int(data.uint16(at: end + 10))
        let size = Int(data.uint32(at: end + 12)), start = Int(data.uint32(at: end + 16))
        guard disk == 0, directoryDisk == 0 else { throw .archive("Multi-part zip archives are not supported.") }
        guard count != 0xFFFF, size != 0xFFFF_FFFF, start != 0xFFFF_FFFF else {
            throw .archive("ZIP64 archives are not supported.")
        }
        guard count <= limits.entries else { throw .archive("The archive has more than \(limits.entries) items.") }
        guard start + size <= end else { throw .archive("The zip archive is damaged.") }

        var entries: [Entry] = []
        var seen = Set<String>()
        var declared: Int64 = 0
        var offset = start
        for _ in 0..<count {
            guard offset + 46 <= end, data.uint32(at: offset) == 0x0201_4B50 else {
                throw .archive("The zip archive is damaged.")
            }
            let madeBy = data.uint16(at: offset + 4)
            let flags = data.uint16(at: offset + 8)
            let method = data.uint16(at: offset + 10)
            let crc = data.uint32(at: offset + 16)
            let compressed = Int64(data.uint32(at: offset + 20))
            let uncompressed = Int64(data.uint32(at: offset + 24))
            let nameLength = Int(data.uint16(at: offset + 28))
            let extraLength = Int(data.uint16(at: offset + 30))
            let commentLength = Int(data.uint16(at: offset + 32))
            let external = data.uint32(at: offset + 38)
            let header = Int(data.uint32(at: offset + 42))
            guard offset + 46 + nameLength <= end else { throw .archive("The zip archive is damaged.") }
            let nameBytes = data.subdata(in: (data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + nameLength))
            offset += 46 + nameLength + extraLength + commentLength

            guard let raw = String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .isoLatin1) else {
                throw .archive("The archive has an unreadable name.")
            }
            guard flags & 1 == 0 else { throw .archive("Encrypted archives are not supported.") }
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF, header != 0xFFFF_FFFF else {
                throw .archive("ZIP64 archives are not supported.")
            }
            guard let path = safePath(raw) else {
                throw .archive("The archive has an unsafe path: \(raw)")
            }
            // Finder's resource-fork shadows are not part of the plugin.
            if path == "__MACOSX" || path.hasPrefix("__MACOSX/") { continue }
            guard seen.insert(path.lowercased()).inserted else {
                throw .archive("The archive has \(path) twice.")
            }
            let mode = madeBy >> 8 == 3 ? UInt16(truncatingIfNeeded: external >> 16) : 0
            let kind: Entry.Kind
            switch mode & 0o170000 {
            case 0o120000: kind = .link
            case 0o040000: kind = .directory
            case 0o100000, 0: kind = raw.hasSuffix("/") ? .directory : .file(executable: mode & 0o111 != 0)
            default: throw .archive("The archive has a special file: \(path)")
            }
            if kind != .directory {
                guard method == 0 || method == 8 else {
                    throw .archive("The archive uses a compression method Spotlite can’t read.")
                }
                declared += uncompressed
                guard declared <= limits.extracted else {
                    throw .archive("The archive expands to more than \(megabytes(limits.extracted)).")
                }
            }
            entries.append(Entry(path: path, kind: kind, method: method, crc: crc, compressedSize: compressed,
                                 size: uncompressed, headerOffset: header))
        }
        return entries
    }

    /// A relative path of plain components, without a trailing slash; nil if unsafe.
    static func safePath(_ raw: String) -> String? {
        var path = Substring(raw)
        while path.hasSuffix("/") { path = path.dropLast() }
        guard !path.isEmpty, !raw.hasPrefix("/"), !raw.contains("\0") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != ".." }) else { return nil }
        let kept = parts.filter { $0 != "." }
        return kept.isEmpty ? nil : kept.joined(separator: "/")
    }

    /// Streams an entry's bytes to `sink`, failing when they exceed what the directory
    /// declared or `limit`, or do not match the checksum.
    private static func inflate(_ entry: Entry, from data: Data, limit: Int64,
                                into sink: (Data) throws(PluginInstallError) -> Void) throws(PluginInstallError) {
        let header = entry.headerOffset
        guard header + 30 <= data.count, data.uint32(at: header) == 0x0403_4B50 else {
            throw .archive("The zip archive is damaged at \(entry.path).")
        }
        let begin = header + 30 + Int(data.uint16(at: header + 26)) + Int(data.uint16(at: header + 28))
        guard begin + Int(entry.compressedSize) <= data.count else {
            throw .archive("The zip archive is damaged at \(entry.path).")
        }
        guard entry.size <= limit else { throw .archive("The archive expands to more than allowed.") }
        // A slice of the mapped archive: the compressed bytes are not copied.
        let input = data[(data.startIndex + begin)..<(data.startIndex + begin + Int(entry.compressedSize))]
        var crc = CRC32()
        var produced: Int64 = 0
        func emit(_ chunk: Data) throws(PluginInstallError) {
            produced += Int64(chunk.count)
            guard produced <= entry.size else { throw .archive("\(entry.path) is larger than the archive says.") }
            crc.update(chunk)
            try sink(chunk)
        }
        if entry.method == 0 {
            guard entry.compressedSize == entry.size else { throw .archive("The zip archive is damaged at \(entry.path).") }
            var position = input.startIndex
            while position < input.endIndex {
                let next = min(position + 1 << 20, input.endIndex)
                try emit(input.subdata(in: position..<next))
                position = next
            }
        } else {
            try deflate(input, emit: emit)
        }
        guard produced == entry.size, crc.value == entry.crc else {
            throw .archive("The zip archive is damaged at \(entry.path).")
        }
    }

    private static func deflate(_ input: Data, emit: (Data) throws(PluginInstallError) -> Void) throws(PluginInstallError) {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw .archive("Couldn’t start decompressing.")
        }
        defer { compression_stream_destroy(stream) }
        let capacity = 64 * 1024
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { output.deallocate() }
        let failure: PluginInstallError? = input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> PluginInstallError? in
            stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(output)
            stream.pointee.src_size = raw.count
            while true {
                stream.pointee.dst_ptr = output
                stream.pointee.dst_size = capacity
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let count = capacity - stream.pointee.dst_size
                if count > 0 {
                    do throws(PluginInstallError) { try emit(Data(bytes: output, count: count)) } catch { return error }
                }
                switch status {
                case COMPRESSION_STATUS_END: return nil
                case COMPRESSION_STATUS_OK:
                    // No progress with nothing left to read: the stream is truncated.
                    if count == 0 && stream.pointee.src_size == 0 { return .archive("The zip archive is truncated.") }
                default: return .archive("The zip archive is damaged.")
                }
            }
        }
        if let failure { throw failure }
    }
}

struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }
    private var state: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        let table = Self.table
        var state = self.state
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes { state = table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8) }
        }
        self.state = state
    }

    var value: UInt32 { state ^ 0xFFFF_FFFF }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
