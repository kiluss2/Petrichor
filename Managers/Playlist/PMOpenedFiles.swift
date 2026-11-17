//
// PlaylistManager class extension
//
// This extension plays audio files and M3U playlists opened from Finder ("Open With",
// a drop on the Dock icon). They play for the current session only: nothing is added
// to the library, and tracks outside it are dropped when the session is restored.
//

import AppKit
import Foundation

extension PlaylistManager {
    private static let openablePlaylistExtensions: Set<String> = ["m3u", "m3u8"]

    /// Replaces the queue with the opened files and starts the first one. Files that are
    /// already in the library play as their library tracks, so favorites and play counts
    /// still apply; the rest are read from disk without being imported.
    func playOpenedFiles(_ urls: [URL]) {
        Task { await playOpenedFilesAsync(urls) }
    }

    private func playOpenedFilesAsync(_ urls: [URL]) async {
        var playableURLs: [URL] = []
        var missingCount = 0
        var unsupported: [URL] = []

        for url in urls where Self.openablePlaylistExtensions.contains(url.pathExtension.lowercased()) {
            let result = await resolvePlaylistEntries(of: url)
            playableURLs += result.playable
            missingCount += result.missingCount
        }

        // Open events don't carry the order files were selected in; file name order
        // matches the track numbering most albums use.
        let audioFiles = urls
            .filter { !Self.openablePlaylistExtensions.contains($0.pathExtension.lowercased()) }
            .filter { url in
                guard AudioFormat.isSupported(url.pathExtension) else {
                    unsupported.append(url)
                    return false
                }
                return true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        playableURLs += audioFiles

        if !unsupported.isEmpty {
            Logger.warning("Ignored unsupported opened files: \(unsupported.map(\.lastPathComponent))")
            NotificationManager.shared.addMessage(
                .warning,
                String(localized: "\(unsupported.count) opened file(s) are not a supported audio format")
            )
        }
        if missingCount > 0 {
            NotificationManager.shared.addMessage(
                .warning,
                String(localized: "\(missingCount) playlist track(s) could not be found or read")
            )
        }

        let tracks = await sessionTracks(for: playableURLs)
        guard let first = tracks.first else {
            Logger.warning("Nothing playable among \(urls.count) opened file(s)")
            return
        }

        await MainActor.run {
            AppCoordinator.shared?.cancelPlaybackRestoration()
            currentQueueSource = .library
            playTrack(first, fromTracks: tracks)
            // Again for a launch by the open event, whose window only exists by now.
            WindowManager.shared.bringMainWindowForward()
            Logger.info("Playing \(tracks.count) opened track(s) for this session")
        }
    }

    // MARK: - Playlists

    /// The readable, supported files a playlist lists, in its order. When the sandbox
    /// blocks the folders holding the rest, asks once for access to them; the grant lasts
    /// until the app quits and is never stored. Entries whose files were renamed are matched
    /// by `M3UTrackMatcher`; a playlist that still mostly fails to resolve is not played.
    private func resolvePlaylistEntries(of playlistURL: URL) async -> (playable: [URL], missingCount: Int) {
        let name = playlistURL.lastPathComponent
        guard let content = readM3UContent(from: playlistURL) else {
            NotificationManager.shared.addMessage(.error, String(localized: "Could not read playlist '\(name)'"))
            return ([], 0)
        }

        let sourceDirectory = playlistURL.deletingLastPathComponent()
        let entries = M3UTrackMatcher.parseEntries(content)
        let locations = entries.map {
            generatePathVariations($0.location, sourceDirectory: sourceDirectory)
                .map { URL(fileURLWithPath: $0).standardizedFileURL }
        }
        var resolved = locations.map(Self.firstPlayableFile)

        let blockedFolders = Set(
            zip(locations, resolved)
                .filter { $0.1 == nil }
                .compactMap { $0.0.first?.deletingLastPathComponent() }
                .filter { !Self.canListFolder($0) }
        )
        if let folder = Self.commonAncestor(of: Array(blockedFolders)),
           await requestFolderAccess(
               folder,
               message: String(
                   localized: "Allow Petrichor to read the tracks of '\(name)'. Access lasts until Petrichor quits."
               )
           ) {
            for index in resolved.indices where resolved[index] == nil {
                resolved[index] = Self.firstPlayableFile(in: locations[index])
            }
        }

        let matchedByTags = await matchRenamedFiles(entries: entries, locations: locations, resolved: &resolved)

        let playable = resolved.compactMap { $0 }
        Logger.info(
            "Opened playlist '\(name)': \(playable.count)/\(entries.count) playable, \(matchedByTags) matched by tags"
        )

        guard !entries.isEmpty,
              Double(playable.count) / Double(entries.count) >= M3UTrackMatcher.minimumResolvedShare else {
            Logger.warning("Playlist '\(name)' does not match the files it points to; not playing it")
            NotificationManager.shared.addMessage(
                .warning,
                String(localized: "'\(name)' doesn't match the files in its folder (\(playable.count)/\(entries.count) found), so it wasn't played")
            )
            return ([], 0)
        }
        if matchedByTags > 0 {
            NotificationManager.shared.addMessage(
                .info,
                String(localized: "\(matchedByTags) renamed track(s) in '\(name)' were matched by track number, length and title")
            )
        }
        return (playable, entries.count - playable.count)
    }

    /// Fills unresolved entries from the files in the folder each one points to.
    /// - Returns: how many entries were matched this way.
    private func matchRenamedFiles(
        entries: [M3UTrackMatcher.Entry],
        locations: [[URL]],
        resolved: inout [URL?]
    ) async -> Int {
        let taken = Set(resolved.compactMap { $0 })
        var unresolvedByFolder: [URL: [Int]] = [:]
        for index in resolved.indices where resolved[index] == nil {
            guard let folder = locations[index].first?.deletingLastPathComponent() else { continue }
            unresolvedByFolder[folder, default: []].append(index)
        }

        var matched = 0
        for (folder, entryIndexes) in unresolvedByFolder {
            let files = Self.audioFiles(in: folder).filter { !taken.contains($0) }
            guard !files.isEmpty, files.count <= Self.maximumFolderFilesToMatch else { continue }

            let candidates = await Self.matchCandidates(for: files)

            let pairs = M3UTrackMatcher.match(entryIndexes.map { entries[$0] }, to: candidates)
            for (position, candidateIndex) in pairs {
                resolved[entryIndexes[position]] = files[candidateIndex]
                matched += 1
            }
        }
        return matched
    }

    /// Asks the user to pick `folder` in an open panel, which grants access to it until
    /// the app quits. The grant is never stored.
    /// The files' tags, read concurrently, in the files' order.
    private static func matchCandidates(for files: [URL]) async -> [M3UTrackMatcher.Candidate] {
        await withTaskGroup(of: (Int, M3UTrackMatcher.Candidate).self) { group in
            for (index, file) in files.enumerated() {
                group.addTask {
                    let metadata = await MetadataEngine.extractMetadata(from: file)
                    return (index, M3UTrackMatcher.Candidate(
                        filename: file.lastPathComponent,
                        title: metadata.title,
                        trackNumber: metadata.trackNumber,
                        discNumber: metadata.discNumber,
                        duration: metadata.duration
                    ))
                }
            }
            var candidates = [M3UTrackMatcher.Candidate?](repeating: nil, count: files.count)
            for await (index, candidate) in group {
                candidates[index] = candidate
            }
            return candidates.compactMap { $0 }
        }
    }

    @MainActor
    func requestFolderAccess(_ folder: URL, message: String) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Allow")
        panel.message = message

        WindowManager.shared.bringMainWindowForward()
        guard panel.runModal() == .OK else {
            Logger.info("Folder access declined for \(folder.path)")
            return false
        }
        Logger.info("Folder access granted for this session: \(panel.urls.first?.path ?? "")")
        return true
    }

