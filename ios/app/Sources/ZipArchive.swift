//
//  ZipArchive.swift
//  3ds2apple
//
//  Small ZIP writer and reader for backing up and restoring battery save data.
//
//  The Save Manager moves a handful of small files, so the writer stores the
//  entries uncompressed (3DS save data barely compresses, and the archive stays
//  readable by every unzip tool). The reader accepts both stored entries and
//  deflated ones, which covers archives made by the Files app, macOS and
//  Windows, and decodes deflate with the system Compression framework (raw
//  DEFLATE, the format ZIP method 8 stores).
//
//  Only the subset this app needs is implemented: UTF-8 names, no archive
//  comments, no encryption, no multi-disk and no ZIP64. Unsafe entry names
//  (absolute paths, "..", drive letters) and damaged CRCs are rejected before
//  anything is written, and every write goes through a temporary file so an
//  interrupted import cannot replace a good save with half a file.
//

import Compression
import Foundation

// MARK: - CRC-32

/// CRC-32 (IEEE 802.3, polynomial 0xEDB88320), the checksum ZIP entries carry.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    /// The checksum of `data` as ZIP stores it (the final XOR included).
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Errors

/// What the ZIP writer/reader reports; the message is shown to the user.
struct ZipArchiveError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Writer

/// Writes a small ZIP archive to disk one entry at a time.
///
/// Every entry is stored (method 0). `close()` writes the central directory and
/// is required; a writer that is released without it leaves an unreadable file,
/// which is fine because the caller deletes a failed export.
final class ZipArchiveWriter {
    /// The largest file the writer stores.
    static let maximumEntryBytes = 256 * 1024 * 1024

    private struct Entry {
        let nameData: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
    }

    private let url: URL
    private let handle: FileHandle
    private var offset: UInt32 = 0
    private var entries: [Entry] = []
    private var isClosed = false

