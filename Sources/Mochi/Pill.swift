import AppKit
import MochiKit
import SwiftUI

/// The floating recording pill: a non-activating panel above every window and Space, so the call
/// app keeps the keyboard. It can be tucked away into a round Mochi bubble that sits partly behind
/// the nearest screen edge, breathes with the audio, peeks out on hover and opens again on a click.
///
/// Two fixed-size panels, the pill's and the bubble's: resizing a SwiftUI-hosted window while its
/// content animates makes AppKit throw (seen in testing), so panels only ever move. The glass
/// morphs inside the pill panel, then the bubble panel takes over at the same spot and glides.
@Observable
@MainActor
final class PillController {
    static let shared = PillController()
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var bubblePanel: NSPanel?

    /// The pill panel shows the bubble shape (true) or the pill. Changed with a spring: the glass morphs.
    private(set) var bubble = false
    /// The bubble panel is the one on screen, at the edge.
    private(set) var small = false
    /// The bubble is out from behind the edge (hover or drag).
    private(set) var peeking = false
    /// The bubble rests on the left edge (its red dot goes to the side that stays visible).
    var onLeftEdge: Bool { access(keyPath: \.tucked); return UserDefaults.standard.string(forKey: "bubbleEdge") == "left" }
    @ObservationIgnored private var moving = false
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var generation = 0

    static let pillSize = NSSize(width: 560, height: 60)
    static let bubbleSize = NSSize(width: 84, height: 84)
    static let bubbleDiameter: CGFloat = 52

    var enabled: Bool { UserDefaults.standard.object(forKey: "showPill") as? Bool ?? true }

    /// You tucked the pill away: kept across calls.
    var tucked: Bool {
        get { access(keyPath: \.tucked); return UserDefaults.standard.bool(forKey: "pillCollapsed") }
        set { withMutation(keyPath: \.tucked) { UserDefaults.standard.set(newValue, forKey: "pillCollapsed") } }
    }

    /// Tucked away, unless something needs you: the recording broke or the call seems over.
    /// The Saved notice after Stop has no session, so it shows in the pill.
    var wantsBubble: Bool {
        guard tucked, let s = AppModel.shared.session else { return false }
        if case .broken = s.health { return false }
        return s.endedCountdown == nil
    }

    func show() {
        guard enabled else { return }
        if panel == nil { panel = makePanel() }
        if bubblePanel == nil { bubblePanel = makeBubblePanel() }
        visible = true
        if wantsBubble {
            // Straight to the edge, no animation, when a call starts tucked.
            generation += 1
            bubble = true
            small = true
            peeking = false
            bubblePanel?.setFrameOrigin(edgeOrigin(peek: false))
            bubblePanel?.orderFrontRegardless()
            panel?.orderOut(nil)
        } else {
            bubble = false
            small = false
            bubblePanel?.orderOut(nil)
            panel?.orderFrontRegardless()
        }
    }

    func hide() {
        visible = false
        generation += 1
        panel?.orderOut(nil)
        bubblePanel?.orderOut(nil)
    }

