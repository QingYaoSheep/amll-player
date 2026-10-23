#if DEBUG
    import UIKit

    /// Rich content for opt-in screenshots and interaction tests only.
    /// No production account, endpoint, artwork, or playback is replaced.
    @MainActor enum ProductCatalogUITestFixture {
        private static let colors: [UIColor] = [.systemIndigo, .systemOrange, .systemTeal, .systemPink, .systemBlue, .systemPurple]
        private static var covers: [Int: URL] = [:]

        private static func cover(_ index: Int) -> URL? {
            if let cached = covers[index] { return cached }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-design-\(index).png")
            let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { context in
                colors[index % colors.count].setFill()
                context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
                UIColor.white.withAlphaComponent(0.25).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: -128, y: 80, width: 500, height: 500))
                UIColor.black.withAlphaComponent(0.18).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 270, y: -160, width: 420, height: 480))
            }
            guard let data = image.pngData(), (try? data.write(to: url)) != nil else { return nil }
            covers[index] = url
            return url
        }

        static func item(_ id: String, kind: MusicCatalogKind, name: String, index: Int = 0) -> MusicCatalogItem {
            var value = MusicCatalogItem(spotifyID: id, kind: kind, name: name,
                subtitle: kind == .artist ? "Artist" : "Test Artist", artworkURL: cover(index), availability: .available)
            if kind == .track {
                value.track = .init(durationMS: 213000, artists: [.init(id: "artist1", name: "Test Artist")],
                                    album: .init(id: "album1", name: "Test Album 1"), isrc: nil)
            }
            if kind == .album || kind == .track { value.artists = [.init(id: "artist1", name: "Test Artist")] }
            if kind == .album { value.releaseDate = "2026" }
            if kind == .playlist {
                value.playlist = .init(ownerName: "Test Listener",
                    description: "把喜欢的旋律留在这里，从清晨出门的第一首歌，到夜晚回家路上的最后一段和声。听熟悉的声音，也发现下一首值得反复播放的新歌。让不同的节奏，陪伴每一个平凡却珍贵的时刻。", total: 8)
            }
            return value
        }

        static func page(_ query: MusicCatalogQuery) -> MusicPage<MusicCatalogRow> {
            let items: [MusicCatalogItem]
            switch query {
            case .collection(.playlists), .collection(.recommendations), .collection(.charts):
                items = (1...5).map { item("list\($0)", kind: .playlist,
                    name: $0 == 1 ? "Test Playlist" : ["", "", "Late Night", "Open Skies", "On Repeat", "Slow Morning"][$0], index: $0) }
            case .collection(.savedAlbums), .artistAlbums:
                items = (1...6).map { item("album\($0)", kind: .album, name: "Test Album \($0)", index: $0) }
            case .collection(.followedArtists):
                items = [item("artist1", kind: .artist, name: "Test Artist", index: 3)]
            case .playlistItems, .albumTracks:
                items = (0..<8).map { item($0 < 2 ? "repeated" : "song\($0)", kind: .track,
                    name: $0 < 2 ? "Repeated Song" : "Afterglow \($0)", index: $0 % 6) }
            case let .search(term, kind):
                items = [item(term == "Unavailable" ? "unavailable" : "result1", kind: kind, name: term + " Result", index: 2)]
            default:
                items = (0..<6).map { item("song\($0)", kind: .track,
                    name: ["Blue Hour", "Golden", "Afterglow", "Breathe", "Midnight", "Way Home"][$0], index: $0) }
            }
            return .init(items: items.enumerated().map { index, item in
                .init(id: "\(query):\(index):\(item.id)", item: item, position: query.preservesPositions ? index : nil)
            }, next: nil, total: items.count)
        }

        static func detail(kind: MusicCatalogKind, id: String) -> MusicCatalogDetail {
            let name = kind == .artist ? "Test Artist" : kind == .playlist ? "Test Playlist" : kind == .album ? "Test Album 1" : "Blue Hour"
            let children: MusicCatalogQuery? = switch kind {
            case .artist: .artistAlbums(id)
            case .album: .albumTracks(id)
            case .playlist: .playlistItems(id)
            default: nil
            }
            return .init(item: item(id, kind: kind, name: name, index: kind == .artist ? 3 : 1), children: children,
                availability: .available,
                highlights: kind == .artist ? Array(page(.collection(.topTracks)).items.prefix(3)) : [],
                about: kind == .artist ? "用旋律记录生活，在不同风格之间寻找自己的声音。从独立创作到与乐队合作，每一张专辑都是一次新的探索。关于成长、相遇与离别的故事，藏在这些作品的字里行间。" : nil)
        }
    }
#endif