    init(url: URL) throws {
        self.url = url
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: url)
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw ZipArchiveError(message: L10n.tr("Could not create the ZIP archive."))
        }
        do {
            self.handle = try FileHandle(forWritingTo: url)
        } catch {
            try? fileManager.removeItem(at: url)
            throw ZipArchiveError(
                message: L10n.format("Could not write the ZIP archive: %@", error.localizedDescription)
            )
        }
    }

    deinit {
        if !isClosed {
            try? handle.close()
        }
    }

    /// Adds one file. `name` is the path inside the archive (forward slashes,
    /// relative); it must be a safe relative path.
    func addFile(name: String, contents: Data) throws {
        guard !isClosed else {
            throw ZipArchiveError(message: L10n.tr("The ZIP archive was already closed."))
        }
        guard let nameData = ZipArchiveWriter.validatedName(name) else {
            throw ZipArchiveError(
                message: L10n.format("Could not store “%@” in the archive: the name is not a safe relative path.", name)
            )
        }
        guard entries.count < Int(UInt16.max) else {
            throw ZipArchiveError(
                message: L10n.tr("There are too many files to include in one save-data archive.")
            )
        }
        guard contents.count <= ZipArchiveWriter.maximumEntryBytes else {
            throw ZipArchiveError(
                message: L10n.format("“%@” is too large to include in a save-data archive.", name)
            )
        }
        guard let size = UInt32(exactly: contents.count) else {
            throw ZipArchiveError(
                message: L10n.format("“%@” is too large to include in a save-data archive.", name)
            )
        }
        let entryOffset = offset
        let crc = CRC32.checksum(contents)
        let (dosTime, dosDate) = ZipArchiveWriter.dosDateAndTime(Date())
        let header = ZipArchiveWriter.localHeader(
            nameData: nameData,
            crc: crc,
            size: size,
            dosTime: dosTime,
            dosDate: dosDate
        )
        try append(header)
        try append(contents)
        entries.append(
            Entry(
                nameData: nameData,
                crc: crc,
                size: size,
                offset: entryOffset,
                dosTime: dosTime,
                dosDate: dosDate
            )
        )
    }

    /// Writes the central directory and the end record and closes the file.
    func close() throws {
        guard !isClosed else { return }
        isClosed = true
        let centralOffset = offset
        var central = Data()
        for entry in entries {
            central.append(
                ZipArchiveWriter.centralHeader(
                    nameData: entry.nameData,
                    crc: entry.crc,
                    size: entry.size,
                    dosTime: entry.dosTime,
                    dosDate: entry.dosDate,
                    offset: entry.offset
                )
            )
        }
        try append(central)
        guard let centralSize = UInt32(exactly: central.count) else {
            throw ZipArchiveError(
                message: L10n.tr("The save data is too large for a ZIP archive (4 GB limit).")
            )
        }
        var end = Data()
        end.append(ZipArchiveWriter.uint32(0x0605_4B50))     // end of central directory
        end.append(ZipArchiveWriter.uint16(0))              // this disk
        end.append(ZipArchiveWriter.uint16(0))              // disk with the central directory
        end.append(ZipArchiveWriter.uint16(UInt16(entries.count)))
        end.append(ZipArchiveWriter.uint16(UInt16(entries.count)))
        end.append(ZipArchiveWriter.uint32(centralSize))
        end.append(ZipArchiveWriter.uint32(centralOffset))
        end.append(ZipArchiveWriter.uint16(0))              // archive comment length
        try append(end)
        do {
            try handle.close()
        } catch {
            throw ZipArchiveError(
                message: L10n.format("Could not finish the ZIP archive: %@", error.localizedDescription)
            )
        }
    }

    // MARK: Private

    private func append(_ data: Data) throws {
        guard UInt64(offset) + UInt64(data.count) <= UInt64(UInt32.max) else {
            throw ZipArchiveError(
                message: L10n.tr("The save data is too large for a ZIP archive (4 GB limit).")
            )
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw ZipArchiveError(
                message: L10n.format("Could not write the ZIP archive: %@", error.localizedDescription)
            )
        }
        offset += UInt32(data.count)
    }

    private static func validatedName(_ name: String) -> Data? {
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/") else { return nil }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        let data = Data(normalized.utf8)
        guard data.count <= Int(UInt16.max) else { return nil }
        return data
    }

    private static func localHeader(
        nameData: Data,
        crc: UInt32,
        size: UInt32,
        dosTime: UInt16,
        dosDate: UInt16
    ) -> Data {
        var data = Data()
        data.append(uint32(0x0403_4B50))                 // local file header
        data.append(uint16(20))                          // version needed: 2.0
        data.append(uint16(0x0800))                      // UTF-8 file name
        data.append(uint16(0))                           // method: stored
        data.append(uint16(dosTime))
        data.append(uint16(dosDate))
        data.append(uint32(crc))
        data.append(uint32(size))                        // compressed size
        data.append(uint32(size))                        // uncompressed size
        data.append(uint16(UInt16(nameData.count)))
        data.append(uint16(0))                           // extra field length
        data.append(nameData)
        return data
    }

    private static func centralHeader(
        nameData: Data,
        crc: UInt32,
        size: UInt32,
        dosTime: UInt16,
        dosDate: UInt16,
        offset: UInt32
    ) -> Data {
        var data = Data()
        data.append(uint32(0x0201_4B50))                 // central directory header
        data.append(uint16(20))                          // version made by: 2.0, DOS
        data.append(uint16(20))                          // version needed
        data.append(uint16(0x0800))                      // UTF-8 file name
        data.append(uint16(0))                           // method: stored
        data.append(uint16(dosTime))
        data.append(uint16(dosDate))
        data.append(uint32(crc))
        data.append(uint32(size))                        // compressed size
        data.append(uint32(size))                        // uncompressed size
        data.append(uint16(UInt16(nameData.count)))
        data.append(uint16(0))                           // extra field length
        data.append(uint16(0))                           // comment length
        data.append(uint16(0))                           // disk number start
        data.append(uint16(0))                           // internal attributes
        data.append(uint32(0))                           // external attributes
        data.append(uint32(offset))                      // local header offset
        data.append(nameData)
        return data
    }

    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    /// MS-DOS date and time (local time, two-second resolution), the form ZIP
    /// headers use. Clamped to the range the fields can hold.
    private static func dosDateAndTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = min(max(components.year ?? 1980, 1980), 2107)
        let month = min(max(components.month ?? 1, 1), 12)
        let day = min(max(components.day ?? 1, 1), 31)
        let hour = min(max(components.hour ?? 0, 0), 23)
        let minute = min(max(components.minute ?? 0, 0), 59)
        let second = min(max(components.second ?? 0, 0), 59) / 2
        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }
}