    func update() {
        guard visible, let panel, let bubblePanel else { return }
        generation += 1
        let gen = generation
        if wantsBubble {
            guard !small else { return }
            withAnimation(.spring(duration: 0.4, bounce: 0.25)) { bubble = true }
            // Hand over once the morph has settled, then glide to the edge.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.generation == gen else { return }
                bubblePanel.setFrameOrigin(self.bubbleOrigin(inPill: panel.frame))
                bubblePanel.orderFrontRegardless()
                panel.orderOut(nil)
                self.small = true
                self.glide(to: self.edgeOrigin(peek: false))
            }
        } else {
            guard small || bubble else { return }
            guard small else {
                withAnimation(.spring(duration: 0.4, bounce: 0.2)) { bubble = false }
                return
            }
            // The bubble flies back to the pill's start, then grows into the pill.
            glide(to: bubbleOrigin(inPill: panel.frame)) { [weak self] in
                guard let self, self.generation == gen else { return }
                panel.orderFrontRegardless()
                bubblePanel.orderOut(nil)
                self.small = false
                self.peeking = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard self.generation == gen else { return }
                    withAnimation(.spring(duration: 0.45, bounce: 0.25)) { self.bubble = false }
                }
            }
        }
    }

    func peek(_ out: Bool) {
        guard small, !moving, out != peeking else { return }
        peeking = out
        glide(to: edgeOrigin(peek: out))
    }

    // MARK: Dragging the bubble

    @ObservationIgnored private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    var isDragging: Bool { dragStart != nil }

    func drag() {
        guard let bubblePanel, small else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, bubblePanel.frame.origin); moving = true }
        guard let start = dragStart else { return }
        bubblePanel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    /// Let go: snap to the nearest side edge of that screen, partly tucked.
    func endDrag() {
        guard let bubblePanel, dragStart != nil else { return }
        dragStart = nil
        let center = NSPoint(x: bubblePanel.frame.midX, y: bubblePanel.frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        if let screen {
            let v = screen.visibleFrame
            withMutation(keyPath: \.tucked) {
                UserDefaults.standard.set(center.x < v.midX ? "left" : "right", forKey: "bubbleEdge")
            }
            UserDefaults.standard.set((center.y - v.minY) / max(v.height, 1), forKey: "bubbleHeight")
            UserDefaults.standard.set(screen.localizedName, forKey: "bubbleScreen")
        }
        peeking = false
        glide(to: edgeOrigin(peek: false)) { [weak self] in self?.moving = false }
    }

    // MARK: Places

    /// The bubble panel's origin when its bubble sits where the pill panel draws it (at the start).
    private func bubbleOrigin(inPill pill: NSRect) -> NSPoint {
        NSPoint(x: pill.minX + 6 + Self.bubbleDiameter / 2 - Self.bubbleSize.width / 2,
                y: pill.midY - Self.bubbleSize.height / 2)
    }

    /// The bubble's resting place on its edge, a third behind it; peeking, fully out.
    private func edgeOrigin(peek: Bool) -> NSPoint {
        let name = UserDefaults.standard.string(forKey: "bubbleScreen")
        let screen = NSScreen.screens.first { $0.localizedName == name } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        let left = UserDefaults.standard.string(forKey: "bubbleEdge") == "left"
        let height = UserDefaults.standard.object(forKey: "bubbleHeight") as? Double ?? 0.72
        let r = Self.bubbleDiameter / 2
        // Tucked a third behind the edge, unless another screen is on that side (it would show
        // there): then it sits just inside. Peeking: fully out, 10 pt from the edge.
        let beyond = NSPoint(x: left ? v.minX - 4 : v.maxX + 4, y: v.midY)
        let neighbour = NSScreen.screens.contains { $0 != screen && $0.frame.insetBy(dx: -1, dy: 0).contains(beyond) }
        let inset = peek || neighbour ? -(r + 10) : -r * 0.35
        let centerX = left ? v.minX - inset : v.maxX + inset
        let centerY = min(max(v.minY + v.height * height, v.minY + r + 8), v.maxY - r - 8)
        return NSPoint(x: centerX - Self.bubbleSize.width / 2, y: centerY - Self.bubbleSize.height / 2)
    }

    private func glide(to origin: NSPoint, then done: (() -> Void)? = nil) {
        guard let bubblePanel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.05)
            bubblePanel.animator().setFrame(NSRect(origin: origin, size: Self.bubbleSize), display: true)
        } completionHandler: {
            MainActor.assumeIsolated { done?() }
        }
    }

    private static func floatingPanel(size: NSSize, label: String, content: some View) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.setAccessibilityLabel(label)
        let host = PillHostingView(rootView: AnyView(content.environment(AppModel.shared)
            .environment(\.controlActiveState, .key).environment(\.appearsActive, true)))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    private func makePanel() -> NSPanel {
        let panel = Self.floatingPanel(size: Self.pillSize, label: "Mochi recording", content: PillView())
        panel.isMovableByWindowBackground = true
        // Before the bubble the frame was autosaved under this name; keep where you had put it.
        if panel.setFrameUsingName("MochiPill") {
            panel.setFrame(NSRect(origin: panel.frame.origin, size: Self.pillSize), display: false)
        } else if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - Self.pillSize.width + 24, y: v.maxY - Self.pillSize.height - 12))
        }
        panel.setFrameAutosaveName("MochiPill")
        return panel
    }

    private func makeBubblePanel() -> NSPanel {
        Self.floatingPanel(size: Self.bubbleSize, label: "Mochi recording, tucked away", content: BubblePanelView())
    }
}

