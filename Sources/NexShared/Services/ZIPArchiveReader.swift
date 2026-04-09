import Foundation
import zlib

enum ZIPArchiveReaderError: Error {
    case invalidArchive
    case unsupportedCompressionMethod
    case entryNotFound
    case inflateFailed
}

struct ZIPArchiveEntry: Equatable {
    let path: String
    let compressionMethod: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

struct ZIPArchive {
    let data: Data
    let entries: [ZIPArchiveEntry]

    func entry(named path: String) -> ZIPArchiveEntry? {
        entries.first(where: { $0.path == path })
    }
}

final class ZIPArchiveReader {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func open(_ url: URL) throws -> ZIPArchive {
        guard fileManager.fileExists(atPath: url.path) else {
            throw ZIPArchiveReaderError.invalidArchive
        }

        let data = try Data(contentsOf: url)
        let entries = try parseEntries(in: data)
        return ZIPArchive(data: data, entries: entries)
    }

    func entryPaths(in archive: ZIPArchive) -> [String] {
        archive.entries.map(\.path)
    }

    func data(for path: String, in archive: ZIPArchive) throws -> Data {
        guard let entry = archive.entry(named: path) else {
            throw ZIPArchiveReaderError.entryNotFound
        }
        return try extract(entry: entry, from: archive.data)
    }

    private func parseEntries(in data: Data) throws -> [ZIPArchiveEntry] {
        guard let endOfCentralDirectoryOffset = findEndOfCentralDirectory(in: data) else {
            throw ZIPArchiveReaderError.invalidArchive
        }

        let centralDirectorySize = try readUInt32(in: data, at: endOfCentralDirectoryOffset + 12)
        let centralDirectoryOffset = try readUInt32(in: data, at: endOfCentralDirectoryOffset + 16)
        var cursor = Int(centralDirectoryOffset)
        let limit = cursor + Int(centralDirectorySize)
        var entries: [ZIPArchiveEntry] = []

        while cursor < limit {
            guard try readUInt32(in: data, at: cursor) == 0x02014b50 else {
                throw ZIPArchiveReaderError.invalidArchive
            }

            let compressionMethod = try readUInt16(in: data, at: cursor + 10)
            let compressedSize = try readUInt32(in: data, at: cursor + 20)
            let uncompressedSize = try readUInt32(in: data, at: cursor + 24)
            let fileNameLength = try readUInt16(in: data, at: cursor + 28)
            let extraFieldLength = try readUInt16(in: data, at: cursor + 30)
            let fileCommentLength = try readUInt16(in: data, at: cursor + 32)
            let localHeaderOffset = try readUInt32(in: data, at: cursor + 42)
            let fileNameOffset = cursor + 46
            let pathData = try slice(
                in: data,
                range: fileNameOffset..<(fileNameOffset + Int(fileNameLength))
            )
            let path = decodePath(from: pathData)

            entries.append(
                ZIPArchiveEntry(
                    path: path,
                    compressionMethod: compressionMethod,
                    compressedSize: Int(compressedSize),
                    uncompressedSize: Int(uncompressedSize),
                    localHeaderOffset: Int(localHeaderOffset)
                )
            )

            cursor += 46 + Int(fileNameLength) + Int(extraFieldLength) + Int(fileCommentLength)
        }

        return entries
    }

    private func extract(entry: ZIPArchiveEntry, from data: Data) throws -> Data {
        let localHeaderOffset = entry.localHeaderOffset
        guard try readUInt32(in: data, at: localHeaderOffset) == 0x04034b50 else {
            throw ZIPArchiveReaderError.invalidArchive
        }

        let fileNameLength = try readUInt16(in: data, at: localHeaderOffset + 26)
        let extraFieldLength = try readUInt16(in: data, at: localHeaderOffset + 28)
        let payloadOffset = localHeaderOffset + 30 + Int(fileNameLength) + Int(extraFieldLength)
        let payloadRange = payloadOffset..<(payloadOffset + entry.compressedSize)
        let payload = try slice(in: data, range: payloadRange)

        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            return try inflateRawDeflate(payload, expectedSize: entry.uncompressedSize)
        default:
            throw ZIPArchiveReaderError.unsupportedCompressionMethod
        }
    }

    private func findEndOfCentralDirectory(in data: Data) -> Int? {
        let minimumRecordSize = 22
        guard data.count >= minimumRecordSize else { return nil }

        let searchStart = max(0, data.count - (minimumRecordSize + 65_535))
        for offset in stride(from: data.count - minimumRecordSize, through: searchStart, by: -1) {
            if (try? readUInt32(in: data, at: offset)) == 0x06054b50 {
                return offset
            }
        }
        return nil
    }

    private func decodePath(from data: Data) -> String {
        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func inflateRawDeflate(_ data: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        var status = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw ZIPArchiveReaderError.inflateFailed
        }
        defer {
            inflateEnd(&stream)
        }

        let chunkSize = max(4_096, expectedSize > 0 ? expectedSize : 4_096)
        var output = Data()

        status = data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return Z_DATA_ERROR
            }

            stream.next_in = UnsafeMutablePointer(mutating: baseAddress)
            stream.avail_in = uInt(data.count)

            var buffer = [UInt8](repeating: 0, count: chunkSize)

            repeat {
                let outputCapacity = buffer.count
                let inflateStatus = buffer.withUnsafeMutableBytes { outputBuffer -> Int32 in
                    guard let outputBase = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                        return Z_MEM_ERROR
                    }
                    stream.next_out = outputBase
                    stream.avail_out = uInt(outputCapacity)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                if inflateStatus != Z_OK && inflateStatus != Z_STREAM_END {
                    return inflateStatus
                }

                let produced = buffer.count - Int(stream.avail_out)
                if produced > 0 {
                    output.append(buffer, count: produced)
                }

                if inflateStatus == Z_STREAM_END {
                    return inflateStatus
                }
            } while stream.avail_in > 0

            return Z_OK
        }

        guard status == Z_STREAM_END || (status == Z_OK && expectedSize == output.count) else {
            throw ZIPArchiveReaderError.inflateFailed
        }
        return output
    }

    private func readUInt16(in data: Data, at offset: Int) throws -> UInt16 {
        let raw = try slice(in: data, range: offset..<(offset + 2))
        return raw.withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
    }

    private func readUInt32(in data: Data, at offset: Int) throws -> UInt32 {
        let raw = try slice(in: data, range: offset..<(offset + 4))
        return raw.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    }

    private func slice(in data: Data, range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= data.count else {
            throw ZIPArchiveReaderError.invalidArchive
        }
        return data.subdata(in: range)
    }
}
