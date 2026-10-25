import SwiftUI

/// Colors tuned for small text and dots on pure black. The three moment colors come from Settings.
@MainActor
enum Palette {
    static var amber: Color { Preferences.shared.color(.needsYou) }
    static var red: Color { Preferences.shared.color(.error) }
    static var green: Color { Preferences.shared.color(.done) }
    static let primary = Color.white.opacity(0.94)
    /// 0.56 on black is about 6:1, enough for 11pt metadata.
    static let secondary = Color.white.opacity(0.56)
    static let hairline = Color.white.opacity(0.12)

    static func tint(_ activity: Activity) -> Color { Preferences.shared.color(activity) }
}

struct NotchView: View {
    let store: Store
    let ui: NotchUI
    let actions: NotchActions

    @Namespace private var dots
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = store.rows
        let g = ui.geometry
        let size = ui.islandSize
        let shoulder = ui.resting ? 0 : Layout.shoulder
        let radius = ui.expanded ? Layout.expandedRadius : Layout.foldedRadius
        let shape = IslandShape(shoulder: shoulder, radius: radius)

        ZStack(alignment: .top) {
            if let pulse = ui.ring {
                RingLayer(pulse: pulse, islandSize: size, notchHeight: g.notchHeight, reduceMotion: reduceMotion)
                    .task(id: pulse.id) {
                        try? await Task.sleep(for: .seconds(pulse.lifetime))
                        if ui.ring?.id == pulse.id { ui.ring = nil }
                    }
            }
            shape
                .fill(.black)
                .frame(width: size.width + 2 * shoulder, height: size.height)
                .overlay(alignment: .top) {
                    VStack(spacing: 0) {
                        header(rows: rows)
                            .frame(width: size.width, height: g.notchHeight)
                        list(rows: rows)
                    }
                    .frame(width: Layout.expandedWidth)
                }
                .clipShape(shape)
                .modifier(RingWobble(pulse: ui.ring, reduceMotion: reduceMotion))
                // On an external display there is no hardware notch to hide behind.
                .opacity(ui.resting && !g.hasNotch && ui.ring == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(morph, value: size)
        .animation(morph, value: ui.expanded)
        .environment(\.colorScheme, .dark)
    }

    /// Opening settles with a slight overshoot; folding is quicker and critically damped.
    private var morph: Animation {
        if reduceMotion { return .easeOut(duration: 0.18) }
        return ui.expanded
            ? .spring(response: 0.42, dampingFraction: 0.78)
            : .spring(response: 0.3, dampingFraction: 1)
    }

    // MARK: header

    @ViewBuilder
    private func header(rows: [Row]) -> some View {
        HStack(spacing: 0) {
            if ui.expanded {
                Text(summary(rows))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                    .padding(.leading, 18)
                    .transition(.opacity)
                Spacer(minLength: ui.geometry.notchWidth)
                let muted = Preferences.shared.muted
                HStack(spacing: 2) {
                    headerButton(muted ? "bell.slash.fill" : "bell.fill",
                                 label: muted ? "Unmute chimes" : "Mute chimes",
                                 dimmed: muted, action: actions.toggleMute)
                    headerButton("gearshape.fill", label: "Nubbin Settings", dimmed: true,
                                 action: actions.openSettings)
                }
                .padding(.trailing, 10)
                .transition(.opacity)
            } else if !ui.constellation.isEmpty {
                Constellation(rows: ui.constellation, namespace: dots, reduceMotion: reduceMotion)
                    .frame(width: Layout.wing)
                Spacer(minLength: 0)
                Tally(rows: ui.constellation)
                    .frame(width: Layout.wing)
            }
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.toggle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nubbin: \(summary(rows))")
    }

    private func headerButton(_ symbol: String, label: String, dimmed: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(dimmed ? Palette.secondary : Palette.primary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func summary(_ rows: [Row]) -> String {
        let counts = Dictionary(grouping: rows, by: \.activity).mapValues(\.count)
        var parts: [String] = []
        if let n = counts[.needsYou] { parts.append(n == 1 ? "1 needs you" : "\(n) need you") }
        if let n = counts[.error] { parts.append("\(n) failed") }
        if let n = counts[.working] { parts.append("\(n) working") }
        if parts.count < 2, let n = counts[.done] { parts.append("\(n) done") }
        if parts.isEmpty { parts.append(rows.count == 1 ? "1 idle session" : "\(rows.count) idle sessions") }
        return parts.prefix(2).joined(separator: " · ")
    }

    // MARK: list

    private func list(rows: [Row]) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    RowView(row: row, expanded: ui.expanded, reveal: reveal(index),
                            namespace: dots, reduceMotion: reduceMotion,
                            onOpen: { actions.select(row) },
                            onDecide: { decision in actions.decide(row, decision) })
                        .contextMenu {
                            Button("Open") { actions.select(row) }
                            Button(row.source == .bell ? "Dismiss Until It Rings Again" : "Dismiss") { actions.dismiss(row) }
                        }
                }
            }
            .padding(.horizontal, 8)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                }
            }
        }
        .scrollIndicators(.never)
        .scrollDisabled(ui.listHeight <= Layout.maxListHeight)
        .frame(height: min(ui.listHeight, Layout.maxListHeight))
        .onPreferenceChange(ListHeightKey.self) { height in
            MainActor.assumeIsolated { ui.listHeight = height }
        }
        .allowsHitTesting(ui.expanded)
        .accessibilityHidden(!ui.expanded)
    }

    /// Rows settle in just behind the opening shape, top to bottom; they leave all at once.
    private func reveal(_ index: Int) -> Animation {
        guard ui.expanded else { return .easeOut(duration: 0.1) }
        if reduceMotion { return .easeOut(duration: 0.15) }
        return .easeOut(duration: 0.3).delay(0.06 + 0.035 * Double(min(index, 5)))
    }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: island outline

