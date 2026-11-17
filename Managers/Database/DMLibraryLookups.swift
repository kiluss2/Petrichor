//
// DatabaseManager class extension
//
// This extension finds library tracks and albums for files that are not in the library
// themselves: playlist entries whose files were renamed, and tracks opened from Finder.
//

import Foundation
import GRDB

extension DatabaseManager {
    /// Every library track without artwork, for matching by tags. `LibraryManager.tracks`
    /// is only filled on demand, so it cannot stand in for this.
    func tracksForMatching() -> [Track] {
        do {
            return try dbQueue.read { db in
                try Track.lightweightRequest().fetchAll(db)
            }
        } catch {
            Logger.error("Failed to fetch tracks for matching: \(error)")
            return []
        }
    }

    /// The library album titled `title` (ignoring case) by `albumArtist`, compared with each
    /// track's album artist or, without one, its artist. Titles such as "Original Soundtrack"
    /// repeat across artists, so without an artist an album is only returned when it is the
    /// one album with that title.
    func libraryAlbum(titled title: String, by albumArtist: String?) -> (id: Int64, title: String)? {
        do {
            let rows = try dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT album_id, album, COALESCE(NULLIF(album_artist, ''), artist) AS credited
                        FROM tracks
                        WHERE album_id IS NOT NULL AND album = ? COLLATE NOCASE
                        GROUP BY album_id, credited
                        """,
                    arguments: [title]
                )
            }
            let albums = rows.map { (id: $0["album_id"] as Int64, title: $0["album"] as String, credited: $0["credited"] as String?) }
            if let albumArtist {
                return albums
                    .first { $0.credited?.caseInsensitiveCompare(albumArtist) == .orderedSame }
                    .map { ($0.id, $0.title) }
            }
            guard Set(albums.map(\.id)).count == 1, let album = albums.first else { return nil }
            return (album.id, album.title)
        } catch {
            Logger.error("Failed to look up album '\(title)': \(error)")
            return nil
        }
    }
}
