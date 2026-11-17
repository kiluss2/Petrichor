import SwiftUI

enum TrackContextMenu {
    static func createMenuItems(
        for track: Track,
        playlistManager: PlaylistManager,
        currentContext: MenuContext
    ) -> [ContextMenuItem] {
        var items: [ContextMenuItem] = []
        
        // Add playback items
        items.append(contentsOf: createPlaybackItems(
            for: track,
            playlistManager: playlistManager,
            currentContext: currentContext
        ))

        items.append(.divider)

        // Add info item
        items.append(createShowInfoItem(for: track))
        
        items.append(createRevealInFinderItem(for: track))
        
        items.append(.divider)
        
        // Add "Go to" submenu
        if let goToMenu = createGoToMenu(for: track) {
            items.append(goToMenu)
        }
        
        items.append(.divider)
        
        // Add playlist items
        items.append(contentsOf: createPlaylistItems(
            for: track,
            playlistManager: playlistManager
        ))
        
        // Add context-specific items
        items.append(contentsOf: createContextSpecificItems(
            for: track,
            playlistManager: playlistManager,
            currentContext: currentContext
        ))

        items.append(.divider)
        items.append(createMoveToTrashItem(for: track, playlistManager: playlistManager))
        
        return items
    }
    
    static func createMenuItems(
        for tracks: [Track],
        playlistManager: PlaylistManager,
        currentContext: MenuContext
    ) -> [ContextMenuItem] {
        if tracks.count == 1, let track = tracks.first {
            return createMenuItems(
                for: track,
                playlistManager: playlistManager,
                currentContext: currentContext
            )
        }
        
        var items: [ContextMenuItem] = []
        
        items.append(contentsOf: createBulkPlaybackItems(
            for: tracks,
            playlistManager: playlistManager
        ))
        
        items.append(.divider)
        
        items.append(contentsOf: createBulkPlaylistItems(
            for: tracks,
            playlistManager: playlistManager,
            currentContext: currentContext
        ))
        
        return items
    }
    
    static func createPlayerViewMenuItems(
        for track: Track,
        playlistManager: PlaylistManager
    ) -> [ContextMenuItem] {
        var items: [ContextMenuItem] = []
        
        // Add info item
        items.append(createShowInfoItem(for: track))
        
        items.append(createRevealInFinderItem(for: track))
        
        // A track opened from Finder for the session only is not in the library: it cannot
        // be added to a playlist, and "Go to" only offers what the library also has.
        if track.trackId != nil {
            items.append(.divider)
            if let goToMenu = createGoToMenu(for: track) {
                items.append(goToMenu)
            }
            items.append(.divider)
            items.append(contentsOf: createPlaylistItems(for: track, playlistManager: playlistManager))
        } else if let goToMenu = createLibraryMatchesGoToMenu(for: track, playlistManager: playlistManager) {
            items.append(.divider)
            items.append(goToMenu)
        }

        items.append(.divider)
        items.append(createMoveToTrashItem(for: track, playlistManager: playlistManager))
        return items
    }

    /// The player bar's menu, after Play and Remove from Queue for rows other than the
    /// playing one.
    static func createQueueMenuItems(
        for track: Track,
        at position: Int,
        isCurrentTrack: Bool,
        playlistManager: PlaylistManager
    ) -> [ContextMenuItem] {
        var items: [ContextMenuItem] = []

        if !isCurrentTrack {
            items.append(.button(title: String(localized: "Play"), icon: Icons.playFill) {
                playlistManager.playFromQueue(at: position)
            })
            items.append(.button(title: String(localized: "Remove from Queue"), icon: "minus.circle") {
                playlistManager.removeFromQueue(at: position)
            })
            items.append(.divider)
        }
        return items + createPlayerViewMenuItems(for: track, playlistManager: playlistManager)
    }

    // MARK: - Helper Methods
    
    private static func createPlaybackItems(
        for track: Track,
        playlistManager: PlaylistManager,
        currentContext: MenuContext
    ) -> [ContextMenuItem] {
        var items: [ContextMenuItem] = []
        
        // Play
        items.append(.button(title: String(localized: "Play"), icon: Icons.playFill) {
            switch currentContext {
            case .library:
                playlistManager.playTrack(track, fromTracks: [track])
            case .folder:
                playlistManager.playTrackFromFolder(track, folderTracks: [track])
            case .playlist(let playlist):
                if let index = playlist.tracks.firstIndex(of: track) {
                    playlistManager.playTrackFromPlaylist(playlist, at: index)
                }
            }
        })
        
        // Play Next
        items.append(.button(title: String(localized: "Play Next"), icon: "text.line.first.and.arrowtriangle.forward") {
            playlistManager.playNext(track)
        })
        
        // Add to Queue
        items.append(.button(title: String(localized: "Add to Queue"), icon: "text.append") {
            playlistManager.addToQueue(track)
        })
        
        return items
    }
    
