import Foundation

/// Development-only input contract. Events occur at the beginning of a frame;
/// the declared delta advances animation time and, only while playing, audio time.
struct AMLLReplayScenario: Codable, Equatable, Sendable {
    struct Event: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case play, pause, seek, beginBrowsing, browseBy, endBrowsing, resumeFollowing
        }

        var frame: Int
        var kind: Kind
        var value: Double?
    }

    var schema = 1
    var id: String
    var lyricResource: String
    var initialPosition: Double
    var initiallyPlaying: Bool
    var frameDeltas: [Double]
    var events: [Event]

    static func shared(framesPerSecond: Int = 60) throws -> Self {
        guard [60, 120].contains(framesPerSecond),
              let url = Bundle.main.url(forResource: "amll-shared-replay", withExtension: "json")
        else { throw CocoaError(.fileReadCorruptFile) }
        var result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try result.validate()
        if framesPerSecond == 120 {
            result.frameDeltas = result.frameDeltas.flatMap { [$0 / 2, $0 / 2] }
            result.events = result.events.map { event in
                var event = event; event.frame *= 2; return event
            }
        }
        return result
    }

    func validate() throws {
        guard schema == 1, initialPosition.isFinite, initialPosition >= 0,
              !frameDeltas.isEmpty, frameDeltas.allSatisfy({ $0.isFinite && $0 >= 0 }),
              events.allSatisfy({ $0.frame >= 0 && $0.frame < frameDeltas.count && ($0.value?.isFinite ?? true) }),
              zip(events, events.dropFirst()).allSatisfy({ $0.frame <= $1.frame }),
              events.allSatisfy({ ![Event.Kind.seek, .browseBy, .endBrowsing].contains($0.kind) || $0.value != nil }),
              events.allSatisfy({ $0.kind != .seek || ($0.value ?? -1) >= 0 })
        else { throw CocoaError(.fileReadCorruptFile) }
    }
}

struct AMLLReplayCursor {
    private(set) var frame = 0
    private(set) var input: AMLLPlayerInput
    private let scenario: AMLLReplayScenario

    init(_ scenario: AMLLReplayScenario) throws {
        try scenario.validate()
        self.scenario = scenario
        input = .init(position: scenario.initialPosition, playing: scenario.initiallyPlaying)
    }

    mutating func next() -> (input: AMLLPlayerInput, delta: Double, interactions: [AMLLInteraction])? {
        guard frame < scenario.frameDeltas.count else { return nil }
        var interactions: [AMLLInteraction] = []
        input.seeking = false
        for event in scenario.events where event.frame == frame {
            switch event.kind {
            case .play: input.playing = true
            case .pause: input.playing = false
            case .seek:
                input.position = event.value!; input.seekRevision += 1; input.seeking = true
            case .beginBrowsing: interactions.append(.beginBrowsing)
            case .browseBy: interactions.append(.browseBy(event.value!))
            case .endBrowsing: interactions.append(.endBrowsing(velocity: event.value!))
            case .resumeFollowing: interactions.append(.resumeFollowing)
            }
        }
        let delta = scenario.frameDeltas[frame]
        if input.playing {
            input.position += delta
        }
        frame += 1
        return (input, delta, interactions)
    }
}
