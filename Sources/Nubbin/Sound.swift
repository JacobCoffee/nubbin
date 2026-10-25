import AVFoundation
import Observation

enum SoundLibrary {
    private static let extensions: Set<String> = ["aiff", "aif", "wav", "caf", "mp3", "m4a"]

    /// macOS alert sounds plus anything in ~/Library/Sounds, by name.
    static let systemSounds: [String] = {
        let dirs = [URL(fileURLWithPath: "/System/Library/Sounds"),
                    FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Sounds")]
        let names = dirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { extensions.contains($0.pathExtension.lowercased()) }
                .map { $0.deletingPathExtension().lastPathComponent }
        }
        return Array(Set(names)).sorted()
    }()

    static func customSounds() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: Paths.soundsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .map(\.lastPathComponent)
            .sorted()
    }

    static func url(_ choice: SoundChoice) -> URL? {
        switch choice {
        case .none:
            return nil
        case .system(let name):
            let dirs = ["/System/Library/Sounds", NSHomeDirectory() + "/Library/Sounds"]
            for dir in dirs {
                for ext in extensions {
                    let url = URL(fileURLWithPath: "\(dir)/\(name).\(ext)")
                    if FileManager.default.fileExists(atPath: url.path) { return url }
                }
            }
            return nil
        case .custom(let file):
            let url = Paths.soundsDir.appending(path: file)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Copy a dropped or chosen file into the app's sound folder. Returns the stored file name.
    static func importSound(from source: URL) throws -> String {
        guard extensions.contains(source.pathExtension.lowercased()) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        _ = try AVAudioFile(forReading: source) // reject files AVFoundation can't decode
        try FileManager.default.createDirectory(at: Paths.soundsDir, withIntermediateDirectories: true)
        var destination = Paths.soundsDir.appending(path: source.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let stem = source.deletingPathExtension().lastPathComponent
            destination = Paths.soundsDir.appending(path: "\(stem) \(counter).\(source.pathExtension)")
            counter += 1
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination.lastPathComponent
    }
}

/// Loudness data for drawing waveforms and driving the notch ring in time with a chime.
struct SoundAnalysis: Sendable {
    static let envelopeRate: Double = 60

    let duration: TimeInterval
    /// Peak amplitude per bar, 0...1, for the waveform editor.
    let peaks: [Float]
    /// RMS loudness at `envelopeRate` per second over the whole file, normalised so the loudest point is 1.
    let envelope: [Float]

    /// The envelope of just the trimmed part, which is what plays.
    func envelope(trimStart: Double, trimEnd: Double) -> [Float] {
        guard !envelope.isEmpty else { return [] }
        let lower = max(0, min(envelope.count - 1, Int(Double(envelope.count) * trimStart)))
        let upper = max(lower + 1, min(envelope.count, Int(Double(envelope.count) * trimEnd)))
        return Array(envelope[lower..<upper])
    }

    @MainActor private static var cache: [URL: SoundAnalysis] = [:]

    @MainActor static func of(_ url: URL) -> SoundAnalysis? {
        if let cached = cache[url] { return cached }
        guard let analysis = analyze(url) else { return nil }
        cache[url] = analysis
        return analysis
    }

    private static func analyze(_ url: URL, bars: Int = 160) -> SoundAnalysis? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData
        else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0 else { return nil }

        func sample(_ i: Int) -> Float {
            var sum: Float = 0
            for c in 0..<channelCount { sum += channels[c][i] }
            return sum / Float(channelCount)
        }

        var peaks = [Float](repeating: 0, count: bars)
        for bar in 0..<bars {
            let start = bar * frames / bars, end = max(start + 1, (bar + 1) * frames / bars)
            var peak: Float = 0
            for i in start..<min(end, frames) { peak = max(peak, abs(sample(i))) }
            peaks[bar] = peak
        }
        let peakMax = max(peaks.max() ?? 1, 0.0001)
        peaks = peaks.map { $0 / peakMax }

        let window = max(1, Int(file.processingFormat.sampleRate / envelopeRate))
        var envelope: [Float] = []
        envelope.reserveCapacity(frames / window + 1)
        var i = 0
        while i < frames {
            let end = min(frames, i + window)
            var sum: Float = 0
            for j in i..<end { let s = sample(j); sum += s * s }
            envelope.append((sum / Float(end - i)).squareRoot())
            i = end
        }
        let envMax = max(envelope.max() ?? 1, 0.0001)
        // Square root of the normalised RMS reads closer to how loud it sounds.
        envelope = envelope.map { ($0 / envMax).squareRoot() }

        return SoundAnalysis(duration: Double(frames) / file.processingFormat.sampleRate,
                             peaks: peaks, envelope: envelope)
    }
}

/// Plays chimes with trim and volume, auditions them in Settings, and plays a quiet music bed
/// so you can judge a chime the way you'll actually hear it.
@MainActor
@Observable
final class SoundEngine {
    static let shared = SoundEngine()

    /// Which moment is auditioning in Settings, and how far through its file the playhead is (0...1).
    private(set) var auditioning: Moment?
    private(set) var playhead: Double?
    private(set) var musicPlaying = false

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let synth = PadSynth()
    @ObservationIgnored private lazy var music = AVAudioSourceNode { [synth] _, _, frameCount, buffers in
        synth.render(frameCount: frameCount, into: UnsafeMutableAudioBufferListPointer(buffers))
        return noErr
    }
    @ObservationIgnored private var connectedFormat: AVAudioFormat?
    @ObservationIgnored private var playheadTimer: Timer?
    @ObservationIgnored private var idleStop: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    private init() {
        engine.attach(player)
        engine.attach(music)
        let musicFormat = AVAudioFormat(standardFormatWithSampleRate: PadSynth.sampleRate, channels: 2)
        engine.connect(music, to: engine.mainMixerNode, format: musicFormat)
        music.volume = 0
    }

    /// Play a moment's chime as configured. Returns the loudness envelope of what plays (also when muted,
    /// so the ring still moves in time with the sound you'd have heard).
    @discardableResult
    func play(_ moment: Moment, ignoringMute: Bool = false) -> [Float] {
        let style = Preferences.shared.style(moment)
        guard let url = SoundLibrary.url(style.sound), let analysis = SoundAnalysis.of(url) else { return [] }
        let envelope = analysis.envelope(trimStart: style.trimStart, trimEnd: style.trimEnd)
        guard ignoringMute || !Preferences.shared.muted else { return envelope }
        schedule(url: url, from: style.trimStart, to: style.trimEnd, volume: style.volume, moment: nil)
        return envelope
    }

    /// Settings: play the trimmed sound, or from `fraction` of the file when you click the waveform.
    func audition(_ moment: Moment, from fraction: Double? = nil) {
        let style = Preferences.shared.style(moment)
        guard let url = SoundLibrary.url(style.sound) else { return }
        let start = fraction.map { min(max($0, 0), 0.99) } ?? style.trimStart
        let end = start < style.trimEnd ? style.trimEnd : 1
        schedule(url: url, from: start, to: end, volume: style.volume, moment: moment)
    }

    /// A soft four-chord pad at a typical listening level, with the chime landing over it.
    func auditionOverMusic(_ moment: Moment) {
        stopMusic()
        generation += 1
        let current = generation
        startEngine()
        synth.start()
        music.volume = 1
        musicPlaying = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard current == generation else { return }
            audition(moment)
            try? await Task.sleep(for: .seconds(PadSynth.length - 1.4))
            guard current == generation else { return }
            stopMusic()
        }
    }

    func stop() {
        generation += 1
        player.stop()
        stopMusic()
        endAudition()
    }

    private func stopMusic() {
        synth.stop()
        music.volume = 0
        musicPlaying = false
        scheduleIdleStop()
    }

    private func schedule(url: URL, from start: Double, to end: Double, volume: Double, moment: Moment?) {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        generation += 1
        let current = generation
        if connectedFormat != file.processingFormat {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            connectedFormat = file.processingFormat
        }
        startEngine()
        player.stop()

        let length = Double(file.length)
        let first = AVAudioFramePosition(length * start)
        let count = AVAudioFrameCount(max(1, length * (end - start)))
        player.volume = Float(volume)
        player.scheduleSegment(file, startingFrame: first, frameCount: count, at: nil) { [weak self] in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                self.endAudition()
                self.scheduleIdleStop()
            }
        }
        player.play()

        playheadTimer?.invalidate()
        if let moment {
            auditioning = moment
            playhead = start
            let rate = file.processingFormat.sampleRate
            playheadTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let nodeTime = self.player.lastRenderTime,
                          let time = self.player.playerTime(forNodeTime: nodeTime) else { return }
                    let played = Double(time.sampleTime) / rate
                    self.playhead = min(end, start + played * rate / length)
                }
            }
        } else {
            endAudition()
        }
    }

    private func endAudition() {
        playheadTimer?.invalidate()
        playheadTimer = nil
        auditioning = nil
        playhead = nil
    }

    private func startEngine() {
        idleStop?.cancel()
        if !engine.isRunning { try? engine.start() }
    }

    /// Release the audio device when nothing has played for a few seconds.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, !self.player.isPlaying, !self.musicPlaying else { return }
            self.engine.stop()
        }
    }
}

