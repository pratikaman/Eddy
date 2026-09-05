import Foundation

/// A slice of the colour wheel. `t` in 0..1 sweeps the slice; Neon is the whole wheel, Mono is white.
enum Palette: String, CaseIterable {
    case neon = "Neon", ember = "Ember", ocean = "Ocean", candy = "Candy", mono = "Mono"

    var range: (base: Float, span: Float, sat: Float) {
        switch self {
        case .neon:  return (0.00, 1.00, 0.85)
        case .ember: return (0.97, 0.15, 0.95)   // red → orange → gold
        case .ocean: return (0.45, 0.25, 0.80)   // teal → blue → indigo
        case .candy: return (0.72, 0.33, 0.65)   // violet → pink → coral
        case .mono:  return (0.00, 0.00, 0.00)
        }
    }

    func color(_ t: Float, _ v: Float = 1) -> SIMD4<Float> {
        let r = range
        let h = (r.base + r.span * (t - floor(t))).truncatingRemainder(dividingBy: 1)
        return hsv(h, r.sat, v)
    }
}

/// How hard the audio pushes the visuals.
enum Intensity: String, CaseIterable {
    case calm = "Calm", normal = "Normal", wild = "Wild"
    var gain: Float {
        switch self { case .calm: return 0.5; case .normal: return 1; case .wild: return 2 }
    }
}

/// The user's choices, persisted in UserDefaults. The menu writes, the renderer reads every frame.
final class Settings {
    static let shared = Settings()

    var palette: Palette { didSet { save("palette", palette.rawValue) } }
    var intensity: Intensity { didSet { save("intensity", intensity.rawValue) } }
    var reactive: Bool { didSet { save("reactive", reactive) } }
    var source: Source { didSet { save("source", source.rawValue) } }

    private init() {
        let d = UserDefaults.standard
        palette = Palette(rawValue: d.string(forKey: "palette") ?? "") ?? .neon
        intensity = Intensity(rawValue: d.string(forKey: "intensity") ?? "") ?? .normal
        reactive = d.object(forKey: "reactive") as? Bool ?? true
        source = Source(rawValue: d.string(forKey: "source") ?? "") ?? .system
    }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }
}
