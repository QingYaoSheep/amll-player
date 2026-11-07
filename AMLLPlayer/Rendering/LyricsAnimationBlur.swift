import Foundation

enum LyricsAnimationBlur {
    static func level(_ saved: Int?, isPad: Bool) -> Int {
        min(10, max(1, saved ?? (isPad ? 3 : 5)))
    }

    static func maximum(_ level: Int) -> Double {
        let level = Double(Self.level(level, isPad: false))
        return level <= 5 ? 1 + (level - 1) * 1.75 : 8 + (level - 5) * 0.8
    }

    static func near(_ maximum: Double) -> Double { min(2, maximum * 0.4) }

    static func radius(distance: Int, compact: Bool, calibrated: Bool, maximum: Double) -> Double {
        guard distance != 0 else { return 0 }
        if calibrated {
            let base = switch distance {
            case ..<0: min(8, 3 + Double(-distance - 1) * 1.25)
            case 1: 1.8
            case 2: 2.7
            default: 4.5 + Double(min(6, distance) - 3) * (3.5 / 3)
            }
            return base * maximum / 8
        }
        let legacy = Double(distance < 0 ? 2 - distance : distance) * (compact ? 0.8 : 1)
        return min(5, legacy) * maximum / 5
    }

    static func weights(radius: Double, maximum: Double?) -> (sharp: Float, near: Float, far: Float) {
        guard let maximum, maximum > 0 else { return (1, 0, 0) }
        let radius = min(maximum, max(0, radius))
        let near = near(maximum)
        if radius <= near {
            let mix = Float(radius / near)
            return (1 - mix, mix, 0)
        }
        let mix = Float((radius - near) / (maximum - near))
        return (0, 1 - mix, mix)
    }
}