/// Notch-like outline: concave fillets meeting the top edge, rounded bottom corners.
/// The rect includes the shoulders on both sides.
struct IslandShape: Shape {
    var shoulder: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, radius) }
        set { shoulder = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = shoulder
        let r = max(0, min(radius, rect.height / 2, (rect.width - 2 * s) / 2))
        let k: CGFloat = 0.5523 // cubic approximation of a quarter circle
        let left = rect.minX + s
        let right = rect.maxX - s
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addCurve(to: CGPoint(x: left, y: rect.minY + s),
                   control1: CGPoint(x: rect.minX + s * k, y: rect.minY),
                   control2: CGPoint(x: left, y: rect.minY + s * (1 - k)))
        p.addLine(to: CGPoint(x: left, y: rect.maxY - r))
        p.addCurve(to: CGPoint(x: left + r, y: rect.maxY),
                   control1: CGPoint(x: left, y: rect.maxY - r * (1 - k)),
                   control2: CGPoint(x: left + r * (1 - k), y: rect.maxY))
        p.addLine(to: CGPoint(x: right - r, y: rect.maxY))
        p.addCurve(to: CGPoint(x: right, y: rect.maxY - r),
                   control1: CGPoint(x: right - r * (1 - k), y: rect.maxY),
                   control2: CGPoint(x: right, y: rect.maxY - r * (1 - k)))
        p.addLine(to: CGPoint(x: right, y: rect.minY + s))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                   control1: CGPoint(x: right, y: rect.minY + s * (1 - k)),
                   control2: CGPoint(x: rect.maxX - s * k, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: folded state

/// One dot per active session, most urgent first. Each dot flies into its row when the island opens.
private struct Constellation: View {
    static let maxDots = 4

    let rows: [Row]
    let namespace: Namespace.ID
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(rows.prefix(Self.maxDots).enumerated()), id: \.element.id) { index, row in
                Pip(activity: row.activity, size: 7, phase: Double(index) * 0.35, reduceMotion: reduceMotion)
                    .matchedGeometryEffect(id: row.id, in: namespace)
            }
            if rows.count > Self.maxDots {
                Text("+\(rows.count - Self.maxDots)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.secondary)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Folded right wing: how many are waiting on you, else how many are working.
private struct Tally: View {
    let rows: [Row]

    var body: some View {
        let waiting = rows.filter { $0.activity == .needsYou }.count
        let failed = rows.filter { $0.activity == .error }.count
        let working = rows.filter { $0.activity == .working }.count
        Group {
            if waiting > 0 {
                Text("\(waiting)").foregroundStyle(Palette.amber)
            } else if failed > 0 {
                Text("\(failed)").foregroundStyle(Palette.red)
            } else if working > 0 {
                Text("\(working)").foregroundStyle(Palette.secondary)
            }
        }
        .font(.system(size: 13, weight: .bold).monospacedDigit())
        .contentTransition(.numericText())
        .animation(.snappy, value: waiting + failed + working)
        .accessibilityHidden(true)
    }
}

/// A session's state as a single point of light.
/// Working breathes, needs-you sends out rings, done blooms once, error holds still.
struct Pip: View {
    let activity: Activity
    let size: CGFloat
    var phase: Double = 0
    let reduceMotion: Bool

    @State private var breathing = false
    @State private var ringing = false
    @State private var bloom = false

    var body: some View {
        let tint = Palette.tint(activity)
        ZStack {
            if activity == .idle {
                Circle().strokeBorder(tint, lineWidth: 1.2)
            } else {
                Circle().fill(tint)
                    .opacity(activity == .working && !reduceMotion ? (breathing ? 0.95 : 0.35) : 1)
                    .scaleEffect(activity == .working && !reduceMotion ? (breathing ? 1 : 0.78) : 1)
            }
            if activity == .needsYou && !reduceMotion {
                Circle().stroke(tint, lineWidth: 1.2)
                    .scaleEffect(ringing ? 2.8 : 1)
                    .opacity(ringing ? 0 : 0.85)
            }
            if activity == .done && !reduceMotion {
                Circle().fill(tint)
                    .scaleEffect(bloom ? 2.6 : 1)
                    .opacity(bloom ? 0 : 0.7)
            }
        }
        .frame(width: size, height: size)
        .onAppear(perform: startLoops)
        .onChange(of: activity) { _, new in
            startLoops()
            if new == .done && !reduceMotion { flashBloom() }
        }
        .accessibilityHidden(true)
    }

    /// Loops start from their resting value so leaving and re-entering a state restarts them.
    private func startLoops() {
        guard !reduceMotion else { return }
        if activity != .working { breathing = false }
        if activity != .needsYou { ringing = false }
        if activity == .working && !breathing {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true).delay(phase)) {
                breathing = true
            }
        }
        if activity == .needsYou && !ringing {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                ringing = true
            }
        }
    }

    private func flashBloom() {
        withAnimation(.easeOut(duration: 0.9)) { bloom = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { bloom = false }
        }
    }
}

// MARK: rows

/// One session. Tap anywhere outside the buttons to jump to it.
struct RowView: View {
    let row: Row
    let expanded: Bool
    /// Text settles in behind the opening shape; the dot travels with the shape itself.
    let reveal: Animation
    let namespace: Namespace.ID
    let reduceMotion: Bool
    let onOpen: () -> Void
    let onDecide: (Decision) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                if expanded {
                    Pip(activity: row.activity, size: 8, reduceMotion: reduceMotion)
                        .matchedGeometryEffect(id: row.id, in: namespace)
                }
            }
            .frame(width: 10, height: 10)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }

            VStack(alignment: .leading, spacing: 0) {
                summary
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityText)
                    .accessibilityHint("Switches to this session")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onOpen() }
                if let prompt = row.prompt {
                    PromptBlock(prompt: prompt, row: row, onDecide: onDecide)
                        .padding(.top, 8)
                }
            }
            .opacity(expanded ? 1 : 0)
            .offset(y: expanded || reduceMotion ? 0 : -6)
            .blur(radius: expanded || reduceMotion ? 0 : 3)
            .animation(reveal, value: expanded)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(elapsed(from: row.since, to: context.date))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.secondary)
            }
            .lineLimit(1)

            meta

            if let status {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor)
                    .lineLimit(row.activity == .error ? 2 : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
        }
    }

    /// Who is running it and where: agent, model, zellij session › tab.
    private var meta: some View {
        HStack(spacing: 6) {
            if let agent = row.agent {
                Text(agent)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().strokeBorder(Palette.hairline))
            }
            Text([row.model, row.location].compactMap { $0 }.joined(separator: "  ·  "))
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .truncationMode(.middle)
        }
        .lineLimit(1)
    }

    /// The prompt block carries the details while the row needs you; the line only summarizes.
    private var status: String? {
        if row.source == .bell { return "Rang" }
        switch row.activity {
        case .needsYou:
            switch row.prompt {
            case .questions: return nil
            case .approval(let tool, _): return "Wants to use \(tool)"
            case .plan: return "Plan ready for review"
            case nil: return row.detail ?? "Needs you"
            }
        case .error: return row.detail.map { "Failed · \($0)" } ?? "Failed"
        case .working: return row.detail ?? "Working"
        case .done: return row.detail.map { "Done · \($0)" } ?? "Done"
        case .idle: return "Idle"
        }
    }

    private var statusColor: Color {
        switch row.activity {
        case .needsYou: Palette.amber
        case .error: Palette.red
        case .done: Palette.green
        case .working, .idle: Palette.secondary
        }
    }

    private var accessibilityText: String {
        var parts = [row.title]
        if let agent = row.agent { parts.append(agent) }
        if let model = row.model { parts.append(model) }
        if let location = row.location { parts.append(location.replacingOccurrences(of: " › ", with: ", tab ")) }
        if let status { parts.append(status) }
        parts.append(elapsedSpoken(from: row.since))
        return parts.joined(separator: ", ")
    }
}

