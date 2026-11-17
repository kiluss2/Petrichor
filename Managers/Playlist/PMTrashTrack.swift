//
// PlaylistManager class extension
//
// This extension moves a track's file to the Trash from inside the app, then removes the
// track everywhere it appears: the play queue, the library and the playlists holding it.
// Edit > Undo (⌘Z) puts the file back and the track where it was; Redo trashes it again.
//

import AppKit
import Foundation

extension PlaylistManager {
    /// What a move to the Trash changed, kept for Undo.
    struct TrashedTrack {
        let originalURL: URL
        let trashedURL: URL
        /// The track as it was, with its favorite, play count and dates.
        let track: Track
        let playlistEntries: [PlaylistTrack]
        /// Where the track sat in the play queue, ascending.
        let queuePositions: [Int]
    }

    /// Asks for confirmation, then moves the track's file to the Trash.
    @MainActor
    func confirmMoveToTrash(_ track: Track) {
        let confirmed = Self.confirm(
            String(localized: "Move “\(track.title)” to the Trash?"),
            information: track.trackId != nil
                ? String(
                    localized: "The file is moved to the Trash and removed from your library, playlists and the play queue. Edit > Undo puts it back."
                )
                : String(localized: "The file is moved to the Trash and removed from the play queue. Edit > Undo puts it back."),
            action: String(localized: "Move to Trash"),
            isDestructive: true
        )
        guard confirmed else { return }
        Task { await moveToTrash(track) }
    }

