import AppKit
import SwiftUI

enum Layout {
    /// Side area beside the notch while folded: dots on the left, count on the right.
    /// Fits four dots plus a "+N" overflow with an inset from the island's rounded edge.
    static let wing: CGFloat = 72
    static let expandedWidth: CGFloat = 468
    static let maxListHeight: CGFloat = 440
    static let listBottomInset: CGFloat = 10
    /// Concave fillets where the island meets the top edge, like the hardware notch.
    static let shoulder: CGFloat = 8
    static let foldedRadius: CGFloat = 11
    static let expandedRadius: CGFloat = 24
}

struct NotchGeometry: Equatable {
    var screenFrame: NSRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool

    /// The screen chosen in Settings; a notch-sized area at the top when it has no notch.
    @MainActor static func current() -> NotchGeometry {
        let screens = NSScreen.screens
        let primary = screens.first ?? NSScreen.main!
        let screen: NSScreen = switch Preferences.shared.display {
        case .notch: screens.first { $0.safeAreaInsets.top > 0 } ?? primary
        case .primary: primary
        case .pointer: screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? primary
        }
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return NotchGeometry(screenFrame: frame,
                                 notchWidth: frame.width - left.width - right.width,
                                 notchHeight: screen.safeAreaInsets.top,
                                 hasNotch: true)
        }
        return NotchGeometry(screenFrame: frame, notchWidth: 180,
                             notchHeight: max(frame.maxY - screen.visibleFrame.maxY, 24),
                             hasNotch: false)
    }
}

@MainActor
@Observable
final class NotchUI {
    var expanded = false
    var geometry = NotchGeometry.current()
    /// Sessions shown as dots while folded. Empty means the island rests inside the notch.
    var constellation: [Row] = []
    /// Measured height of the session list, laid out even while folded so opening is one motion.
    var listHeight: CGFloat = 0
    /// The chime's visible counterpart: set when a moment rings, cleared after the ring fades.
    var ring: RingPulse?

    var resting: Bool { !expanded && constellation.isEmpty }

    /// Body size without shoulders; the view animates toward it and the pointer tracking uses it.
    var islandSize: CGSize {
        let g = geometry
        if expanded {
            return CGSize(width: Layout.expandedWidth,
                          height: g.notchHeight + min(listHeight, Layout.maxListHeight) + Layout.listBottomInset)
        }
        if constellation.isEmpty { return CGSize(width: g.notchWidth, height: g.notchHeight) }
        return CGSize(width: g.notchWidth + 2 * Layout.wing, height: g.notchHeight)
    }
}

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Let the panel sit over the menu bar instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Clicks land without activating Nubbin first.
/// While the island takes the pointer, the global mouse monitor goes quiet; this tracking area keeps
/// mouse-moved events flowing to the local monitor so leaving the island is noticed immediately.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self && $0.options.contains(.mouseMoved) }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
    }
}

struct NotchActions {
    let toggle: () -> Void
    let select: (Row) -> Void
    let dismiss: (Row) -> Void
    let decide: (Row, Decision) -> Void
    let toggleMute: () -> Void
    let openSettings: () -> Void
}

/// The panel never resizes: it covers the largest island, and SwiftUI morphs the island inside it.
/// Mouse events pass through everywhere except the island's current outline.
@MainActor
final class NotchController {
    private let store: Store
    private let ui = NotchUI()
    private let panel = NotchPanel()
    private var hovering = false
    private var foldTask: Task<Void, Never>?
    private var monitors: [Any] = []

