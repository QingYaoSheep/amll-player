#if DEBUG
    import AVFoundation
    import Foundation

    /// Explicit opt-in, in-memory fixtures. Release builds have no mock account or launch bypass.
    @MainActor
    enum CatalogUITestFixture {
        static func makeModel(includeLyrics: Bool = false) -> AppModel {
            let arguments = ProcessInfo.processInfo.arguments
            let defaultsName: String
            if let index = arguments.firstIndex(of: "--quick-settings-preferences-suite"), index + 1 < arguments.count,
               arguments[index + 1].hasPrefix("quick-settings-ui-") {
                defaultsName = arguments[index + 1]
            } else { defaultsName = "render-ui-" + UUID().uuidString }
            let preferences = LyricsRenderPreferences(defaults: UserDefaults(suiteName: defaultsName)!)
            if arguments.contains("--lyrics-custom-profile-ui-testing") { preferences.activate(.custom) }
            let service: MusicServiceID
            if let index = arguments.firstIndex(of: "--quick-settings-service"), index + 1 < arguments.count {
                service = MusicServiceID(rawValue: arguments[index + 1]) ?? .spotify
            } else { service = .spotify }
            let defaults = UserDefaults(suiteName: defaultsName)!
            let sources = MusicSourcePreferences(defaults: defaults); sources.selected = service
            let lyrics = LyricsCoordinator(providers: includeLyrics ? [LyricsFixtureProvider()] : [], cache: MemoryLyricsCache(),
                                           settingsStore: LyricsSettingsStore(defaults: UserDefaults(suiteName: "lyrics-ui-" + UUID().uuidString)!))
            let session = NetEaseSession(api: NetEaseFixtureAPI(), store: FixtureStore())
            let nativePlayback: NetEasePlayback?
            if service == .netease, let audio = try? makeSilentAudio() {
                nativePlayback = NetEasePlayback(session: session, catalog: NetEaseCatalog(session: session), defaults: defaults,
                                                makeItem: { _ in NetEasePlayback.makeAudioItem(audio) })
            } else { nativePlayback = nil }
            let model = AppModel(environment: AppEnvironment(
                configuration: .preview, diagnostics: DiagnosticsStore(),
                spotifySession: Session(), spotifyPlayback: Playback(includeLyrics: includeLyrics)
            ), catalogProvider: Provider(), lyrics: lyrics,
            renderPreferences: preferences, appleSession: AppleSession(),
            applePlayback: Playback(includeLyrics: includeLyrics, service: .appleMusic), appleCatalog: Provider(),
            netEaseSession: session, netEasePlayback: nativePlayback, musicPreferences: sources)
            if service == .netease {
                Task {
                    try? await session.importCookie("MUSIC_U=fixture-only")
                    for _ in 0 ..< 200 {
                        if model.netEaseState.connected { break }
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    if let song = NetEaseDecoder.item(NetEaseFixtureAPI.song, kind: .track) { await model.playCatalog(song) }
                }
            }
            return model
        }

        // Generated only for opt-in UI tests; never bundled, streamed or fetched from a service.
        private static func makeSilentAudio() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("quick-settings-" + UUID().uuidString + ".caf")
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
            buffer.frameLength = 8000
            buffer.floatChannelData![0].initialize(repeating: 0, count: 8000)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0 ..< 120 { try file.write(from: buffer) }
            return url
        }

        private final class AppleSession: MusicSessionProviding {
            var currentState = MusicConnectionState(connected: true, authorization: .authorized, storefront: "us",
                                                    capabilities: .init(canBrowse: true, canPlayCatalog: true, usesSystemRoutes: true))
            var connectionStates: AsyncStream<MusicConnectionState> { AsyncStream { $0.yield(currentState); $0.finish() } }
            func connect() async {}
            func refresh() async {}
            func disconnect() { currentState.connected = false }
        }

        private final class FixtureStore: SpotifySessionDataStoring, @unchecked Sendable {
            func load() throws -> Data? { nil }
            func save(_: Data) throws {}
            func remove() throws {}
        }

        private final class NetEaseFixtureAPI: NetEaseRequesting {
            static let song: [String: Any] = ["id": 42, "name": "Fixture Song", "dt": 120000, "ar": [["id": 1, "name": "Fixture Artist"]]]
            func send(_ path: String, _: [String: Any], cookie _: String?) async throws -> NetEaseResponse {
                if path == "/w/nuser/account/get" { return .init(object: ["profile": ["userId": 1, "nickname": "Fixture"]]) }
                if path == "/v3/song/detail" { return .init(object: ["songs": [Self.song]]) }
                if path == "/song/enhance/player/url/v1" {
                    return .init(object: ["data": [["id": 42, "code": 200, "url": "https://fixture.music.126.net/audio.caf", "level": "exhigh"]]])
                }
                return .init(object: ["code": 200])
            }
        }

        private static func item(_ id: String, kind: SpotifyCatalogKind = .track, name: String = "Test Song") -> SpotifyCatalogItem {
            SpotifyCatalogItem(spotifyID: id, kind: kind, name: name, subtitle: "Test Artist", artworkURL: nil, availability: .available)
        }

        private final class Provider: SpotifyCatalogProviding {
            func invalidate() {}
            func profile() async throws -> SpotifyProfile {
                SpotifyProfile(accountID: "fixture", displayName: "Test Listener")
            }

            func page(_ query: SpotifyCatalogQuery, next _: URL?) async throws -> SpotifyPage<SpotifyCatalogRow> {
                let value: SpotifyCatalogItem = switch query {
                case .collection(.playlists): CatalogUITestFixture.item("list1", kind: .playlist, name: "Test Playlist")
                case .collection(.savedAlbums), .artistAlbums: CatalogUITestFixture.item("album1", kind: .album, name: "Test Album")
                case .collection(.followedArtists): CatalogUITestFixture.item("artist1", kind: .artist, name: "Test Artist")
                case let .search(term, kind): CatalogUITestFixture.item("result1", kind: kind, name: term + " Result")
                default: CatalogUITestFixture.item("track1")
                }
                return SpotifyPage(items: [SpotifyCatalogRow(id: value.id, item: value, position: query.preservesPositions ? 0 : nil)], next: nil, total: 1)
            }

            func detail(kind: SpotifyCatalogKind, id: String) async throws -> SpotifyCatalogDetail {
                let name = kind == .playlist ? "Test Playlist" : kind == .album ? "Test Album" : kind == .artist ? "Test Artist" : "Test Song"
                let children: SpotifyCatalogQuery? = switch kind {
                case .track, .playlist, .station, .musicVideo: nil
                case .album: .albumTracks(id)
                case .artist: .artistAlbums(id)
                }
                return SpotifyCatalogDetail(item: CatalogUITestFixture.item(id, kind: kind, name: name), children: children,
                                            availability: kind == .playlist ? .metadataOnly : .available)
            }
        }

        private final class Session: SpotifySessionProviding {
            var currentState: SpotifySessionState = .authenticated(expiresAt: .distantFuture)
            var sessionStates: AsyncStream<SpotifySessionState> {
                AsyncStream { $0.yield(currentState); $0.finish() }
            }

            var spotifyAppInstalled: Bool {
                false
            }

            func authorize() throws {}
            func authorizeInBrowser() async throws {}
            func refreshIfNeeded() async throws {}
            func validAccessToken() async throws -> String {
                throw SpotifyServiceError.notAuthorized
            }

            func handleRedirectURL(_: URL) -> Bool {
                false
            }

            func logout() {
                currentState = .signedOut
            }
        }

        private final class Playback: SpotifyPlaybackProviding {
            let includeLyrics: Bool
            let service: MusicServiceID
            var shuffle = false
            var repeatMode: MusicRepeatMode = .off
            let playbackSnapshots: AsyncStream<PlaybackSnapshot>
            private let continuation: AsyncStream<PlaybackSnapshot>.Continuation
            init(includeLyrics: Bool, service: MusicServiceID = .spotify) {
                self.includeLyrics = includeLyrics
                self.service = service
                let stream = AsyncStream<PlaybackSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
                playbackSnapshots = stream.stream; continuation = stream.continuation
            }
            deinit { continuation.finish() }

            var appRemoteState: SpotifyAppRemoteState {
                .disconnected
            }

            private func publish() {
                if includeLyrics {
                    let item = PlaybackItem(id: "fixture", uri: service == .spotify ? "spotify:track:fixture" : "applemusic:catalog:track:fixture",
                                            title: "Fixture Song", artists: ["Fixture Artist"], albumTitle: nil, artworkURL: nil,
                                            duration: 10, isEpisode: false, isAdvertisement: false, isrc: "FIXTURE", service: service)
                    var snapshot = PlaybackSnapshot(item: item, isPlaying: false, position: 1, duration: 10, device: nil,
                                                    restrictions: .unrestricted, source: service == .spotify ? .webAPI : .musicKit,
                                                    sampledAtUptime: ProcessInfo.processInfo.systemUptime)
                    snapshot.shuffleEnabled = shuffle; snapshot.repeatMode = repeatMode
                    continuation.yield(snapshot)
                }
            }

            func start() { publish() }
            func stop() {}
            func enterForeground() {}
            func enterBackground() {}
            func refresh() async throws {}
            func play() async throws {}
            func pause() async throws {}
            func seek(to _: TimeInterval) async throws {}
            func skipNext() async throws {}
            func skipPrevious() async throws {}
            func setVolume(percent _: Int, on _: String?) async throws {}
            func play(uri _: String, on _: String?) async throws {}
            func play(contextURI _: String, position _: Int, on _: String?) async throws {}
            func devices() async throws -> [PlaybackDevice] {
                []
            }

            func transferPlayback(to _: String) async throws {}
            func setShuffle(_ enabled: Bool) async throws { shuffle = enabled; publish() }
            func setRepeat(_ mode: MusicRepeatMode) async throws { repeatMode = mode; publish() }
        }

        private final class LyricsFixtureProvider: LyricsProvider {
            let source = LyricsSource.qq
            func search(track _: TrackIdentity, query: String, settings _: LyricsSettings) async throws -> [LyricCandidate] {
                [LyricCandidate(source: .qq, sourceID: query.isEmpty ? "auto" : "manual", title: query.isEmpty ? "Fixture Song" : "Correction Candidate", artists: ["Fixture Artist"], score: 99)]
            }

            func lyrics(candidate: LyricCandidate, settings _: LyricsSettings) async throws -> LyricsAssetBundle {
                LyricsAssetBundle(format: .lrc, original: candidate.sourceID == "manual" ? "[00:01]Corrected fixture line" : "[00:01]Original fixture line")
            }
        }
    }
#endif