/// What the agent is waiting on: its questions and choices, or the command it wants to run.
private struct PromptBlock: View {
    static let maxQuestions = 3

    let prompt: PromptDetail
    let row: Row
    let onDecide: (Decision) -> Void

    var body: some View {
        switch prompt {
        case .questions(let questions):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(questions.prefix(Self.maxQuestions).enumerated()), id: \.offset) { _, question in
                    QuestionView(question: question)
                }
                if questions.count > Self.maxQuestions {
                    Text("\(questions.count - Self.maxQuestions) more in the terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                }
                answerHint
            }
        case .approval(_, let command):
            VStack(alignment: .leading, spacing: 8) {
                if let command {
                    Text(command)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Palette.primary)
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
                        .textSelection(.enabled)
                }
                if row.canDecide { decisionButtons } else { answerHint }
            }
        case .plan:
            answerHint
        }
    }

    private var decisionButtons: some View {
        HStack(spacing: 6) {
            if row.canAlwaysAllow {
                Button("Always allow") { onDecide(.alwaysAllow) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .help("Approve and stop asking for this kind of request")
            }
            Spacer(minLength: 0)
            Button("Deny") { onDecide(.deny) }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            Button("Approve") { onDecide(.allow) }
                .buttonStyle(PillButtonStyle(kind: .primary))
        }
        .padding(.top, 2)
    }

    /// Agents without an answer API (omp, pi, Claude's questions) are answered where they run.
    private var answerHint: some View {
        Label("Answer in \(row.agent ?? "the terminal")", systemImage: "arrow.up.forward")
            .labelStyle(TrailingIconLabelStyle())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.secondary)
    }
}