    private static func createBulkPlaybackItems(
        for tracks: [Track],
        playlistManager: PlaylistManager
    ) -> [ContextMenuItem] {
        var items: [ContextMenuItem] = []
        
        // Play
        items.append(.button(title: String(localized: "Play"), icon: Icons.playFill) {
            if let firstTrack = tracks.first {
                playlistManager.playTrack(firstTrack, fromTracks: tracks)
            }
        })
        
        // Play Next
        items.append(.button(title: String(localized: "Play Next"), icon: "text.line.first.and.arrowtriangle.forward") {
            for track in tracks.reversed() {
                playlistManager.playNext(track)
            }
        })
        
        // Add to Queue
        items.append(.button(title: String(localized: "Add to Queue"), icon: "text.append") {
            for track in tracks {
                playlistManager.addToQueue(track)
            }
        })
        
        return items
    }
    
    private static func createShowInfoItem(for track: Track) -> ContextMenuItem {
        .button(title: String(localized: "Show Info"), icon: Icons.infoCircle) {
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowTrackInfo"),
                object: nil,
                userInfo: ["track": track]
            )
        }
    }
    
    private static func createRevealInFinderItem(for track: Track) -> ContextMenuItem {
        .button(title: String(localized: "Reveal in Finder"), icon: "finder") {
            NSWorkspace.shared.selectFile(track.url.path, inFileViewerRootedAtPath: "")
        }
    }
    
    private static func createMoveToTrashItem(for track: Track, playlistManager: PlaylistManager) -> ContextMenuItem {
        .button(title: String(localized: "Move to Trash"), icon: "trash", role: .destructive) {
            // Runs after the menu has closed, so the confirmation is not raised over it.
            Task { @MainActor in
                playlistManager.confirmMoveToTrash(track)
            }
        }
    }
    
    /// - Parameter libraryMatches: set for a track outside the library, such as one opened
    ///   from Finder, to offer only what the library also has. Nil when nothing matches.
    private static func createGoToMenu(for track: Track, libraryMatches: LibraryMatches? = nil) -> ContextMenuItem? {
        var goToItems: [ContextMenuItem] = []
        
        for filterType in LibraryFilterType.allCases {
            // A year or decade says nothing about a file outside the library, and leads to
            // a broad list rather than to the track or its album.
            if libraryMatches != nil, filterType == .decades || filterType == .years { continue }
            if filterType.usesMultiArtistParsing {
                goToItems.append(contentsOf: createMultiValueFilterItems(
                    for: track,
                    filterType: filterType,
                    libraryMatches: libraryMatches
                ))
            } else if let item = createSingleValueFilterItem(
                for: track,
                filterType: filterType,
                libraryMatches: libraryMatches
            ) {
                goToItems.append(item)
            }
        }
        
        guard !goToItems.isEmpty else { return nil }
        return .menu(title: String(localized: "Go to"), items: goToItems)
    }
    
    private static func createMultiValueFilterItems(
        for track: Track,
        filterType: LibraryFilterType,
        libraryMatches: LibraryMatches? = nil
    ) -> [ContextMenuItem] {
        let value = filterType.getValue(from: track)
        var parsedValues = ArtistParser.parse(
            value,
            unknownPlaceholder: filterType.unknownPlaceholder,
            role: filterType.artistRole
        )
        if let libraryMatches {
            parsedValues = parsedValues.compactMap { libraryMatches.libraryValue($0, for: filterType) }
            guard !parsedValues.isEmpty else { return [] }
        }
        
        if parsedValues.count > 1 {
            var subItems: [ContextMenuItem] = []
            for parsedValue in parsedValues {
                subItems.append(.button(title: parsedValue) {
                    postGoToNotification(filterType: filterType, filterValue: parsedValue)
                })
            }
            return [
                .menu(title: filterType.pluralDisplayName, items: subItems)
            ]
        } else {
            let displayValue = parsedValues.first ?? filterType.unknownPlaceholder
            return [
                // swiftlint:disable:next localized_context_menu_title - dynamic filter category and value
                .button(title: "\(filterType.pluralDisplayName): \(filterType.localizedDisplay(displayValue))") {
                    postGoToNotification(filterType: filterType, filterValue: displayValue)
                }
            ]
        }
    }
    
    private static func createSingleValueFilterItem(
        for track: Track,
        filterType: LibraryFilterType,
        libraryMatches: LibraryMatches? = nil
    ) -> ContextMenuItem? {
        let value = filterType.getValue(from: track)
        var displayValue = value.isEmpty ? filterType.unknownPlaceholder : value
        var albumId = filterType == .albums ? track.albumId : nil
        if let libraryMatches {
            if filterType == .albums {
                guard let album = libraryMatches.album(of: track) else {
                    return libraryMatches.sessionAlbum().map {
                        createShowDetailItem(.sessionAlbum($0), title: $0.entity.name)
                    }
                }
                displayValue = album.title
                albumId = album.id
            } else {
                guard let libraryValue = libraryMatches.libraryValue(displayValue, for: filterType) else { return nil }
                displayValue = libraryValue
            }
        }

        // An album opens its page in Home, as Home's album tiles do.
        if let albumId {
            return createShowDetailItem(
                .entity(AlbumEntity(name: displayValue, trackCount: 0, albumId: albumId)),
                title: displayValue
            )
        }
        // swiftlint:disable:next localized_context_menu_title - dynamic filter category and value
        return .button(title: "\(filterType.pluralDisplayName): \(filterType.localizedDisplay(displayValue))") {
            postGoToNotification(filterType: filterType, filterValue: displayValue)
        }
    }
    
    private static func createLibraryMatchesGoToMenu(
        for track: Track,
        playlistManager: PlaylistManager
    ) -> ContextMenuItem? {
        guard let libraryManager = playlistManager.libraryManager else { return nil }
        // Without a library the window shows the welcome screen, not Home's album page.
        let libraryMatches = LibraryMatches(libraryManager: libraryManager) {
            libraryManager.isLocalLibraryReady ? playlistManager.sessionAlbum(for: track) : nil
        }
        return createGoToMenu(for: track, libraryMatches: libraryMatches)
    }

    /// "Albums: <title>", opening `target` in Home's detail page.
    private static func createShowDetailItem(_ target: HomeDetailTarget, title: String) -> ContextMenuItem {
        let filterType = LibraryFilterType.albums
        // swiftlint:disable:next localized_context_menu_title - dynamic filter category and value
        return .button(title: "\(filterType.pluralDisplayName): \(filterType.localizedDisplay(title))") {
            NotificationCenter.default.post(name: .showHomeDetail, object: nil, userInfo: ["target": target])
        }
    }
    
    private static func postGoToNotification(
        filterType: LibraryFilterType,
        filterValue: String,
        albumId: Int64? = nil
    ) {
        var userInfo: [String: Any] = [
            "filterType": filterType,
            "filterValue": filterValue
        ]
        userInfo["albumId"] = albumId

        NotificationCenter.default.post(
            name: .goToLibraryFilter,
            object: nil,
            userInfo: userInfo
        )
    }
    
    private static func createPlaylistItems(
        for track: Track,
        playlistManager: PlaylistManager
    ) -> [ContextMenuItem] {
        var items: [ContextMenuItem] = []
        
        // Cache playlists to avoid repeated access
        let playlists = playlistManager.playlists.filter { $0.type == .regular }
        
        // Create playlist items more efficiently
        var playlistItems: [ContextMenuItem] = []
        
        // Create new playlist item
        playlistItems.append(.button(title: String(localized: "New Playlist...")) {
            playlistManager.showCreatePlaylistModal(with: [track])
        })
        
        // Add to existing playlists - optimize the containment check
        if !playlists.isEmpty {
            playlistItems.append(.divider)
            
            // Pre-compute track ID for efficiency
            let trackId = track.trackId
            
            for playlist in playlists {
                // More efficient containment check
                let isInPlaylist = trackId != nil && playlist.tracks.contains { $0.trackId == trackId }
                let playlistName = DefaultPlaylists.displayName(for: playlist)
                let title = isInPlaylist ? "✓ \(playlistName)" : playlistName
                
                playlistItems.append(.button(title: title) {
                    playlistManager.updateTrackInPlaylist(
                        track: track,
                        playlist: playlist,
                        add: !isInPlaylist
                    )
                })
            }
        }
        
        items.append(.menu(title: String(localized: "Add to Playlist"), icon: "text.badge.plus", items: playlistItems))
        
        items.append(
            .button(
                title: track.isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"),
                icon: track.isFavorite ? Icons.starFill : Icons.star
            ) { playlistManager.toggleFavorite(for: track) }
        )
        
        return items
    }
    
    private static func createBulkPlaylistItems(
        for tracks: [Track],
        playlistManager: PlaylistManager,
        currentContext: MenuContext
    ) -> [ContextMenuItem] {
        var items: [ContextMenuItem] = []
        
        let playlists = playlistManager.playlists.filter { $0.type == .regular }
        var playlistItems: [ContextMenuItem] = []
        
        playlistItems.append(.button(title: String(localized: "New Playlist...")) {
            playlistManager.showCreatePlaylistModal(with: tracks)
        })
        
        if !playlists.isEmpty {
            playlistItems.append(.divider)
            
            for playlist in playlists {
                playlistItems.append(.button(title: DefaultPlaylists.displayName(for: playlist)) {
                    Task {
                        await playlistManager.addTracksToPlaylist(tracks: tracks, playlistID: playlist.id)
                    }
                })
            }
        }
        
        items.append(.menu(title: String(localized: "Add to Playlist"), icon: "text.badge.plus", items: playlistItems))
        
        let allFavorited = tracks.allSatisfy { $0.isFavorite }
        let title = allFavorited ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")
        items.append(.button(title: title, icon: allFavorited ? Icons.starFill : Icons.star) {
            playlistManager.toggleFavorite(for: tracks, setTo: !allFavorited)
        })
        
        if case .playlist(let playlist) = currentContext, playlist.type == .regular {
            items.append(.divider)
            items.append(.button(title: String(localized: "Remove from Playlist"), role: .destructive) {
                Task {
                    await playlistManager.removeTracksFromPlaylist(tracks: tracks, playlistID: playlist.id)
                }
            })
        }
        
        return items
    }

    private static func createContextSpecificItems(
        for track: Track,
        playlistManager: PlaylistManager,
        currentContext: MenuContext
    ) -> [ContextMenuItem] {
        var items: [ContextMenuItem] = []
        
        switch currentContext {
        case .playlist(let playlist):
            if playlist.type == .regular {
                items.append(.divider)
                items.append(.button(title: String(localized: "Remove from Playlist"), role: .destructive) {
                    playlistManager.removeTrackFromPlaylist(
                        track: track,
                        playlistID: playlist.id
                    )
                })
            }
            
        case .library, .folder:
            break
        }
        
        return items
    }
    
    /// What the library holds for a track it doesn't contain, so "Go to" can lead from a
    /// file opened from Finder to the same album or artist in the library, or else to the
    /// album its play queue neighbours make up.
    struct LibraryMatches {
        let libraryManager: LibraryManager
        /// Offered as the album when the library has no album to go to; only gathered then.
        let sessionAlbum: () -> PlaylistManager.SessionAlbum?

        /// The library's spelling of `value`, or nil when no library track has it.
        func libraryValue(_ value: String, for filterType: LibraryFilterType) -> String? {
            guard !value.isEmpty, value != filterType.unknownPlaceholder,
                  let items = libraryManager.cachedLibraryFilterItems(for: filterType) else { return nil }
            return items.first { !$0.isAllItem && $0.name.caseInsensitiveCompare(value) == .orderedSame }?.name
        }

        /// The library album with the track's title by the same album artist; see
        /// `DatabaseManager.libraryAlbum(titled:by:)`.
        func album(of track: Track) -> (id: Int64, title: String)? {
            // The cached titles rule most tracks out without a query.
            guard libraryValue(track.album, for: .albums) != nil else { return nil }
            let artist = track.albumCredit
            let knownArtist = artist.isEmpty || artist == LibraryFilterType.artists.unknownPlaceholder ? nil : artist
            return libraryManager.databaseManager.libraryAlbum(titled: track.album, by: knownArtist)
        }
    }

    enum MenuContext {
        case library
        case folder(Folder)
        case playlist(Playlist)
    }
}

struct ContextMenuItemView: View {
    let item: ContextMenuItem
    
    var body: some View {
        switch item {
        case let .button(_, _, role, action):
            Button(role: role, action: action) {
                HStack {
                    if let icon = item.icon {
                        Image(systemName: icon)
                            .frame(width: 16)
                    }
                    Text(item.title)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            
        case .menu(_, _, let items):
            Menu {
                ForEach(items, id: \.id) { subItem in
                    ContextMenuItemView(item: subItem)
                }
            } label: {
                HStack {
                    if let icon = item.icon {
                        Image(systemName: icon)
                            .frame(width: 16)
                    }
                    Text(item.title)
                    Spacer()
                }
            }
            
        case .divider:
            Divider()
        }
    }
}
