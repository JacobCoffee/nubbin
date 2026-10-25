import SwiftUI

/// One ring of the notch: the visible counterpart of a chime, driven by the chime's own loudness.
struct RingPulse: Equatable, Identifiable {
    let id = UUID()
    let moment: Moment
    /// Loudness at `SoundAnalysis.envelopeRate`; empty for silent moments (a short synthetic swell is used).
    let envelope: [Float]
    let start = Date()

    static let travel: TimeInterval = 1.5

    var soundLength: TimeInterval { Double(envelope.count) / SoundAnalysis.envelopeRate }
    var lifetime: TimeInterval { max(soundLength, 0.35) + Self.travel }

    func level(at t: TimeInterval) -> Double {
        guard t >= 0 else { return 0 }
        if envelope.isEmpty { return exp(-t * 5) }
        let index = Int(t * SoundAnalysis.envelopeRate)
        return index < envelope.count ? Double(envelope[index]) : 0
    }

    /// The loudest the sound has been so far: rings that have left the notch keep the energy they had.
    func peak(until t: TimeInterval) -> Double {
        guard !envelope.isEmpty else { return 1 }
        let index = min(envelope.count, max(1, Int(t * SoundAnalysis.envelopeRate)))
        return Double(envelope[..<index].max() ?? 0)
    }
}

/// Rings of light spreading from the notch across the menu bar, plus the island's own wobble.
struct RingLayer: View {
    let pulse: RingPulse
    let islandSize: CGSize
    /// Rings start at the notch and stay near the menu bar, whatever size the island is.
    let notchHeight: CGFloat
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(pulse.start)
            Canvas { canvas, size in
                let color = Preferences.shared.style(pulse.moment).color.color
                // A second, quieter ring follows the first like an echo.
                for (delay, strength) in [(0.0, 1.0), (0.2, 0.55)] {
                    let local = t - delay
                    guard local > 0, local < RingPulse.travel else { continue }
                    drawRing(in: &canvas, size: size, progress: local / RingPulse.travel,
                             energy: strength * (0.45 + 0.55 * pulse.peak(until: t)), color: color)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawRing(in canvas: inout GraphicsContext, size: CGSize, progress: Double,
                          energy: Double, color: Color) {
        let eased = reduceMotion ? 0.35 : 1 - pow(1 - progress, 3)
        let fromX = islandSize.width / 2, toX = size.width * 0.58
        let fromY = notchHeight * 1.2, toY = notchHeight * 1.2 + 96
        let rx = fromX + (toX - fromX) * eased
        let ry = fromY + (toY - fromY) * eased
        let rect = CGRect(x: size.width / 2 - rx, y: -ry, width: rx * 2, height: ry * 2)
        let fade = pow(1 - progress, 1.6) * energy
        let path = Path(ellipseIn: rect)

        var glow = canvas
        glow.addFilter(.blur(radius: 7))
        glow.stroke(path, with: .color(color.opacity(0.75 * fade)), lineWidth: 6)
        canvas.stroke(path, with: .color(color.opacity(0.95 * fade)), lineWidth: 1.4)
    }
}

/// Scales the island with the sound: a swell on loud parts and a quick damped wobble, like a struck bell.
struct RingWobble: ViewModifier {
    let pulse: RingPulse?
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if let pulse, !reduceMotion {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSince(pulse.start)
                let level = pulse.level(at: t)
                let strike = sin(t * 2 * .pi * 5.5) * exp(-t * 3.2)
                content
                    .scaleEffect(x: 1 + 0.035 * level + 0.018 * strike,
                                 y: 1 + 0.07 * level - 0.02 * strike,
                                 anchor: .top)
            }
        } else {
            content
        }
    }
}
