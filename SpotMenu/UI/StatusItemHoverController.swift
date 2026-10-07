import AppKit

/// Opens the playback panel when the mouse hovers the menu bar item, and
/// closes it once the mouse has left both the menu bar item and the panel.
///
/// - Opening waits a moment so sweeping across the menu bar doesn't flash it.
/// - Closing waits a moment too, so moving the mouse down from the menu bar
///   into the panel (or briefly overshooting its edge) doesn't close it.
final class StatusItemHoverController: NSResponder {
    private weak var button: NSStatusBarButton?
    private let popoverManager: PopoverManager
    private let isEnabled: () -> Bool

    var openDelay: TimeInterval = 0.15
    var closeDelay: TimeInterval = 0.35

    private var trackingArea: NSTrackingArea?
    private var pendingOpen: DispatchWorkItem?
    private var pollTimer: Timer?
    private var outsideSince: Date?

    init(
        button: NSStatusBarButton,
        popoverManager: PopoverManager,
        isEnabled: @escaping () -> Bool
    ) {
        self.button = button
        self.popoverManager = popoverManager
        self.isEnabled = isEnabled
        super.init()
        installTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopWatching()
        if let area = trackingArea { button?.removeTrackingArea(area) }
    }

    private func installTrackingArea() {
        guard let button else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Tracking events

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled() else { return }
        outsideSince = nil
        guard !popoverManager.isVisible else { return }

        pendingOpen?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.open() }
        pendingOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + openDelay, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        // Left before the open delay finished: don't open.
        pendingOpen?.cancel()
        pendingOpen = nil
    }

    // MARK: - Open / close

    private func open() {
        pendingOpen = nil
        guard let button, isEnabled(), isMouseInside(includePanel: false) else { return }
        popoverManager.show(relativeTo: button)
        startWatching()
    }

    private func startWatching() {
        pollTimer?.invalidate()
        outsideSince = nil
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.checkMouse()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
        outsideSince = nil
    }

    private func checkMouse() {
        // Closed some other way (click, outside click, right-click menu).
        guard popoverManager.isVisible else {
            stopWatching()
            return
        }

        if isMouseInside(includePanel: true) {
            outsideSince = nil
            return
        }

        if let since = outsideSince {
            if Date().timeIntervalSince(since) >= closeDelay {
                popoverManager.dismiss()
                stopWatching()
            }
        } else {
            outsideSince = Date()
        }
    }

    private func isMouseInside(includePanel: Bool) -> Bool {
        let point = NSEvent.mouseLocation

        if let button, let window = button.window {
            let buttonFrame = window.convertToScreen(
                button.convert(button.bounds, to: nil)
            )
            if buttonFrame.insetBy(dx: -2, dy: -2).contains(point) { return true }
        }

        if includePanel,
            popoverManager.frame.insetBy(dx: -6, dy: -6).contains(point)
        {
            return true
        }

        return false
    }
}
