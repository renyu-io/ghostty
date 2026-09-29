import AppKit

/// The window for `macos-titlebar-style = zen`.
///
/// Inspired by the Zen browser, this window keeps the titlebar hidden and only
/// reveals it while the mouse is at the top edge of the window. The native tab bar
/// is never shown; tabs are instead displayed in a vertical sidebar (see
/// ``ZenTerminalView``). Tabs are still native macOS window tabs under the hood so
/// all existing tab behaviors (new tab, goto tab, move tab, restoration) continue
/// to work.
class ZenTerminalWindow: TerminalWindow {
    /// The distance from the top of the window (in points) that the mouse must be
    /// within to reveal the titlebar.
    private static let revealTriggerHeight: CGFloat = 8

    /// Extra space below the titlebar that the mouse can move within before
    /// the titlebar is hidden again.
    private static let hideMargin: CGFloat = 12

    /// Delay before hiding the titlebar after the mouse leaves it.
    private static let hideDelay: TimeInterval = 0.35

    /// Duration of the fade in/out animation.
    private static let animationDuration: TimeInterval = 0.18

    /// The titlebar is hidden most of the time, so the update notification is shown
    /// in the terminal view instead.
    override var supportsUpdateAccessory: Bool { false }

    /// The vertical tab sidebar model, notified of mouse movement so it can
    /// reveal itself on hover.
    weak var zenTabs: ZenTabsModel?

    /// True while the titlebar is revealed.
    private(set) var isTitlebarRevealed: Bool = false

    /// Pending work to hide the titlebar.
    private var hideWorkItem: DispatchWorkItem?

    /// The tracking area used to detect the mouse near the top edge.
    private var hoverTrackingArea: NSTrackingArea?

    /// The view that `hoverTrackingArea` is installed on.
    private weak var hoverTrackingView: NSView?

    /// The object that receives tracking area events. This is separate from the
    /// window so that we don't interfere with the window's own responder behavior.
    private lazy var hoverTracker = HoverTracker(window: self)

