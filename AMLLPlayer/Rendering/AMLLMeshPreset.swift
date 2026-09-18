import Foundation

/// Native port of core 0.5.2 mesh-renderer/cp-generate.ts.
/// Source attribution is recorded in Docs/Plan5-AMLL-Port.md.
struct AMLLMeshPreset: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        var cx: Int
        var cy: Int
        var x: Double
        var y: Double
        var ur: Double
        var vr: Double
        var up: Double
        var vp: Double
    }

    var width: Int
    var height: Int
    var conf: [Point]

    static func loadPresets(bundle: Bundle = .main) throws -> [Self] {
        guard let url = bundle.url(forResource: "amll-mesh-presets", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
    }

    /// A fixed stream also used by the original TypeScript fixture exporter.
    struct Random: Sendable {
        var state: UInt32

        mutating func next() -> Double {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return Double(state) / 4_294_967_296
        }

        mutating func range(_ lower: Double, _ upper: Double) -> Double {
            next() * (upper - lower) + lower
        }
    }

    static func generate(width: Int = 6, height: Int = 6, random: inout Random) -> Self {
        precondition(width >= 2 && height >= 2)
        let variation = random.range(0.4, 0.6)
        let normalOffset = random.range(0.3, 0.6)
        let iterations = Int(floor(random.range(3, 5)))
        var factor = random.range(0.2, 0.3)
        let modifier = random.range(-0.1, -0.05)
        let dx = 2 / Double(width - 1)
        let dy = 2 / Double(height - 1)
        var points: [Point] = []
        for j in 0 ..< height {
            for i in 0 ..< width {
                let baseX = Double(i) / Double(width - 1) * 2 - 1
                let baseY = Double(j) / Double(height - 1) * 2 - 1
                let border = i == 0 || i == width - 1 || j == 0 || j == height - 1
                var x = baseX + (border ? 0 : random.range(-variation * dx, variation * dx))
                var y = baseY + (border ? 0 : random.range(-variation * dy, variation * dy))
                let ur = border ? 0 : random.range(-60, 60)
                let vr = border ? 0 : random.range(-60, 60)
                let up = border ? 1 : random.range(0.8, 1.2)
                let vp = border ? 1 : random.range(0.8, 1.2)
                if !border {
                    let u = (baseX + 1) / 2
                    let v = (baseY + 1) / 2
                    let gx = (smoothNoise(u + 0.001, v) - smoothNoise(u - 0.001, v)) / 0.002
                    let gy = (smoothNoise(u, v + 0.001) - smoothNoise(u, v - 0.001)) / 0.002
                    let magnitude = sqrt(gx * gx + gy * gy)
                    let length = magnitude == 0 ? 1 : magnitude
                    let distance = min(u, 1 - u, v, 1 - v)
                    let weight = distance * distance * (3 - 2 * distance)
                    let ox = gx / length * normalOffset * weight
                    let oy = gy / length * normalOffset * weight
                    x = x * (1 - 0.8) + (x + ox) * 0.8
                    y = y * (1 - 0.8) + (y + oy) * 0.8
                }
                points.append(Point(cx: i, cy: j, x: x, y: y, ur: ur, vr: vr, up: up, vp: vp))
            }
        }
        let fields: [WritableKeyPath<Point, Double>] = [\.x, \.y, \.ur, \.vr, \.up, \.vp]
        let kernel = [[1.0, 2, 1], [2, 4, 2], [1, 2, 1]]
        for _ in 0 ..< iterations {
            var next = points
            for j in 1 ..< height - 1 {
                for i in 1 ..< width - 1 {
                    let index = j * width + i
                    for field in fields {
                        var sum = 0.0
                        for dj in -1 ... 1 {
                            for di in -1 ... 1 {
                                sum += points[(j + dj) * width + i + di][keyPath: field] * kernel[dj + 1][di + 1]
                            }
                        }
                        next[index][keyPath: field] = points[index][keyPath: field] * (1 - factor) + sum / 16 * factor
                    }
                }
            }
            points = next
            factor = min(1, max(0, factor + modifier))
        }
        return Self(width: width, height: height, conf: points)
    }

    private static func noise(_ x: Double, _ y: Double) -> Double {
        let value = sin(x * 12.9898 + y * 78.233) * 43758.5453
        return value - floor(value)
    }

    private static func smoothNoise(_ x: Double, _ y: Double) -> Double {
        let x0 = floor(x)
        let y0 = floor(y)
        let xf = x - x0
        let yf = y - y0
        let u = xf * xf * (3 - 2 * xf)
        let v = yf * yf * (3 - 2 * yf)
        let n0 = noise(x0, y0) * (1 - u) + noise(x0 + 1, y0) * u
        let n1 = noise(x0, y0 + 1) * (1 - u) + noise(x0 + 1, y0 + 1) * u
        return n0 * (1 - v) + n1 * v
    }
}