/// The panel never becomes key (so the call app keeps the keyboard), which makes every click a
/// "first mouse" click. Without this, AppKit swallows it and the pill's buttons do nothing.
final class PillHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The pill's content. Left aligned in a wide transparent panel; the capsule hugs its content.
/// Tucked, the same glass morphs into the round bubble.
struct PillView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var glass
    private var controller: PillController { .shared }

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 0) {
                if controller.bubble, let session = model.session {
                    MochiBubble(session: session, glassID: glass)
                        .frame(width: PillController.bubbleDiameter, height: PillController.bubbleDiameter)
                } else {
                    content
                        .padding(.horizontal, 16)
                        .frame(height: 48)
                        .glassEffect(.regular, in: .capsule)
                        .glassEffectID("pill", in: glass)
                        .overlay { border }
                        .animation(.smooth(duration: 0.2), value: stateKey)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
        }
        .onChange(of: controller.wantsBubble) { controller.update() }
        .onChange(of: model.isRecording || model.savedNotice != nil) { _, visible in
            if !visible { PillController.shared.hide() }
        }
    }

    private var stateKey: String {
        if let s = model.session { return "\(s.health)\(s.paused)\(s.endedCountdown != nil)" }
        return model.savedNotice == nil ? "idle" : "saved"
    }
    @ViewBuilder private var border: some View {
        switch model.session?.health {
        case .attention?: Capsule().strokeBorder(.orange, lineWidth: 1.5)
        case .broken?: Capsule().strokeBorder(.red, lineWidth: 1.5)
        default: EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        if let session = model.session {
            RecordingPillContent(session: session)
        } else if let saved = model.savedNotice {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                Text("Recording saved").font(.body.weight(.semibold))
                Text("\(TranscriptText.duration(saved.duration)) · \(saved.bothSides ? "both sides" : "your side only")")
                    .foregroundStyle(.secondary)
                Button("Copy Transcript") { model.copyTranscript(saved.callID) }
                    .buttonStyle(SolidButtonStyle(color: .accentColor))
                Button("Open") {
                    model.selectedCallID = saved.callID
                    model.section = .calls
                    NSApp.activate()
                }
                .buttonStyle(.glass)
            }
            .controlSize(.small)
        }
    }
}

struct RecordingPillContent: View {
    @Environment(AppModel.self) private var model
    let session: RecordingSession

    var body: some View {
        HStack(spacing: 14) {
            if let countdown = session.endedCountdown {
                LiveWaveform(levels: session.wave, tint: .primary)
                Text(TranscriptText.clock(session.savedSeconds)).font(.title3.weight(.semibold)).monospacedDigit()
                Text("Call ended? Still recording.").font(.body.weight(.medium))
                Button("Keep Recording") { model.keepRecording() }.buttonStyle(.glass)
                Button("Stop (\(countdown))") { model.stopRecording() }.buttonStyle(SolidButtonStyle(color: .red))
            } else {
                switch session.health {
                case .broken(let why):
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    Text("Recording stopped").font(.body.weight(.semibold)).foregroundStyle(.red)
                    Text("\(why). \(TranscriptText.clock(session.savedSeconds)) is saved.")
                        .foregroundStyle(.secondary).lineLimit(1)
                    stopButton
                default:
                    LiveWaveform(levels: session.wave, tint: waveTint)
                    Text(session.health == .starting ? "Starting…" : TranscriptText.clock(session.savedSeconds))
                        .font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(session.paused || session.health == .starting ? .secondary : .primary)
                    SideTraces(me: session.micLevel, them: session.themLevel, dim: session.paused)
                    if case .attention(let why) = session.health {
                        Text(why).foregroundStyle(.orange).font(.body.weight(.medium)).lineLimit(1)
                    }
                    Button { model.togglePause() } label: {
                        Image(systemName: session.paused ? "play.fill" : "pause.fill").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help(session.paused ? "Resume recording (⌃⌥P)" : "Pause recording (⌃⌥P)")
                    stopButton
                    Button { PillController.shared.tucked = true } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 20, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Tuck the pill away")
                    .accessibilityLabel("Tuck the pill away")
                }
            }
        }
        .controlSize(.small)
    }

    private var waveTint: Color {
        if case .attention = session.health { return .orange }
        return session.paused || session.health == .starting ? Color.secondary : .primary
    }

    private var stopButton: some View {
        Button { model.stopRecording() } label: {
            Image(systemName: "stop.fill").frame(width: 28, height: 28)
        }
        .buttonStyle(SolidButtonStyle(color: .red, circle: true))
        .help("Stop recording (⌃⌥R)")
    }
}

/// The waveform: five bars following the last levels of both tracks.
struct LiveWaveform: View {
    let levels: [Double]
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let recent = levels.suffix(10)
                let base = recent.isEmpty ? 0 : recent.reduce(0, +) / Double(recent.count)
                let shape = [0.55, 0.85, 1.0, 0.75, 0.5][i]
                let jitter = levels.count > i ? levels[levels.count - 1 - i] : 0
                Capsule()
                    .fill(tint)
                    .frame(width: 2.5, height: max(3, 18 * min(1, (base * 0.6 + jitter * 0.4) * shape * 1.4)))
            }
        }
        .frame(width: 22, height: 20)
        .animation(.easeOut(duration: 0.12), value: levels)
        .accessibilityHidden(true)
    }
}

/// Two tiny level traces, You and Them: the proof that both sides are arriving.
struct SideTraces: View {
    let me: Double
    let them: Double
    var dim = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
            row("You", me, .accentColor)
            row("Them", them, .primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You \(Int(me * 100)) percent, Them \(Int(them * 100)) percent")
    }