/// A slow Cmaj7 - Am7 - Fmaj7 - G pad: sine partials with soft attack, standing in for music
/// playing in the background. Rendered on the audio thread; `start`/`stop` only flip flags.
final class PadSynth: @unchecked Sendable {
    static let sampleRate: Double = 48_000
    static let length: Double = 6

    private static let chords: [[Double]] = [
        [261.63, 329.63, 392.00, 493.88],
        [220.00, 261.63, 329.63, 392.00],
        [174.61, 220.00, 261.63, 329.63],
        [196.00, 246.94, 293.66, 392.00],
    ]

    private var frame: Int = 0
    private var running = false
    private var phases = [Double](repeating: 0, count: 8)

    func start() { frame = 0; running = true }
    func stop() { running = false }

    func render(frameCount: AVAudioFrameCount, into buffers: UnsafeMutableAudioBufferListPointer) {
        let total = Int(Self.length * Self.sampleRate)
        let chordFrames = total / Self.chords.count
        for i in 0..<Int(frameCount) {
            var value = 0.0
            if running && frame < total {
                let t = Double(frame) / Self.sampleRate
                let chord = Self.chords[min(frame / chordFrames, Self.chords.count - 1)]
                // Fade in, fade out, and a gentle swell on each chord change.
                let fade = min(1, t / 0.6) * min(1, (Self.length - t) / 0.8)
                let local = Double(frame % chordFrames) / Self.sampleRate
                let swell = 0.75 + 0.25 * min(1, local / 0.25)
                for (n, freq) in chord.enumerated() {
                    phases[n] += 2 * .pi * freq / Self.sampleRate
                    phases[n + 4] += 2 * .pi * freq * 2.001 / Self.sampleRate
                    value += sin(phases[n]) + 0.25 * sin(phases[n + 4])
                }
                value *= 0.045 * fade * swell
                frame += 1
            }
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[i] = Float(value)
            }
        }
        for n in phases.indices where phases[n] > 2 * .pi * 1000 { phases[n] = phases[n].truncatingRemainder(dividingBy: 2 * .pi) }
    }
}
