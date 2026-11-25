import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ScanResult: Sendable {
    public var tracks: [Track]
    public var skipped: [String]
}

public actor LibraryScanner {
    public static let extensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac", "caf"]
    private let artworkDirectory: URL

    public init(artworkDirectory: URL) { self.artworkDirectory = artworkDirectory }

    public func scan(_ folder: LibraryFolder, existing: [Track],
                     progress: @Sendable (Int) async -> Void) async throws -> ScanResult {
        let manager = FileManager.default
        guard manager.isReadableFile(atPath: folder.url.path) else { throw CocoaError(.fileReadNoPermission) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        var enumerationErrors: [String] = []
        guard let iterator = manager.enumerator(at: folder.url, includingPropertiesForKeys: keys,
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                               errorHandler: { url, error in
            enumerationErrors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            return true
        }) else { throw CocoaError(.fileReadNoPermission) }
        let previous = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var tracks: [Track] = [], skipped: [String] = []
        while let url = iterator.nextObject() as? URL {
            try Task.checkCancellation()
            guard Self.extensions.contains(url.pathExtension.lowercased()) else { continue }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let id = url.standardizedFileURL.absoluteString
                if var cached = previous[id], cached.modifiedAt == values.contentModificationDate,
                   cached.fileSize == Int64(values.fileSize ?? 0) {
                    cached.folderID = folder.id
                    tracks.append(cached)
                } else {
                    tracks.append(try await readTrack(url, folderID: folder.id, values: values))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { skipped.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            if tracks.count.isMultiple(of: 20) { await progress(tracks.count) }
        }
        await progress(tracks.count)
        return ScanResult(tracks: tracks, skipped: skipped + enumerationErrors)
    }

    private func readTrack(_ url: URL, folderID: UUID, values: URLResourceValues) async throws -> Track {
        let audio = try AVAudioFile(forReading: url)
        let rate = audio.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, audio.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        var title: String?, artist: String?, album: String?, artworkPath: String?
        for item in metadata {
            if item.commonKey == .commonKeyTitle { title = try? await item.load(.stringValue) }
            else if item.commonKey == .commonKeyArtist { artist = try? await item.load(.stringValue) }
            else if item.commonKey == .commonKeyAlbumName { album = try? await item.load(.stringValue) }
            else if item.commonKey == .commonKeyArtwork, let data = try? await item.load(.dataValue) {
                artworkPath = try? saveArtwork(data)
            }
        }
        var trackNumber = 0
        for item in (try? await asset.load(.metadata)) ?? [] {
            if item.identifier == .id3MetadataTrackNumber,
               let value = try? await item.load(.stringValue) {
                trackNumber = Int(value.split(separator: "/").first.map(String.init) ?? "") ?? 0
            } else if item.identifier == .iTunesMetadataTrackNumber,
                      let data = try? await item.load(.dataValue), data.count >= 4 {
                trackNumber = Int(data[2]) * 256 + Int(data[3])
            }
        }
        if artworkPath == nil {
            for name in ["cover.jpg", "cover.png", "folder.jpg", "front.jpg", "Cover.jpg"] {
                let cover = url.deletingLastPathComponent().appendingPathComponent(name)
                if let attributes = try? FileManager.default.attributesOfItem(atPath: cover.path),
                   (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 20_000_000,
                   let data = try? Data(contentsOf: cover) {
                    artworkPath = try? saveArtwork(data)
                    if artworkPath != nil { break }
                }
            }
        }
        let clean: (String?) -> String? = { value in
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        let filename = url.deletingPathExtension().lastPathComponent
        let parts = filename.components(separatedBy: " - ")
        return Track(url: url, folderID: folderID, title: clean(title) ?? (parts.count == 2 ? parts[1] : filename),
                     artist: clean(artist) ?? (parts.count == 2 ? parts[0] : "未知歌手"),
                     album: clean(album) ?? "未知专辑", duration: Double(audio.length) / rate,
                     trackNumber: trackNumber, artworkPath: artworkPath, modifiedAt: values.contentModificationDate,
                     fileSize: Int64(values.fileSize ?? 0))
    }

    private func saveArtwork(_ data: Data) throws -> String? {
        guard data.count <= 32_000_000 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        let destination = artworkDirectory.appendingPathComponent(hash + ".jpg")
        if !FileManager.default.fileExists(atPath: destination.path) {
            let encoded = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { return nil }
            try (encoded as Data).write(to: destination, options: .atomic)
        }
        return destination.path
    }
}