    private func row(_ label: String, _ level: Double, _ color: Color) -> some View {
        GridRow {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).fixedSize()
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(dim ? Color.secondary : color).frame(width: max(2, 52 * level))
            }
            .frame(width: 52, height: 4)
            .animation(.easeOut(duration: 0.15), value: level)
        }
    }
}

/// The bubble panel's content: the bubble centred in it.
struct BubblePanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let session = model.session { MochiBubble(session: session, live: true) }
        }
        .frame(width: PillController.bubbleSize.width, height: PillController.bubbleSize.height)
    }
}

/// The tucked pill: the Mochi icon in a round glass bubble with a red recording dot and a ring that
/// breathes with the voices. Hover peeks it out and shows the timer; drag moves it to another edge
/// or height; a click opens the pill again.
struct MochiBubble: View {
    @Environment(AppModel.self) private var model
    let session: RecordingSession
    /// In the bubble panel (hover, drag and click work); false while it morphs inside the pill.
    var live = false
    /// Inside the pill: the shared glass id, so the capsule morphs into this circle and back.
    var glassID: Namespace.ID?
    @State private var hovering = false
    private var controller: PillController { .shared }

    private var level: Double {
        let recent = session.wave.suffix(4)
        return session.paused ? 0 : recent.reduce(0, +) / Double(max(recent.count, 1))
    }

    private var ringColor: Color {
        if case .attention = session.health { return .orange }
        return session.paused ? .secondary : .red
    }

    var body: some View {
        let d = PillController.bubbleDiameter
        ZStack {
            // The breathing ring: a soft halo that swells with the louder side.
            Circle()
                .strokeBorder(ringColor.opacity(session.paused ? 0.35 : 0.55), lineWidth: 2.5)
                .frame(width: d + 6, height: d + 6)
                .scaleEffect(1 + level * 0.22)
                .opacity(0.5 + level * 0.5)
                .blur(radius: 0.6)
                .animation(.spring(response: 0.3, dampingFraction: 0.55), value: level)
            Group {
                if hovering {
                    VStack(spacing: 0) {
                        Text(TranscriptText.clock(session.savedSeconds))
                            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        if session.paused { Text("Paused").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary) }
                    }
                    .transition(.blurReplace)
                } else {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().interpolation(.high)
                        .frame(width: d - 10, height: d - 10)
                        .transition(.blurReplace)
                }
            }
            .frame(width: d, height: d)
            .glassEffect(.regular.interactive(), in: .circle)
            .modifier(GlassID(namespace: glassID))
            .overlay(alignment: controller.onLeftEdge || !live ? .topTrailing : .topLeading) {
                Circle().fill(session.paused ? Color.secondary : .red)
                    .frame(width: 11, height: 11)
                    .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5) }
                    .phaseAnimator([1.0, 0.45]) { dot, phase in dot.opacity(session.paused ? 1 : phase) } animation: { _ in
                        .easeInOut(duration: 0.9)
                    }
                    .offset(x: controller.onLeftEdge || !live ? 1 : -1, y: -1)
            }
        }
        .frame(width: live ? PillController.bubbleSize.width : d, height: live ? PillController.bubbleSize.height : d)
        .contentShape(Circle().scale(live ? 0.75 : 1))
        .allowsHitTesting(live)
        .onHover { inside in
            withAnimation(.snappy(duration: 0.2)) { hovering = inside }
            controller.peek(inside)
        }
        // One gesture for both: a press that barely moves is a click (open the pill), more is a drag.
        // A separate tap gesture missed clicks while the bubble was still gliding out on hover.
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if hypot(value.translation.width, value.translation.height) > 3 { controller.drag() }
            }
            .onEnded { value in
                if controller.isDragging { controller.endDrag() } else { controller.tucked = false }
            })
        .help("Recording \(TranscriptText.clock(session.savedSeconds)). Click to open, drag to move.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mochi recording, \(TranscriptText.clock(session.savedSeconds))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { controller.tucked = false }
    }
}

/// A filled button that keeps its colour in the floating panels. Those never become key, and the
/// system's prominent styles draw grey ("inactive") in a window that is not key.
struct SolidButtonStyle: ButtonStyle {
    var color: Color
    var circle = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(circle ? nil : .system(size: size == .large ? 13 : 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, circle ? 0 : (size == .large ? 14 : 10))
            .frame(minHeight: circle ? nil : (size == .large ? 30 : 24))
            .background {
                if circle { Circle().fill(color.gradient) } else { Capsule().fill(color.gradient) }
            }
            .overlay { if configuration.isPressed { (circle ? AnyShape(Circle()) : AnyShape(Capsule())).fill(.black.opacity(0.15)) } }
            .contentShape(circle ? AnyShape(Circle()) : AnyShape(Capsule()))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

private struct GlassID: ViewModifier {
    let namespace: Namespace.ID?
    func body(content: Content) -> some View {
        if let namespace { content.glassEffectID("pill", in: namespace) } else { content }
    }
}