    init(store: Store, onSelect: @escaping (Row) -> Void, onToggleMute: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.store = store

        let actions = NotchActions(
            toggle: { [weak self] in self?.toggle() },
            select: { [weak self] row in
                onSelect(row)
                self?.setExpanded(false)
            },
            dismiss: { [weak self] row in self?.store.dismiss(row) },
            decide: { [weak self] row, decision in self?.store.decide(row, decision) },
            toggleMute: onToggleMute,
            openSettings: { [weak self] in
                self?.setExpanded(false)
                onOpenSettings()
            }
        )
        panel.contentView = NotchHostingView(rootView: NotchView(store: store, ui: ui, actions: actions))

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ui.geometry = .current()
                self?.placePanel()
            }
        }
        // Window tiling and Space changes can shove the panel down the screen; put it back at the top.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placePanel() }
        }
        let track: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: track) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            track(event)
            return event
        }) {
            monitors.append(local)
        }

        observeRows()
        observeDisplay()
        refresh()
        placePanel()
        panel.orderFrontRegardless()
    }

    /// Open for a moment to show what needs attention.
    func flash() {
        setExpanded(true)
        let after = Preferences.shared.autoFoldAfter
        if after > 0 { scheduleFold(after: after) } else { foldTask?.cancel() }
    }

    /// Ring the notch for a moment, in time with the sound's loudness.
    /// Rehearsals from Settings pass `allowOpen: false`: an opened island would cover the Settings stage.
    func ring(_ moment: Moment, envelope: [Float], allowOpen: Bool = true) {
        let style = Preferences.shared.style(moment)
        if style.rings { ui.ring = RingPulse(moment: moment, envelope: envelope) }
        if style.opensIsland && allowOpen { flash() }
    }

    /// Recompute which sessions show as dots; finished ones age out without a hook event.
    func refresh() {
        let now = Date()
        let rows = store.rows
        let prefs = Preferences.shared
        let constellation = rows.filter { row in
            switch row.activity {
            case .needsYou, .error: true
            case .working: !prefs.dotsOnlyForAttention
            case .done: !prefs.dotsOnlyForAttention && now.timeIntervalSince(row.since) < prefs.doneLingers
            case .idle: false
            }
        }
        if constellation != ui.constellation { ui.constellation = constellation }
        if rows.isEmpty { setExpanded(false) }
        trackPointer()
    }

    /// The island hotkey and menu bar: open it, or fold it if open.
    func toggle() {
        if ui.expanded { setExpanded(false) } else { flash() }
    }

    /// Leaving folds the island whichever way it opened; reaching it opens only with hover to open.
    private func hover(_ inside: Bool) {
        hovering = inside
        if !inside {
            if ui.expanded { scheduleFold(after: 0.1) }
            return
        }
        guard Preferences.shared.hoverToOpen else { return }
        foldTask?.cancel()
        setExpanded(true)
    }

    private func scheduleFold(after seconds: TimeInterval) {
        foldTask?.cancel()
        foldTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.hovering else { return }
            self.setExpanded(false)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        let expanded = expanded && !store.rows.isEmpty
        guard ui.expanded != expanded else { return }
        ui.expanded = expanded
        trackPointer()
    }

    private func observeRows() {
        withObservationTracking {
            _ = store.rows
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observeRows()
            }
        }
    }

    /// Full screen width so the ring can spread across the menu bar; mouse events still pass through
    /// everywhere except the island itself.
    private func placePanel() {
        let g = ui.geometry
        let height = g.notchHeight + Layout.maxListHeight + Layout.listBottomInset + 24
        let frame = NSRect(x: g.screenFrame.minX, y: g.screenFrame.maxY - height, width: g.screenFrame.width, height: height)
        guard panel.frame != frame else { return }
        if panel.frame.size == frame.size { debugLog("panel moved to \(panel.frame); back to \(frame)") }
        panel.setFrame(frame, display: true)
    }

    /// Screen rect of the island's target shape, with a little slop so the edge isn't twitchy.
    private var hoverRect: NSRect {
        let g = ui.geometry
        let size = ui.islandSize
        return NSRect(x: g.screenFrame.midX - size.width / 2 - 6, y: g.screenFrame.maxY - size.height - 4,
                      width: size.width + 12, height: size.height + 4)
    }

    private func observeDisplay() {
        withObservationTracking {
            _ = Preferences.shared.display
            _ = Preferences.shared.dotsOnlyForAttention
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.moveToChosenScreen()
                self?.refresh()
                self?.observeDisplay()
            }
        }
    }

    private func moveToChosenScreen() {
        let geometry = NotchGeometry.current()
        guard geometry != ui.geometry else { return }
        ui.geometry = geometry
        placePanel()
    }

    private func trackPointer() {
        if Preferences.shared.display == .pointer,
           !NSMouseInRect(NSEvent.mouseLocation, ui.geometry.screenFrame, false) {
            moveToChosenScreen()
        }
        let inside = !store.rows.isEmpty && hoverRect.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        if inside != hovering { hover(inside) }
    }
}
