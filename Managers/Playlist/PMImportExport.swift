//
// PlaylistManager class extension
//
// This extension contains methods for importing and exporting M3U playlists.
//

import Foundation

// MARK: - Import/Export Result Types

enum M3UImportError: Error, LocalizedError {
    case fileReadFailed(filename: String)
    case invalidFormat(filename: String)
    case emptyFile(filename: String)
    
    var errorDescription: String? {
        switch self {
        case .fileReadFailed(let filename):
            return "Could not read file '\(filename)'"
        case .invalidFormat(let filename):
            return "File '\(filename)' has invalid M3U format"
        case .emptyFile(let filename):
            return "File '\(filename)' contains no tracks"
        }
    }
}

struct PlaylistImportResult {
    let playlistName: String
    let totalTracksInFile: Int
    let tracksAdded: Int
    let tracksMissing: [String]
    let error: Error?
    
    var isSuccess: Bool {
        error == nil && tracksAdded > 0
    }
    
    var hasWarnings: Bool {
        error == nil && !tracksMissing.isEmpty && tracksAdded > 0
    }
    
    var isCompleteFailure: Bool {
        error != nil || (tracksAdded == 0 && totalTracksInFile > 0)
    }
}

struct BulkImportResult {
    let results: [PlaylistImportResult]
    
    var totalFiles: Int { results.count }
    var successful: Int { results.filter { $0.isSuccess && !$0.hasWarnings }.count }
    var withWarnings: Int { results.filter { $0.hasWarnings }.count }
    var failed: Int { results.filter { $0.isCompleteFailure }.count }
    var totalTracksImported: Int { results.reduce(0) { $0 + $1.tracksAdded } }
    var totalTracksMissing: Int { results.reduce(0) { $0 + $1.tracksMissing.count } }
}

struct PlaylistExportResult {
    let playlistName: String
    let error: Error?
    
    var isSuccess: Bool { error == nil }
}

struct BulkExportResult {
    let results: [PlaylistExportResult]
    
    var totalPlaylists: Int { results.count }
    var successful: Int { results.filter { $0.isSuccess }.count }
    var failed: [(playlist: String, error: Error)] {
        results.filter { !$0.isSuccess }.compactMap { result in
            guard let error = result.error else { return nil }
            return (result.playlistName, error)
        }
    }
}

enum M3UFormat {
    static let header = "#EXTM3U"
    static let infoPrefix = "#EXTINF:"
    static let commentPrefix = "#"
    static let lineEnding = "\r\n"
}

// MARK: - PlaylistManager Extension

extension PlaylistManager {
    // MARK: - Import
    
    func importPlaylists(from urls: [URL]) async -> BulkImportResult {
        let existingNames = await fetchExistingPlaylistNames()
        var usedNames = Set(existingNames.map { $0.lowercased() })
        var results: [PlaylistImportResult] = []
        
        for url in urls {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            let result = await importSinglePlaylist(from: url, usedNames: usedNames)
            results.append(result)
            
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
            
            usedNames.insert(result.playlistName.lowercased())
        }
        
        return BulkImportResult(results: results)
    }
    
    private func fetchExistingPlaylistNames() async -> [String] {
        await MainActor.run { playlists.map { $0.name } }
    }
    
    private func importSinglePlaylist(from url: URL, usedNames: Set<String>) async -> PlaylistImportResult {
        let basePlaylistName = url.deletingPathExtension().lastPathComponent
        let sourceDirectory = url.deletingLastPathComponent()
        
        guard let content = readM3UContent(from: url) else {
            Logger.error("Failed to read '\(url.lastPathComponent)' (tried UTF-8 and Latin-1)")
            return PlaylistImportResult(
                playlistName: basePlaylistName,
                totalTracksInFile: 0,
                tracksAdded: 0,
                tracksMissing: [],
                error: M3UImportError.fileReadFailed(filename: url.lastPathComponent)
            )
        }
        
        return await processM3UContent(
            content,
            playlistName: basePlaylistName,
            usedNames: usedNames,
            sourceDirectory: sourceDirectory
        )
    }
    
