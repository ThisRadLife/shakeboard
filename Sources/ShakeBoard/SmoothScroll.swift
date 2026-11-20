//
//  SmoothScroll.swift
//  ShakeBoard -- eased mouse-wheel scrolling for the strip's scroll views, and the shake open/close rule.
//
//  A classic mouse wheel (hasPreciseScrollingDeltas == false) reports coarse line ticks, so SwiftUI's
//  ScrollView jumps in steps. Every scroll view that opts in with `.smoothWheel(_:)` gets those ticks
//  turned into an eased glide instead: each tick moves a TARGET offset (accumulating across fast ticks,
//  clamped to the content), and the visible offset approaches it exponentially on the display link
//  (~95 % in 120 ms; a single tick settles in ~180 ms, a long fling in ~270 ms; never past an edge). A vertical wheel drives a horizontal strip.
//  Trackpads and Magic Mouse (precise deltas, with momentum) are left completely native. With
//  System Settings > Accessibility > Display > Reduce motion on, ticks jump straight to the target.
//

import AppKit
import SwiftUI

// MARK: - Motion preferences

enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Eased animation for programmatic scrolls (keyboard selection), or none when Reduce motion is on.
    static var scroll: Animation? { reduce ? nil : .easeOut(duration: 0.22) }
}

// MARK: - The easing model (pure, unit-tested)

struct EasedScroll: Equatable {
    var position: CGFloat
    var target: CGFloat
    var lower: CGFloat = 0
    var upper: CGFloat
    /// Time constant: the gap shrinks by 1/e every `tau` seconds.
    static let tau: CGFloat = 0.04
    static let settle: CGFloat = 0.5

    init(position: CGFloat, lower: CGFloat = 0, upper: CGFloat) {
        self.lower = lower
        self.upper = max(lower, upper)
        self.position = min(max(position, lower), self.upper)
        self.target = self.position
    }

    var isSettled: Bool { abs(target - position) < Self.settle }

    /// One wheel tick: move the target (not the position), clamped, so fast ticks accumulate.
    mutating func add(_ delta: CGFloat) {
        target = min(max(target + delta, lower), upper)
    }

    /// Advance by `dt` seconds. Returns true while still moving.
    @discardableResult
    mutating func step(_ dt: CGFloat) -> Bool {
        guard !isSettled else { position = target; return false }
        let k = 1 - exp(-max(0, dt) / Self.tau)
        position += (target - position) * k
        if isSettled { position = target; return false }
        return true
    }

    /// The content or viewport changed size: keep everything inside the new bounds.
    mutating func rebound(lower: CGFloat, upper: CGFloat) {
        self.lower = lower
        self.upper = max(lower, upper)
        position = min(max(position, self.lower), self.upper)
        target = min(max(target, self.lower), self.upper)
    }
}

// MARK: - Wheel -> offset mapping (pure, unit-tested)

enum WheelMapping {
    /// Points per wheel "line". AppKit's own line scroll is ~10 pt, which feels sluggish across 200 pt cards.
    static let pointsPerLine: CGFloat = 40
    /// One burst can't fling more than this.
    static let maxPerEvent: CGFloat = 600

    /// The offset change for a non-precise wheel event. Horizontal views take whichever of the vertical wheel
    /// or a tilt wheel is dominant; wheel away from you (deltaY > 0) moves toward the start, like AppKit.
    /// Vertical views: wheel toward you (deltaY < 0) shows content further down.
    static func delta(axis: Axis, deltaX: CGFloat, deltaY: CGFloat, flipped: Bool) -> CGFloat {
        let raw: CGFloat
        switch axis {
        case .horizontal:
            raw = -(abs(deltaX) > abs(deltaY) ? deltaX : deltaY)
        case .vertical:
            raw = flipped ? -deltaY : deltaY
        }
        return min(max(raw * pointsPerLine, -maxPerEvent), maxPerEvent)
    }
}

// MARK: - Live scrolling (AppKit)

@MainActor
final class SmoothWheel {
    static let shared = SmoothWheel()

    private final class Entry {
        weak var scrollView: NSScrollView?
        let axis: Axis
        var model: EasedScroll?
        var lastSet: CGFloat = 0
        var link: CADisplayLink?
        var lastTime: CFTimeInterval = 0
        init(_ sv: NSScrollView, axis: Axis) { scrollView = sv; self.axis = axis }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var monitor: Any?
    private let debug = ProcessInfo.processInfo.environment["PERCH_DEBUG_SCROLL"] == "1"

