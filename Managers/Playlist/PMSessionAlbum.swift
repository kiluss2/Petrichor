//
// PlaylistManager class extension
//
// This extension gathers an album for tracks opened from Finder, which the library does
// not hold: the play queue tracks that share the album's title and album artist.
//

import Foundation

extension PlaylistManager {
    /// An album made of play queue tracks, for a track outside the library.
    struct SessionAlbum {
        let entity: AlbumEntity
        let tracks: [Track]
    }

    /// The queue tracks outside the library on the same album as `track`, by title and
    /// album artist (or artist, when the album artist is not tagged), in disc and track
    /// order. Nil for a library track, or one without an album tag.
    func sessionAlbum(for track: Track) -> SessionAlbum? {
        guard track.trackId == nil, !track.album.isEmpty,
              track.album != LibraryFilterType.albums.unknownPlaceholder else { return nil }

        let credited = track.albumCredit
        var seenPaths = Set<String>()
        let tracks = currentQueue.enumerated()
            .filter { _, queued in
                queued.trackId == nil
                    && queued.album.caseInsensitiveCompare(track.album) == .orderedSame
                    && queued.albumCredit.caseInsensitiveCompare(credited) == .orderedSame
                    && seenPaths.insert(queued.url.standardizedFileURL.path).inserted
            }
            .sorted { lhs, rhs in
                let lhsOrder = (lhs.element.discNumber ?? 1, lhs.element.trackNumber ?? Int.max, lhs.offset)
                let rhsOrder = (rhs.element.discNumber ?? 1, rhs.element.trackNumber ?? Int.max, rhs.offset)
                return lhsOrder < rhsOrder
            }
            .map(\.element)
        guard !tracks.isEmpty else { return nil }

        let entity = AlbumEntity(
            name: track.album,
            trackCount: tracks.count,
            artworkData: tracks.first { $0.albumArtworkData != nil }?.albumArtworkData,
            year: tracks.first { !$0.year.isEmpty }?.year,
            duration: tracks.reduce(0) { $0 + HelperUtils.sanitizedDuration($1.duration) },
            artistName: credited
        )
        return SessionAlbum(entity: entity, tracks: tracks)
    }

    /// Plays `track` where it already sits in the queue, so the album page doesn't replace
    /// a queue it was built from. Falls back to queueing `albumTracks` when it has left.
    func playSessionAlbumTrack(_ track: Track, in albumTracks: [Track]) {
        let path = track.url.standardizedFileURL.path
        if let index = currentQueue.firstIndex(where: { $0.url.standardizedFileURL.path == path }) {
            playFromQueue(at: index)
        } else {
            playTrack(track, fromTracks: albumTracks)
        }
    }
}