    /// Reading every file's tags gets slow in a large folder, and a playlist pointing into
    /// one is unlikely to be an album that was renamed.
    private static let maximumFolderFilesToMatch = 300

    private static func audioFiles(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { AudioFormat.isSupported($0.pathExtension) }
            .map(\.standardizedFileURL)
    }

    private static func firstPlayableFile(in candidates: [URL]) -> URL? {
        candidates.first { AudioFormat.isSupported($0.pathExtension) && canReadFile($0) }
    }

    /// Opens the file rather than checking its permissions, which the sandbox does not reflect.
    private static func canReadFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }

    private static func canListFolder(_ folder: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
    }

    private static func commonAncestor(of folders: [URL]) -> URL? {
        guard var common = folders.first?.pathComponents else { return nil }
        for folder in folders.dropFirst() {
            let components = folder.pathComponents
            let shared = zip(common, components).prefix { $0 == $1 }.count
            common = Array(common.prefix(shared))
        }
        guard common.count > 1 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true)
    }

    // MARK: - Session Tracks

    /// One track per URL, in order: the library's own when the file is in it, otherwise a
    /// track built from the file's tags with no database ID.
    private func sessionTracks(for urls: [URL]) async -> [Track] {
        let databaseManager = libraryManager?.databaseManager
        let folders = Set(urls.map { $0.deletingLastPathComponent() })
        var folderArtwork: [URL: Data] = [:]
        for folder in folders {
            folderArtwork[folder] = Self.folderArtwork(in: folder)
        }

        return await withTaskGroup(of: (Int, Track).self) { [folderArtwork] group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    if let libraryTrack = await databaseManager?.findTrackByPath(url.path) {
                        return (index, libraryTrack)
                    }
                    let artwork = folderArtwork[url.deletingLastPathComponent()]
                    return (index, await Self.sessionOnlyTrack(for: url, folderArtwork: artwork))
                }
            }

            var tracks: [Track?] = Array(repeating: nil, count: urls.count)
            for await (index, track) in group {
                tracks[index] = track
            }
            return tracks.compactMap { $0 }
        }
    }

    private static func sessionOnlyTrack(for url: URL, folderArtwork: Data?) async -> Track {
        let metadata = await MetadataEngine.extractMetadata(from: url, externalArtwork: folderArtwork)

        var track = Track(url: url)
        track.title = metadata.title?.nilIfEmpty ?? url.deletingPathExtension().lastPathComponent
        track.artist = metadata.artist?.nilIfEmpty ?? "Unknown Artist"
        track.album = metadata.album?.nilIfEmpty ?? "Unknown Album"
        track.genre = metadata.genre?.nilIfEmpty ?? "Unknown Genre"
        track.composer = metadata.composer?.nilIfEmpty ?? "Unknown Composer"
        track.year = metadata.year?.nilIfEmpty ?? ""
        track.duration = HelperUtils.sanitizedDuration(metadata.duration)
        track.albumArtist = metadata.albumArtist
        track.trackNumber = metadata.trackNumber
        track.discNumber = metadata.discNumber
        track.codec = metadata.codec
        track.bitrate = metadata.bitrate
        track.sampleRate = metadata.sampleRate
        track.channels = metadata.channels
        track.lossless = metadata.lossless
        track.setArtworkData(metadata.artworkData)
        return track
    }

    /// The first known cover image (cover.jpg, folder.png, ...) in `folder`, as a library
    /// scan would use it. In the sandbox this only reads folders the app has access to.
    static func folderArtwork(in folder: URL) -> Data? {
        for name in AlbumArtFormat.knownFilenames {
            for fileExtension in AlbumArtFormat.supportedExtensions {
                let candidate = folder.appendingPathComponent(name).appendingPathExtension(fileExtension)
                guard let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                      size <= AlbumArtFormat.maxArtworkSize,
                      let data = try? Data(contentsOf: candidate) else { continue }
                return ImageUtils.compressImage(from: data, source: candidate.path) ?? data
            }
        }
        return nil
    }
}