    func register(_ sv: NSScrollView, axis: Axis) {
        entries = entries.filter { $0.value.scrollView != nil }
        let id = ObjectIdentifier(sv)
        if let e = entries[id], e.axis == axis { return }
        entries[id] = Entry(sv, axis: axis)
        if debug { NSLog("ShakeBoard scroll: registered %@ scroll view (%d live)", axis == .horizontal ? "horizontal" : "vertical", entries.count) }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) ?? event }
            }
        }
    }

    var registeredCount: Int { entries.values.filter { $0.scrollView != nil }.count }

    /// Returns nil when the event was consumed (we're animating it), else the event untouched.
    func handle(_ event: NSEvent, window override: NSWindow? = nil, at point: NSPoint? = nil) -> NSEvent? {
        guard !event.hasPreciseScrollingDeltas, event.phase.isEmpty, event.momentumPhase.isEmpty,
              !event.modifierFlags.contains(.command),   // leave Cmd-wheel (zoom in some apps) alone
              let window = override ?? event.window, let content = window.contentView else { return event }
        let loc = point ?? event.locationInWindow
        let p = content.superview?.convert(loc, from: nil) ?? loc
        var view = content.hitTest(p)
        while let sv = (view as? NSScrollView) ?? view?.enclosingScrollView {
            if let e = entries[ObjectIdentifier(sv)], e.scrollView === sv, scroll(e, event) { return nil }
            view = sv.superview
        }
        return event
    }

    private func bounds(_ sv: NSScrollView, _ axis: Axis) -> (lower: CGFloat, upper: CGFloat, current: CGFloat)? {
        guard let doc = sv.documentView else { return nil }
        let clip = sv.contentView
        let docFrame = doc.frame
        switch axis {
        case .horizontal:
            return (docFrame.minX, max(docFrame.minX, docFrame.maxX - clip.bounds.width), clip.bounds.origin.x)
        case .vertical:
            return (docFrame.minY, max(docFrame.minY, docFrame.maxY - clip.bounds.height), clip.bounds.origin.y)
        }
    }

    /// False when this view can't move on its axis (let an outer scroll view have the tick).
    private func scroll(_ e: Entry, _ event: NSEvent) -> Bool {
        guard let sv = e.scrollView, let b = bounds(sv, e.axis), b.upper - b.lower > 0.5 else { return false }
        let flipped = sv.documentView?.isFlipped ?? true
        let d = WheelMapping.delta(axis: e.axis, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, flipped: flipped)
        guard d != 0 else { return false }
        // Start from where the view really is if we're idle or someone else (keyboard scrollTo) moved it.
        let gliding = e.model != nil && abs(b.current - e.lastSet) <= 1
        var m = gliding ? e.model! : EasedScroll(position: b.current, lower: b.lower, upper: b.upper)
        if gliding { m.rebound(lower: b.lower, upper: b.upper) }
        let before = m.target
        m.add(d)
        // Already pinned at this edge and idle: let an outer scroll view (or AppKit) have the tick.
        if m.target == before && !gliding { return false }
        if !gliding { e.lastSet = b.current }   // baseline for drift checks: fast ticks before the first frame accumulate
        e.model = m
        if Motion.reduce {
            if let t = e.model?.target { e.model?.position = t; apply(e, t) }
            stop(e)
            return true
        }
        if e.link == nil {
            let link = sv.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            e.link = link
            e.lastTime = 0
        }
        return true
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let e = entries.values.first(where: { $0.link === link }) else { link.invalidate(); return }
        guard let sv = e.scrollView, var m = e.model, let b = bounds(sv, e.axis) else { stop(e); return }
        // Someone else scrolled (keyboard selection, a trackpad): yield to them.
        if abs(b.current - e.lastSet) > 1, e.lastTime != 0 { stop(e); return }
        let now = link.timestamp
        let dt = e.lastTime == 0 ? CGFloat(1.0 / 60.0) : CGFloat(now - e.lastTime)
        e.lastTime = now
        m.rebound(lower: b.lower, upper: b.upper)
        let moving = m.step(dt)
        e.model = m
        apply(e, m.position)
        if !moving { stop(e) }
    }

    private func apply(_ e: Entry, _ value: CGFloat) {
        guard let sv = e.scrollView else { return }
        let clip = sv.contentView
        var origin = clip.bounds.origin
        let v = value.rounded(toPlaces: sv.window?.backingScaleFactor ?? 2)
        switch e.axis {
        case .horizontal: origin.x = v
        case .vertical: origin.y = v
        }
        clip.scroll(to: origin)
        sv.reflectScrolledClipView(clip)
        e.lastSet = e.axis == .horizontal ? clip.bounds.origin.x : clip.bounds.origin.y
    }

    private func stop(_ e: Entry) {
        e.link?.invalidate()
        e.link = nil
        e.lastTime = 0
        e.model = nil
    }
}

