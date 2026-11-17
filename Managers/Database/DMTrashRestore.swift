//
// DatabaseManager class extension
//
// This extension puts a track back into the library after the file moved to the Trash
// from inside the app is restored by Undo, with the user data it had before.
//

import Foundation
import GRDB

extension DatabaseManager {
    /// The playlist rows holding a track, so an Undo can put it back in the same places.
    func playlistEntries(forTrackId trackId: Int64) async -> [PlaylistTrack] {
        do {
            return try await dbQueue.read { db in
                try PlaylistTrack
                    .filter(PlaylistTrack.Columns.trackId == trackId)
                    .fetchAll(db)
            }
        } catch {
            Logger.error("Failed to read playlist entries for track \(trackId): \(error)")
            return []
        }
    }

    /// Imports the restored file as a scan would, then gives the new row the favorite,
    /// play count and dates of the track it replaces and puts it back into its playlists
    /// at the positions it had.
    /// - Returns: the restored library track.
    func restoreTrashedTrack(
        at url: URL,
        folderId: Int64,
        previous: Track,
        playlistEntries: [PlaylistTrack],
        folderArtwork: Data?
    ) async throws -> Track? {
        let directory = url.deletingLastPathComponent()
        try await processBatch(
            [(url: url, folderId: folderId)],
            artworkMap: folderArtwork.map { [directory: $0] } ?? [:]
        )
        guard let restored = await findTrackByPath(url.path), let trackId = restored.trackId else {
            return nil
        }

        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE tracks SET is_favorite = ?, play_count = ?, last_played_date = ?, date_added = ?
                    WHERE id = ?
                    """,
                arguments: [
                    previous.isFavorite, previous.playCount, previous.lastPlayedDate,
                    previous.dateAdded ?? restored.dateAdded, trackId
                ]
            )
            // Ascending, so each row goes back where it was among the ones before it.
            for entry in playlistEntries.sorted(by: { $0.position < $1.position }) {
                try db.execute(
                    sql: "UPDATE playlist_tracks SET position = position + 1 WHERE playlist_id = ? AND position >= ?",
                    arguments: [entry.playlistId, entry.position]
                )
                try PlaylistTrack(
                    playlistId: entry.playlistId,
                    trackId: trackId,
                    position: entry.position,
                    dateAdded: entry.dateAdded
                ).insert(db)
            }
        }
        await detectAndMarkDuplicates()
        return await findTrackByPath(url.path)
    }
}
