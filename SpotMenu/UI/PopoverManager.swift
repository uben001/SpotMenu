import SwiftUI

class PopoverManager {
    private var window: PopoverWindow
    private var isDismissing = false
    // Bumped on every show/dismiss so a stale fade-out completion can't hide
    // a panel that was re-shown mid-animation (happens a lot with hover).
    private var generation = 0

    init<Content: View>(contentView: Content) {
        self.window = PopoverWindow(rootView: contentView)
    }

    var isVisible: Bool { window.isVisible && !isDismissing }

    var frame: NSRect { window.frame }

    func toggle(relativeTo button: NSStatusBarButton?) {
        guard let button = button else { return }

        if isVisible {
            dismiss()
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window,
            let screen = buttonWindow.screen
        else { return }

        generation += 1
        let wasFadingOut = window.isVisible && isDismissing
        isDismissing = false

        let buttonFrame = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )

        if let fitting = window.contentView?.fittingSize,
            fitting.width > 0, fitting.height > 0,
            fitting != window.frame.size
        {
            window.setContentSize(fitting)
        }

        let popoverSize = window.frame.size

        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let spacingBelowMenuBar: CGFloat = 0
        let totalOffset = menuBarHeight + spacingBelowMenuBar

        let popoverY = screen.frame.maxY - totalOffset - popoverSize.height
        let popoverX = buttonFrame.midX - popoverSize.width / 2

        window.setFrameOrigin(NSPoint(x: popoverX, y: popoverY))
        if !wasFadingOut {
            window.alphaValue = 0
        }
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard window.isVisible, !isDismissing else { return }
        isDismissing = true
        generation += 1
        let token = generation

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        } completionHandler: {
            guard token == self.generation else { return }
            self.window.orderOut(nil)
            self.window.alphaValue = 1
            self.isDismissing = false
        }
    }
}