    @MainActor
    private static func confirm(_ message: String, information: String, action: String, isDestructive: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = isDestructive ? .warning : .informational
        alert.messageText = message
        alert.informativeText = information
        alert.addButton(withTitle: action).hasDestructiveAction = isDestructive
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func moveToTrash(_ track: Track) async {
        let url = track.url
        let name = url.lastPathComponent

        // Read before anything changes: the playlist rows go with the track's library row.
        let libraryTrack = await libraryTrack(for: track)
        let playlistEntries: [PlaylistTrack]
        if let trackId = libraryTrack?.trackId, let databaseManager = libraryManager?.databaseManager {
            playlistEntries = await databaseManager.playlistEntries(forTrackId: trackId)
        } else {
            playlistEntries = []
        }

        let trashedURL: URL
        do {
            trashedURL = try await trashFile(at: url)
        } catch {
            Logger.error("Failed to move \(url.path) to the Trash: \(error)")
            NotificationManager.shared.addMessage(
                .error,
                String(localized: "Couldn't move '\(name)' to the Trash: \(error.localizedDescription)")
            )
            return
        }
        Logger.info("Moved to the Trash: \(url.path)")

        let queuePositions = await MainActor.run { removeQueueEntries(forTrashedFileAt: url) }
        if let libraryTrack {
            await removeFromLibrary(libraryTrack, trashedFileAt: url)
        }
        NotificationManager.shared.addMessage(.info, String(localized: "Moved '\(name)' to the Trash"))

        let trashed = TrashedTrack(
            originalURL: url,
            trashedURL: trashedURL,
            track: libraryTrack ?? track,
            playlistEntries: playlistEntries,
            queuePositions: queuePositions
        )
        await MainActor.run { registerUndo(for: trashed) }
    }

    private func libraryTrack(for track: Track) async -> Track? {
        if track.trackId != nil { return track }
        return await libraryManager?.databaseManager.findTrackByPath(track.url.path)
    }

    // MARK: - Undo

    /// Registers on the main window's undo manager, which Edit > Undo (⌘Z) reaches
    /// from anywhere in that window.
    @MainActor
    private func registerUndo(for trashed: TrashedTrack) {
        guard let undoManager = WindowManager.shared.mainWindow?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { manager in
            MainActor.assumeIsolated {
                guard manager.confirmPutBack(trashed) else {
                    // The undo is already off the stack; offer it again once this one ends.
                    DispatchQueue.main.async { manager.registerUndo(for: trashed) }
                    return
                }
                // Redo must be registered while the undo runs, before the async restore.
                undoManager.registerUndo(withTarget: manager) { manager in
                    Task { await manager.redoMoveToTrash(trashed) }
                }
                undoManager.setActionName(String(localized: "Move to Trash"))
                Task { await manager.restoreFromTrash(trashed, undoManager: undoManager) }
            }
        }
        undoManager.setActionName(String(localized: "Move to Trash"))
    }

    @MainActor
    private func confirmPutBack(_ trashed: TrashedTrack) -> Bool {
        Self.confirm(
            String(localized: "Put “\(trashed.track.title)” back?"),
            information: trashed.track.trackId != nil
                ? String(localized: "The file returns from the Trash to its folder, and the track to your library, playlists and the play queue.")
                : String(localized: "The file returns from the Trash to its folder, and the track to the play queue."),
            action: String(localized: "Put Back"),
            isDestructive: false
        )
    }

    private func restoreFromTrash(_ trashed: TrashedTrack, undoManager: UndoManager) async {
        let name = trashed.originalURL.lastPathComponent
        do {
            try await moveBack(trashed)
        } catch {
            Logger.error("Failed to put back \(trashed.originalURL.path): \(error)")
            NotificationManager.shared.addMessage(
                .error,
                String(localized: "Couldn't put back '\(name)': \(error.localizedDescription)")
            )
            // The redo registered for this undo has nothing to trash again.
            await MainActor.run { undoManager.removeAllActions(withTarget: self) }
            return
        }
        Logger.info("Put back from the Trash: \(trashed.originalURL.path)")

        let libraryTrack = trashed.track.trackId != nil ? await restoreToLibrary(trashed) : nil
        let restoredTrack = libraryTrack ?? trashed.track
        await MainActor.run {
            for position in trashed.queuePositions {
                insertIntoQueue(restoredTrack, at: position)
            }
        }
        NotificationManager.shared.addMessage(.info, String(localized: "Put back '\(name)'"))
    }

    /// Moves the file from the Trash back to where it was. Asks for the folder when the
    /// sandbox only covered the file, as when it was opened from Finder.
    private func moveBack(_ trashed: TrashedTrack) async throws {
        let name = trashed.originalURL.lastPathComponent
        guard !FileManager.default.fileExists(atPath: trashed.originalURL.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: trashed.originalURL.path])
        }
        try await withFolderAccess(
            to: trashed.originalURL.deletingLastPathComponent(),
            message: String(localized: "Allow Petrichor to put '\(name)' back in this folder. Access lasts until Petrichor quits.")
        ) {
            try FileManager.default.moveItem(at: trashed.trashedURL, to: trashed.originalURL)
        }
    }

    private func restoreToLibrary(_ trashed: TrashedTrack) async -> Track? {
        guard let libraryManager, let folderId = trashed.track.folderId else { return nil }
        let databaseManager = libraryManager.databaseManager
        let directory = trashed.originalURL.deletingLastPathComponent()

        let restored: Track?
        do {
            restored = try await databaseManager.restoreTrashedTrack(
                at: trashed.originalURL,
                folderId: folderId,
                previous: trashed.track,
                playlistEntries: trashed.playlistEntries,
                folderArtwork: Self.folderArtwork(in: directory)
            )
        } catch {
            Logger.error("Failed to restore \(trashed.originalURL.path) to the library: \(error)")
            NotificationManager.shared.addMessage(
                .warning,
                String(localized: "'\(trashed.originalURL.lastPathComponent)' is back but stays out of the library until the next scan")
            )
            return nil
        }
        await reloadLibraryViews()
        return restored
    }

    private func redoMoveToTrash(_ trashed: TrashedTrack) async {
        let current = await libraryManager?.databaseManager.findTrackByPath(trashed.originalURL.path)
        await moveToTrash(current ?? trashed.track)
    }

    // MARK: - Files

    /// - Returns: where the file now is in the Trash.
    private func trashFile(at url: URL) async throws -> URL {
        var trashedURL: NSURL?
        try await withFolderAccess(
            to: url.deletingLastPathComponent(),
            message: String(localized: "Allow Petrichor to move '\(url.lastPathComponent)' to the Trash. Access lasts until Petrichor quits.")
        ) {
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
        }
        guard let trashedURL = trashedURL as URL? else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return trashedURL
    }

    /// Runs a file operation that changes `folder`. A file opened from Finder comes with
    /// access to itself only, so on a permission error this asks once for the folder, for
    /// this session, and retries.
    private func withFolderAccess(to folder: URL, message: String, _ operation: () throws -> Void) async throws {
        do {
            try operation()
        } catch where Self.isPermissionError(error) {
            guard await requestFolderAccess(folder, message: message) else { throw error }
            try operation()
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(nsError.code) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return underlying.code == Int(EPERM) || underlying.code == Int(EACCES)
        }
        return false
    }

    // MARK: - Queue

    /// Drops every queue entry for the file. When it is the one playing, playback first
    /// moves on to the next other track, wrapping only under repeat-all, or stops when
    /// none is left.
    /// - Returns: the positions the entries had, ascending.
    @MainActor
    private func removeQueueEntries(forTrashedFileAt url: URL) -> [Int] {
        let path = url.standardizedFileURL.path
        let isTrashed = { (track: Track) in track.url.standardizedFileURL.path == path }
        let positions = currentQueue.indices.filter { isTrashed(currentQueue[$0]) }

        var remove = removeFromQueue(at:)
        if currentQueue.indices.contains(currentQueueIndex), isTrashed(currentQueue[currentQueueIndex]) {
            if let next = nextIndex(after: currentQueueIndex, skipping: isTrashed) {
                playFromQueue(at: next)
            } else {
                audioPlayer?.stop()
                // Nothing plays any more, so the engine has no entry to keep in step.
                remove = dropQueueEntry(at:)
            }
        }
        for index in positions.reversed() {
            remove(index)
        }
        return positions
    }

    private func nextIndex(after index: Int, skipping isSkipped: (Track) -> Bool) -> Int? {
        let following = Array(currentQueue.indices.dropFirst(index + 1))
        let candidates = repeatMode == .all ? following + Array(currentQueue.indices.prefix(index)) : following
        return candidates.first { !isSkipped(currentQueue[$0]) }
    }

    // MARK: - Library

    /// Removes the track's row, its playlist entries and pins, and any artist or album
    /// left without tracks, then reloads what the views show as a rescan would.
    private func removeFromLibrary(_ track: Track, trashedFileAt url: URL) async {
        guard let databaseManager = libraryManager?.databaseManager else { return }
        do {
            try await databaseManager.cleanupAfterTrackRemoval([track])
        } catch {
            Logger.error("Failed to remove trashed track from the library: \(error)")
            NotificationManager.shared.addMessage(
                .error,
                String(localized: "'\(url.lastPathComponent)' was moved to the Trash but is still listed until the next scan")
            )
            return
        }
        // The track may have been the copy its duplicates were hidden behind.
        await databaseManager.detectAndMarkDuplicates()
        await reloadLibraryViews()
    }

    private func reloadLibraryViews() async {
        guard let libraryManager else { return }
        await libraryManager.loadPinnedItems()
        await MainActor.run {
            libraryManager.refreshLibraryCategories()
            libraryManager.loadMusicLibrary()
            libraryManager.updateSearchResults()
            libraryManager.updateTotalCounts()
            loadPlaylists()
        }
    }
}