    private func processM3UContent(
        _ content: String,
        playlistName: String,
        usedNames: Set<String>,
        sourceDirectory: URL? = nil
    ) async -> PlaylistImportResult {
        let entries = M3UTrackMatcher.parseEntries(content)
        let trackPaths = entries.map(\.location)
        
        guard !trackPaths.isEmpty else {
            Logger.error("Empty M3U file: \(playlistName)")
            return PlaylistImportResult(
                playlistName: playlistName,
                totalTracksInFile: 0,
                tracksAdded: 0,
                tracksMissing: [],
                error: M3UImportError.emptyFile(filename: "\(playlistName).m3u")
            )
        }
        
        let matchResult = await matchTracksToLibrary(
            entries: entries,
            sourceDirectory: sourceDirectory
        )
        
        guard !matchResult.matchedTracks.isEmpty else {
            Logger.error("Import failed - '\(playlistName)': 0/\(trackPaths.count) tracks found in library")
            return PlaylistImportResult(
                playlistName: playlistName,
                totalTracksInFile: trackPaths.count,
                tracksAdded: 0,
                tracksMissing: matchResult.unmatchedPaths,
                error: nil
            )
        }
        
        if !matchResult.unmatchedPaths.isEmpty {
            let sample = matchResult.unmatchedPaths.prefix(3).joined(separator: ", ")
            let more = matchResult.unmatchedPaths.count > 3 ? " (+\(matchResult.unmatchedPaths.count - 3) more)" : ""
            let message = """
                Partial import - '\(playlistName)': \(matchResult.matchedTracks.count)/\(trackPaths.count) \
                tracks. Missing: \(sample)\(more)
                """
            Logger.warning(message)
        }
        
        let uniquePlaylistName = generateUniquePlaylistName(baseName: playlistName, existingNames: usedNames)

        // Populate album artwork on matched tracks before creating the playlist
        // so that the collage artwork and gradient are available immediately
        var mutableTracks = matchResult.matchedTracks
        libraryManager?.databaseManager.populateAlbumArtworkForTracks(&mutableTracks)
        let tracksWithArtwork = mutableTracks

        await MainActor.run {
            _ = createPlaylist(name: uniquePlaylistName, tracks: tracksWithArtwork)
        }
        
        return PlaylistImportResult(
            playlistName: uniquePlaylistName,
            totalTracksInFile: trackPaths.count,
            tracksAdded: matchResult.matchedTracks.count,
            tracksMissing: matchResult.unmatchedPaths,
            error: nil
        )
    }
    
    /// Reads a playlist file, falling back to Latin-1 for files that aren't valid UTF-8.
    func readM3UContent(from url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
    }

    /// Library tracks for each entry, in playlist order: by path, then by file name, then
    /// by `M3UTrackMatcher` among the tracks in the folder the entry points to, for files
    /// renamed since the playlist was written.
    private func matchTracksToLibrary(
        entries: [M3UTrackMatcher.Entry],
        sourceDirectory: URL? = nil
    ) async -> (matchedTracks: [Track], unmatchedPaths: [String]) {
        guard let dbManager = libraryManager?.databaseManager else {
            return ([], entries.map(\.location))
        }

        var matches: [Track?] = Array(repeating: nil, count: entries.count)
        let variations = entries.map { generatePathVariations($0.location, sourceDirectory: sourceDirectory) }

        for index in entries.indices {
            for path in variations[index] {
                if let track = await dbManager.findTrackByPath(path) {
                    matches[index] = track
                    break
                }
            }
        }

        let byPath = matches.indices.filter { matches[$0] == nil }
        if !byPath.isEmpty {
            let filenames = byPath.map { (entries[$0].location as NSString).lastPathComponent }
            let filenameMap = await dbManager.findTracksByFilenames(filenames)
            for index in byPath {
                matches[index] = filenameMap[(entries[index].location as NSString).lastPathComponent.lowercased()]
            }
        }

        await matchRenamedLibraryTracks(entries: entries, variations: variations, matches: &matches)

        let unmatchedPaths = entries.indices.filter { matches[$0] == nil }.map { entries[$0].location }
        return (matches.compactMap { $0 }, unmatchedPaths)
    }

    /// Matches the remaining entries against the library tracks in the folder each one
    /// points to or, when the library has no such folder, in the one library folder whose
    /// path ends the same way (an album that moved to another drive or root). Names such as
    /// "Disc 1" that several folders share are compared with their parent, and skipped
    /// when that still leaves more than one folder.
    private func matchRenamedLibraryTracks(
        entries: [M3UTrackMatcher.Entry],
        variations: [[String]],
        matches: inout [Track?]
    ) async {
        let unresolved = matches.indices.filter { matches[$0] == nil }
        guard !unresolved.isEmpty, let library = libraryManager else { return }

        let databaseManager = library.databaseManager
        let libraryTracks = await Task.detached { databaseManager.tracksForMatching() }.value
        let taken = Set(matches.compactMap { $0?.trackId })
        var tracksByFolder: [String: [Track]] = [:]
        for track in libraryTracks where !taken.contains(track.trackId ?? -1) {
            tracksByFolder[track.url.deletingLastPathComponent().path.lowercased(), default: []].append(track)
        }
        let libraryFolders = Array(tracksByFolder.keys)

        var entriesByFolder: [String: [Int]] = [:]
        for index in unresolved {
            guard let path = variations[index].first else { continue }
            let folder = (path as NSString).deletingLastPathComponent
            entriesByFolder[folder, default: []].append(index)
        }

        for (folder, entryIndexes) in entriesByFolder {
            let libraryFolder = tracksByFolder[folder.lowercased()] != nil
                ? folder.lowercased()
                : Self.libraryFolder(endingLike: folder, in: libraryFolders)
            guard let libraryFolder, let candidates = tracksByFolder[libraryFolder] else { continue }

            let pairs = M3UTrackMatcher.match(
                entryIndexes.map { entries[$0] },
                to: candidates.map {
                    M3UTrackMatcher.Candidate(
                        filename: $0.filename,
                        title: $0.title,
                        trackNumber: $0.trackNumber,
                        discNumber: $0.discNumber,
                        duration: $0.duration
                    )
                }
            )
            for (position, candidateIndex) in pairs {
                matches[entryIndexes[position]] = candidates[candidateIndex]
            }
            if !pairs.isEmpty {
                Logger.info("Matched \(pairs.count) renamed playlist entries in '\(folder)' by tags")
            }
        }
    }
    