    /// True if we are in any fullscreen mode. In fullscreen, macOS (native) or our
    /// fullscreen implementation (non-native) manages the titlebar so we stay out
    /// of the way.
    private var isFullscreen: Bool {
        styleMask.contains(.fullScreen) ||
            (terminalController?.fullscreenStyle?.isFullscreen ?? false)
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        // Extend content into the titlebar area so that the terminal and tab
        // sidebar fill the entire window. The titlebar overlays the content when
        // it is revealed. We keep an opaque titlebar background so the title and
        // window buttons remain readable over terminal content.
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = false
        titleVisibility = .visible

        installHoverTracking()
        applyTitlebarVisibility(animated: false)

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowWillEnterFullScreen(_:)),
            name: NSWindow.willEnterFullScreenNotification,
            object: self)
        center.addObserver(
            self,
            selector: #selector(fullscreenDidChange(_:)),
            name: .fullscreenDidEnter,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(fullscreenDidChange(_:)),
            name: .fullscreenDidExit,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: NSWindow

    override var title: String {
        didSet {
            // Setting the title can cause AppKit to reveal the titlebar views again.
            applyTitlebarVisibility(animated: false)
        }
    }

    override func tabStateDidChange() {
        NotificationCenter.default.post(name: .ghosttyZenTabsDidChange, object: self)
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)

        // We never show the native tab bar. Tabs are shown in our sidebar.
        if isTabBar(childViewController) {
            childViewController.isHidden = true
        }
    }

    override func becomeMain() {
        super.becomeMain()
        hideNativeTabBar()
        applyTitlebarVisibility(animated: false)
    }

    override func resignKey() {
        super.resignKey()

        // If we lose focus while the titlebar is revealed (i.e. the user clicked
        // into another window from our titlebar) then we hide it.
        if isTitlebarRevealed { scheduleHide() }
    }

    // MARK: Native Tab Bar

    private func hideNativeTabBar() {
        for controller in titlebarAccessoryViewControllers where isTabBar(controller) {
            if !controller.isHidden { controller.isHidden = true }
        }
    }

    // MARK: Titlebar Reveal

    /// The height of the titlebar area, used to determine when the mouse has left it.
    private var titlebarHeight: CGFloat {
        let height = frame.height - contentLayoutRect.height
        return max(height, 28)
    }

    fileprivate func mouseDidMove(to locationInWindow: NSPoint) {
        zenTabs?.mouseDidMove(to: locationInWindow, windowWidth: frame.width)

        guard !isFullscreen, styleMask.contains(.titled) else { return }

        let distanceFromTop = frame.height - locationInWindow.y
        if distanceFromTop <= Self.revealTriggerHeight {
            revealTitlebar()
        } else if distanceFromTop > titlebarHeight + Self.hideMargin {
            if isTitlebarRevealed { scheduleHide() }
        } else if isTitlebarRevealed {
            // Within the titlebar area, keep it visible.
            cancelHide()
        }
    }

    fileprivate func mouseDidExit() {
        zenTabs?.mouseDidExit()
        guard isTitlebarRevealed else { return }
        scheduleHide()
    }

    private func revealTitlebar() {
        cancelHide()
        guard !isTitlebarRevealed else { return }
        isTitlebarRevealed = true
        applyTitlebarVisibility(animated: true)
    }

    private func scheduleHide() {
        guard hideWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWorkItem = nil

            // Don't hide while a mouse button is held down, e.g. when the user is
            // dragging the window by its titlebar.
            if NSEvent.pressedMouseButtons != 0 {
                self.scheduleHide()
                return
            }

            self.isTitlebarRevealed = false
            self.applyTitlebarVisibility(animated: true)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: workItem)
    }

    private func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    /// The views that make up the titlebar that we show and hide.
    private var titlebarViews: [NSView] {
        guard let themeFrame = contentView?.superview else { return [] }
        var views: [NSView] = []
        if let container = themeFrame.firstDescendant(withClassName: "NSTitlebarContainerView") {
            views.append(container)
        }

        // On newer macOS versions AppKit may move `NSScrollPocket` into the titlebar,
        // which draws a background over the top of our terminal. It must follow the
        // titlebar visibility. See HiddenTitlebarTerminalWindow.
        if let scrollPocket = themeFrame.firstDescendant(withClassName: "NSScrollPocket") {
            views.append(scrollPocket)
        }

        return views
    }

    /// Show or hide the titlebar based on `isTitlebarRevealed`.
    private func applyTitlebarVisibility(animated: Bool) {
        // In fullscreen the titlebar is managed by the system. We make sure
        // everything is visible so that the native fullscreen titlebar works.
        let visible = isTitlebarRevealed || isFullscreen
        let views = titlebarViews
        guard !views.isEmpty else { return }

        if visible {
            for view in views {
                view.isHidden = false
                if !animated { view.alphaValue = 1 }
            }

            guard animated else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.animationDuration
                for view in views { view.animator().alphaValue = 1 }
            }
            return
        }

        guard animated else {
            for view in views {
                view.alphaValue = 0
                view.isHidden = true
            }
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.animationDuration
            for view in views { view.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            // Hide the views entirely so that they don't intercept mouse
            // events (e.g. text selection at the top of the terminal).
            // We check again in case we were revealed during the animation.
            guard let self, !self.isTitlebarRevealed, !self.isFullscreen else { return }
            for view in views { view.isHidden = true }
        })
    }

    private func installHoverTracking() {
        // We prefer the theme frame because it covers the whole window
        // (including the titlebar) and survives content view changes.
        guard let trackingView = contentView?.superview ?? contentView else { return }
        if let hoverTrackingArea {
            hoverTrackingView?.removeTrackingArea(hoverTrackingArea)
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: hoverTracker,
            userInfo: nil)
        trackingView.addTrackingArea(area)
        hoverTrackingArea = area
        hoverTrackingView = trackingView
    }

    // MARK: Notifications

    @objc private func windowWillEnterFullScreen(_ notification: Notification) {
        // The titlebar views are moved into a separate fullscreen window by AppKit,
        // so they must be visible before we enter fullscreen.
        cancelHide()
        isTitlebarRevealed = false
        for view in titlebarViews {
            view.isHidden = false
            view.alphaValue = 1
        }
    }

    @objc private func fullscreenDidChange(_ notification: Notification) {
        guard let fullscreen = notification.object as? FullscreenBase else { return }
        guard fullscreen.window == self else { return }

        // Our fullscreen state changed so reapply our titlebar and tab bar
        // visibility since AppKit tends to reset these.
        hideNativeTabBar()
        applyTitlebarVisibility(animated: false)
    }
}

/// Receives tracking area events on behalf of a ``ZenTerminalWindow``.
private class HoverTracker: NSResponder {
    private weak var window: ZenTerminalWindow?

    init(window: ZenTerminalWindow) {
        self.window = window
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseMoved(with event: NSEvent) {
        window?.mouseDidMove(to: event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        window?.mouseDidMove(to: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        window?.mouseDidExit()
    }
}