extension SmoothWheel {
    /// Dev-only (PERCH_DEBUG_SHOW=wheeltest): feed synthetic wheel ticks to the strip's card scroller and log
    /// the offset as it glides, since scripts can't drive a real mouse wheel.
    func debugSelfTest(in window: NSWindow) {
        guard let e = entries.values.first(where: { $0.axis == .horizontal && $0.scrollView?.window === window }),
              let sv = e.scrollView else { NSLog("ShakeBoard wheeltest: no horizontal scroll view registered in the strip"); return }
        let mid = sv.convert(NSPoint(x: sv.bounds.midX, y: sv.bounds.midY), to: nil)
        NSLog("ShakeBoard wheeltest: sv=%@ frame=%@ doc=%@ docFrame=%@ clip=%@ subviews=%@", String(describing: type(of: sv)),
              NSStringFromRect(sv.frame), String(describing: sv.documentView.map { type(of: $0) }),
              NSStringFromRect(sv.documentView?.frame ?? .zero), NSStringFromRect(sv.contentView.bounds),
              sv.contentView.subviews.map { "\(type(of: $0)) \(NSStringFromRect($0.frame))" }.joined(separator: ", "))
        func send(_ lines: Int32) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0),
                  let ev = NSEvent(cgEvent: cg) else { return }
            let consumed = handle(ev, window: window, at: mid) == nil
            NSLog("ShakeBoard wheeltest: tick %d precise=%d consumed=%d", lines, ev.hasPreciseScrollingDeltas ? 1 : 0, consumed ? 1 : 0)
        }
        let t0 = CACurrentMediaTime()
        func log() { NSLog("ShakeBoard wheeltest: t=%3.0f ms x=%.1f max=%.1f", (CACurrentMediaTime() - t0) * 1000,
                           sv.contentView.bounds.origin.x, (sv.documentView?.frame.width ?? 0) - sv.contentView.bounds.width) }
        log()
        send(-3); send(-3)
        for ms in [16, 50, 100, 150, 200, 300, 500] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { log() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(700)) {
            send(2)
            for ms in [50, 150, 400] { DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { log() } }
        }
    }
}

private extension CGFloat {
    /// Round to the device pixel grid so text doesn't shimmer mid-glide.
    func rounded(toPlaces scale: CGFloat) -> CGFloat { (self * scale).rounded() / scale }
}

// MARK: - SwiftUI hook

/// Put inside a ScrollView's content: `.background(SmoothWheelAnchor(axis: .horizontal))`.
struct SmoothWheelAnchor: NSViewRepresentable {
    let axis: Axis
    func makeNSView(context: Context) -> AnchorView { AnchorView(axis: axis) }
    func updateNSView(_ v: AnchorView, context: Context) { v.registerIfPossible() }

    final class AnchorView: NSView {
        let axis: Axis
        init(axis: Axis) { self.axis = axis; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never steals clicks or drags
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); registerIfPossible() }
        func registerIfPossible() {
            guard window != nil, let sv = enclosingScrollView else { return }
            MainActor.assumeIsolated { SmoothWheel.shared.register(sv, axis: axis) }
        }
    }
}

extension View {
    /// Eased mouse-wheel scrolling for the enclosing ScrollView (apply to the ScrollView's content).
    func smoothWheel(_ axis: Axis) -> some View { background(SmoothWheelAnchor(axis: axis)) }
}

// MARK: - Shake opens, shake closes

/// A strip that a shake revealed can be closed by another shake. Only shake-opened strips (Command-Space and
/// copy reveals keep their rules); never mid-drag (a shake while dragging is the "show me the shelf" gesture,
/// so it keeps the strip up); never while it's in deliberate use (summoned for an edit) -- and not within
/// `cooldown` of the opening shake, so the tail of one long shake doesn't open and close it.
struct ShakeToggle: Equatable {
    enum Action: Equatable { case reveal, close, ignore }
    static let cooldown: TimeInterval = 1.0

    private(set) var openedByShake = false
    private var lastChange: TimeInterval = -.infinity

    mutating func shake(at now: TimeInterval, shown: Bool, dragging: Bool, inUse: Bool) -> Action {
        if now - lastChange < Self.cooldown { return .ignore }
        if !shown {
            openedByShake = true
            lastChange = now
            return .reveal
        }
        if dragging || inUse || !openedByShake { return .reveal }   // existing behavior: keep it up
        openedByShake = false
        lastChange = now
        return .close
    }

    /// The strip hid for any reason, or was summoned / revealed by something other than a shake.
    mutating func reset() { openedByShake = false }

    /// While true, a plain (non-dragging) mouse shake should be fed to the detector even with an empty shelf.
    var canCloseByShake: Bool { openedByShake }
}