    /// The single library folder whose last two path components, or else whose name, match
    /// those of `folder`; nil when none or several do.
    private static func libraryFolder(endingLike folder: String, in libraryFolders: [String]) -> String? {
        func suffix(_ path: String, _ count: Int) -> [Substring] {
            path.lowercased().split(separator: "/").suffix(count)
        }
        for count in [2, 1] {
            let wanted = suffix(folder, count)
            guard wanted.count == count else { continue }
            let hits = libraryFolders.filter { suffix($0, count) == wanted }
            if hits.count == 1 { return hits[0] }
            if hits.count > 1 { return nil }
        }
        return nil
    }

    /// Generates possible path variations for M3U import matching
    func generatePathVariations(_ path: String, sourceDirectory: URL? = nil) -> [String] {
        var normalized = path
        
        for scheme in ["file://", "smb://", "afp://", "nfs://"] where normalized.lowercased().hasPrefix(scheme) {
            normalized = String(normalized.dropFirst(scheme.count))
            break
        }
        
        // Handle Windows-style UNC paths (leading double-slash, e.g. server/share)
        if normalized.hasPrefix("//") {
            normalized = "/Volumes" + String(normalized.dropFirst(1))
        }
        
        normalized = normalized.replacingOccurrences(of: "\\", with: "/")
        
        // URL decode
        normalized = normalized.removingPercentEncoding ?? normalized
        
        var variations = [normalized]
        
        if normalized.hasPrefix("/Volumes/") {
            variations.append(String(normalized.dropFirst(8)))
        } else if normalized.hasPrefix("/") && !normalized.hasPrefix("/Users/") {
            variations.append("/Volumes" + normalized)
        } else if !normalized.hasPrefix("/"), let sourceDirectory {
            var relativePath = normalized
            while relativePath.hasPrefix("./") {
                relativePath = String(relativePath.dropFirst(2))
            }
            let resolved = sourceDirectory.appendingPathComponent(relativePath).standardizedFileURL.path
            variations.insert(resolved, at: 0)
        }
        
        return variations
    }
    
    private func generateUniquePlaylistName(baseName: String, existingNames: Set<String>) -> String {
        guard existingNames.contains(baseName.lowercased()) else {
            return baseName
        }
        
        let baseNameLower = baseName.lowercased()
        let highestNumber = existingNames.reduce(1) { currentMax, name in
            guard name.hasPrefix(baseNameLower + " ") else { return currentMax }
            let suffix = String(name.dropFirst(baseNameLower.count + 1))
            return max(currentMax, Int(suffix) ?? 0)
        }
        
        return "\(baseName) \(highestNumber + 1)"
    }
    
    // MARK: - Export
    
    func exportPlaylists(_ playlists: [Playlist], to directoryURL: URL) async -> BulkExportResult {
        var results: [PlaylistExportResult] = []
        
        for playlist in playlists {
            let filename = FilesystemUtils.sanitizeFilename(playlist.name) + ".m3u"
            let fileURL = directoryURL.appendingPathComponent(filename)
            let result = await exportSinglePlaylist(playlist, to: fileURL)
            results.append(result)
        }
        
        return BulkExportResult(results: results)
    }
    
    private func exportSinglePlaylist(_ playlist: Playlist, to fileURL: URL) async -> PlaylistExportResult {
        let tracks = playlist.tracks.isEmpty
            ? await MainActor.run { getPlaylistTracks(playlist) }
            : playlist.tracks
        
        let m3uContent = generateM3UContent(for: tracks)
        
        do {
            try FilesystemUtils.writeM3UFile(content: m3uContent, to: fileURL)
            return PlaylistExportResult(
                playlistName: playlist.name,
                error: nil
            )
        } catch {
            Logger.error("Failed to export '\(playlist.name)': \(error)")
            return PlaylistExportResult(
                playlistName: playlist.name,
                error: error
            )
        }
    }
    
    private func generateM3UContent(for tracks: [Track]) -> String {
        var lines = [M3UFormat.header]
        
        for track in tracks {
            let durationSeconds = Int(track.duration)
            let artistTitle = "\(track.artist) - \(track.title)"
            lines.append("\(M3UFormat.infoPrefix)\(durationSeconds),\(artistTitle)")
            lines.append(track.url.path)
        }
        
        return lines.joined(separator: M3UFormat.lineEnding)
    }
}