private struct QuestionView: View {
    let question: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.amber)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 5, lineSpacing: 5) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    OptionChip(number: index + 1, label: option, suggested: question.recommended == index)
                }
                if question.multiSelect {
                    Text("pick any")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.secondary)
                        .padding(.vertical, 3)
                }
            }
        }
    }
}

/// Numbered like the terminal prompt, so you know which key to press when you get there.
private struct OptionChip: View {
    let number: Int
    let label: String
    let suggested: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text("\(number)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.secondary)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(suggested ? Palette.amber.opacity(0.7) : Palette.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Option \(number): \(label)\(suggested ? ", suggested" : "")")
    }
}

private struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Color.black : Palette.primary.opacity(kind == .quiet ? 0.75 : 1))
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(
                Capsule().fill(kind == .primary ? AnyShapeStyle(Palette.amber)
                               : AnyShapeStyle(Color.white.opacity(kind == .quiet ? 0 : 0.12)))
            )
            .overlay(Capsule().strokeBorder(kind == .quiet ? Palette.hairline : .clear))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}

/// Wraps chips onto as many lines as they need.
private struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, layout.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0 && x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + lineHeight), frames)
    }
}

private func elapsed(from start: Date, to now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(start))
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86400)d"
}

private func elapsedSpoken(from start: Date) -> String {
    let minutes = Int(Date().timeIntervalSince(start)) / 60
    if minutes < 1 { return "just now" }
    if minutes < 60 { return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago" }
    let hours = minutes / 60
    return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
}