// MARK: - Reader

/// What one archive extraction wrote.
struct ZipExtractionSummary {
    var fileCount = 0
    var bytes: UInt64 = 0
    /// Entries that were skipped on purpose: macOS metadata and directories.
    var skippedEntries = 0
}

/// Reads a ZIP archive into a directory, one file at a time.
enum ZipArchiveReader {
    /// Limits that keep a damaged or hostile archive from filling the device.
    static let maximumEntries = 4096
    static let maximumEntryBytes: UInt64 = 128 * 1024 * 1024
    static let maximumTotalBytes: UInt64 = 512 * 1024 * 1024

    /// Extracts `archiveURL` into `directory`.
    ///
    /// `strippingWrapperNamed` handles the common backup shape where the user
    /// zipped the game's save-data folder itself: when every file in the
    /// archive sits inside one top-level folder with that name, the folder is
    /// dropped so the files land where the runtime reads them.
    static func extract(
        from archiveURL: URL,
        into directory: URL,
        strippingWrapperNamed wrapper: String?
    ) throws -> ZipExtractionSummary {
        let fileManager = FileManager.default
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: archiveURL)
        } catch {
            throw ZipArchiveError(
                message: L10n.format("Could not open the archive: %@", error.localizedDescription)
            )
        }
        defer { try? handle.close() }

        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            throw ZipArchiveError(
                message: L10n.format("Could not read the archive: %@", error.localizedDescription)
            )
        }
        guard fileSize >= 22 else {
            throw ZipArchiveError(message: L10n.tr("The selected file is not a ZIP archive."))
        }

        // The end record sits at the end, before an optional comment of up to
        // 65535 bytes.
        let tailSize = Int(min(fileSize, UInt64(22 + 0xFFFF)))
        let tailStart = fileSize - UInt64(tailSize)
        let tail = try readBytes(handle: handle, offset: tailStart, count: tailSize, fileSize: fileSize)
        guard let endRecord = findEndOfCentralDirectory(in: tail) else {
            throw ZipArchiveError(message: L10n.tr("The selected file is not a ZIP archive."))
        }
        let entryCount = Int(try readUInt16(tail, endRecord + 10))
        let centralSize = UInt64(try readUInt32(tail, endRecord + 12))
        let centralOffset = UInt64(try readUInt32(tail, endRecord + 16))
        guard entryCount <= maximumEntries else {
            throw ZipArchiveError(
                message: L10n.format("The archive has too many entries to import (limit %ld).", maximumEntries)
            )
        }
        guard centralSize <= 32 * 1024 * 1024,
              centralOffset <= fileSize,
              centralSize <= fileSize - centralOffset else {
            throw ZipArchiveError(message: L10n.tr("The ZIP archive is damaged (bad central directory)."))
        }
        let central = try readBytes(
            handle: handle,
            offset: centralOffset,
            count: Int(centralSize),
            fileSize: fileSize
        )

        var entries: [CentralEntry] = []
        var position = 0
        for _ in 0..<entryCount {
            guard try readUInt32(central, position) == 0x0201_4B50 else {
                throw ZipArchiveError(message: L10n.tr("The ZIP archive is damaged (bad central directory)."))
            }
            let flags = try readUInt16(central, position + 8)
            let method = try readUInt16(central, position + 10)
            let crc = try readUInt32(central, position + 16)
            let compressedSize = UInt64(try readUInt32(central, position + 20))
            let uncompressedSize = UInt64(try readUInt32(central, position + 24))
            let nameLength = Int(try readUInt16(central, position + 28))
            let extraLength = Int(try readUInt16(central, position + 30))
            let commentLength = Int(try readUInt16(central, position + 32))
            let diskStart = try readUInt16(central, position + 34)
            let localOffset = UInt64(try readUInt32(central, position + 42))
            let recordLength = 46 + nameLength + extraLength + commentLength
            guard position + recordLength <= central.count else {
                throw ZipArchiveError(message: L10n.tr("The ZIP archive is damaged (bad central directory)."))
            }
            if flags & 0x0001 != 0 {
                throw ZipArchiveError(message: L10n.tr("Encrypted ZIP archives are not supported."))
            }
            guard diskStart == 0 else {
                throw ZipArchiveError(message: L10n.tr("Multi-disk ZIP archives are not supported."))
            }
            guard compressedSize != 0xFFFF_FFFF, uncompressedSize != 0xFFFF_FFFF,
                  localOffset != 0xFFFF_FFFF else {
                throw ZipArchiveError(message: L10n.tr("ZIP64 archives are not supported."))
            }
            guard method == 0 || method == 8 else {
                throw ZipArchiveError(
                    message: L10n.tr("The archive uses a compression method this app cannot read.")
                )
            }
            let nameData = central.subdata(in: (position + 46)..<(position + 46 + nameLength))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""
            entries.append(
                CentralEntry(
                    name: name,
                    isDirectory: name.hasSuffix("/"),
                    method: method,
                    crc: crc,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localOffset: localOffset
                )
            )
            position += recordLength
        }

        // A backup of the whole save-data folder usually arrives as one
        // top-level folder named after the game; drop it when present.
        let stripWrapper = ZipArchiveReader.wrapperStrippable(entries, named: wrapper)

        var summary = ZipExtractionSummary()
        var totalBytes: UInt64 = 0
        for entry in entries {
            if ZipArchiveReader.isJunkEntry(entry.name) {
                summary.skippedEntries += 1
                continue
            }
            if entry.isDirectory {
                continue
            }
            var relativeName = entry.name
            if stripWrapper, let wrapper, relativeName.hasPrefix(wrapper + "/") {
                relativeName = String(relativeName.dropFirst(wrapper.count + 1))
            }
            let components = relativeName
                .replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !relativeName.hasPrefix("/") else {
                throw ZipArchiveError(
                    message: L10n.format("The archive contains an unsafe file name (“%@”).", entry.name)
                )
            }
            guard entry.uncompressedSize <= maximumEntryBytes else {
                throw ZipArchiveError(
                    message: L10n.format("“%@” is too large to import.", entry.name)
                )
            }
            let target = directory.appendingPathComponent(relativeName, isDirectory: false)
            let basePath = directory.standardizedFileURL.path
            guard target.standardizedFileURL.path.hasPrefix(basePath + "/") else {
                throw ZipArchiveError(
                    message: L10n.format("The archive contains an unsafe file name (“%@”).", entry.name)
                )
            }

            // The local header may carry a different extra field than the
            // central directory, so the data offset comes from the local one.
            let localHeader = try readBytes(
                handle: handle,
                offset: entry.localOffset,
                count: 30,
                fileSize: fileSize
            )
            guard try readUInt32(localHeader, 0) == 0x0403_4B50 else {
                throw ZipArchiveError(message: L10n.tr("The ZIP archive is damaged (bad local header)."))
            }
            let localNameLength = UInt64(try readUInt16(localHeader, 26))
            let localExtraLength = UInt64(try readUInt16(localHeader, 28))
            let dataOffset = entry.localOffset + 30 + localNameLength + localExtraLength
            guard dataOffset <= fileSize, entry.compressedSize <= fileSize - dataOffset else {
                throw ZipArchiveError(message: L10n.tr("The ZIP archive is damaged (truncated file)."))
            }
            let compressed = try readBytes(
                handle: handle,
                offset: dataOffset,
                count: Int(entry.compressedSize),
                fileSize: fileSize
            )
            let payload: Data
            switch entry.method {
            case 0:
                guard entry.compressedSize == entry.uncompressedSize else {
                    throw ZipArchiveError(message: L10n.tr("The ZIP archive is damaged (wrong size)."))
                }
                payload = compressed
            default:
                payload = try inflate(compressed, uncompressedSize: Int(entry.uncompressedSize))
            }
            guard UInt64(payload.count) == entry.uncompressedSize else {
                throw ZipArchiveError(message: L10n.tr("The ZIP archive is damaged (wrong size)."))
            }
            guard CRC32.checksum(payload) == entry.crc else {
                throw ZipArchiveError(message: L10n.tr("The ZIP archive is damaged (checksum mismatch)."))
            }
            totalBytes += UInt64(payload.count)
            guard totalBytes <= maximumTotalBytes else {
                throw ZipArchiveError(message: L10n.tr("The archive is too large to import."))
            }
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try AtomicFileWriter.write(payload, to: target)
            } catch {
                throw ZipArchiveError(
                    message: L10n.format("Could not write “%@”: %@", relativeName, error.localizedDescription)
                )
            }
            summary.fileCount += 1
            summary.bytes += UInt64(payload.count)
        }

        guard summary.fileCount > 0 else {
            throw ZipArchiveError(message: L10n.tr("The archive does not contain any save-data files."))
        }
        return summary
    }

    // MARK: Private

    private struct CentralEntry {
        let name: String
        let isDirectory: Bool
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localOffset: UInt64
    }

    /// Whether every file in the archive sits inside one top-level folder with
    /// the expected name, the shape a folder compressed in the Files app has.
    private static func wrapperStrippable(_ entries: [CentralEntry], named wrapper: String?) -> Bool {
        guard let wrapper, !wrapper.isEmpty else { return false }
        let names = entries
            .filter { !$0.isDirectory && !isJunkEntry($0.name) }
            .map(\.name)
        guard !names.isEmpty, names.allSatisfy({ $0.contains("/") }) else { return false }
        let tops = Set(names.compactMap { $0.split(separator: "/").first.map(String.init) })
        return tops.count == 1 && tops.first == wrapper
    }

    /// macOS metadata and resource forks, and directory entries, are not save
    /// data and are skipped instead of failing the import.
    private static func isJunkEntry(_ name: String) -> Bool {
        let components = name.split(separator: "/").map(String.init)
        if components.contains("__MACOSX") { return true }
        guard let last = components.last else { return true }
        return last == ".DS_Store" || last.hasPrefix("._")
    }

    private static func findEndOfCentralDirectory(in tail: Data) -> Int? {
        guard tail.count >= 22 else { return nil }
        var index = tail.count - 22
        while index >= 0 {
            if let signature = try? readUInt32(tail, index), signature == 0x0605_4B50 {
                let commentLength = (try? readUInt16(tail, index + 20)).map { Int($0) } ?? -1
                if commentLength >= 0, index + 22 + commentLength == tail.count {
                    return index
                }
            }
            index -= 1
        }
        return nil
    }

    private static func inflate(_ data: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else {
            guard data.isEmpty else {
                throw ZipArchiveError(message: L10n.tr("The ZIP archive is damaged (empty entry)."))
            }
            return Data()
        }
        var output = Data(count: uncompressedSize)
        let decoded: Int = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    uncompressedSize,
                    sourceBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == uncompressedSize else {
            throw ZipArchiveError(
                message: L10n.tr("The ZIP archive contains a file this device could not decompress.")
            )
        }
        return output
    }

    private static func readBytes(
        handle: FileHandle,
        offset: UInt64,
        count: Int,
        fileSize: UInt64
    ) throws -> Data {
        guard count >= 0, offset <= fileSize, UInt64(count) <= fileSize - offset else {
            throw ZipArchiveError(message: L10n.tr("The ZIP archive is damaged (truncated file)."))
        }
        if count == 0 { return Data() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            throw ZipArchiveError(message: L10n.tr("Could not read the ZIP archive."))
        }
        guard let data = try? handle.read(upToCount: count), data.count == count else {
            throw ZipArchiveError(message: L10n.tr("Could not read the ZIP archive."))
        }
        return data
    }

    private static func readUInt16(_ data: Data, _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw ZipArchiveError(message: L10n.tr("The ZIP archive is damaged (truncated header)."))
        }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw ZipArchiveError(message: L10n.tr("The ZIP archive is damaged (truncated header)."))
        }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
