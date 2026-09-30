import AppKit
import Combine
import SwiftUI

private struct ContentInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

extension EnvironmentValues {
    /// Space that ``TerminalView`` leaves around the terminal when its content
    /// extends into the titlebar area (see ``ZenTerminalWindow``).
    var ghosttyContentInsets: EdgeInsets {
        get { self[ContentInsetsKey.self] }
        set { self[ContentInsetsKey.self] = newValue }
    }
}

extension Notification.Name {
    /// Posted when something about a terminal tab changes that should be reflected
    /// in the zen tab sidebar (title, color, order, selection, etc.).
    static let ghosttyZenTabsDidChange = Notification.Name("com.mitchellh.ghostty.zenTabsDidChange")
}

/// App-wide layout state for the zen tab sidebar. This is shared by all windows
/// so that moving or resizing the sidebar in one window applies to all of them.
final class ZenSidebarSettings: ObservableObject {
    static let shared = ZenSidebarSettings()

    /// The allowed range for the sidebar width.
    static let widthRange: ClosedRange<CGFloat> = 140...420

    /// The side of the window that the sidebar is on.
    @Published var position: Ghostty.Config.MacOSZenTabPosition

    /// Whether the sidebar is always visible or only visible on hover.
    @Published var visibility: Ghostty.Config.MacOSZenTabVisibility

    /// The width of the sidebar. This is remembered across launches, see ``saveWidth()``.
    @Published var width: CGFloat

    /// The UserDefaults key used to remember the sidebar width.
    private static let widthDefaultsKey = "ZenSidebarWidth"

    private static let defaultWidth: CGFloat = 220

    private init() {
        let config = (NSApp.delegate as? AppDelegate)?.ghostty.config
        position = config?.macosZenTabPosition ?? .left
        visibility = config?.macosZenTabVisibility ?? .hover

        let savedWidth = CGFloat(UserDefaults.ghostty.double(forKey: Self.widthDefaultsKey))
        width = savedWidth > 0
            ? min(max(savedWidth, Self.widthRange.lowerBound), Self.widthRange.upperBound)
            : Self.defaultWidth
    }

    /// Remember the current width for future launches.
    func saveWidth() {
        UserDefaults.ghostty.set(Double(width), forKey: Self.widthDefaultsKey)
    }

    /// Update our state from a (reloaded) configuration.
    func update(from config: Ghostty.Config) {
        let newPosition = config.macosZenTabPosition
        if position != newPosition { position = newPosition }
        let newVisibility = config.macosZenTabVisibility
        if visibility != newVisibility { visibility = newVisibility }
    }

    /// Toggle between an always visible sidebar and a sidebar shown on hover.
    func toggleVisibility() {
        visibility = visibility == .always ? .hover : .always
    }
}

/// The list of tabs in the tab group of a single window. Tabs are native macOS
/// window tabs so this model mirrors the state of the window's `NSWindowTabGroup`.
final class ZenTabsModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier
        weak var window: NSWindow?
        let title: String
        let color: TerminalTabColor
        let keyEquivalent: String?
        let isSelected: Bool
        let isZoomed: Bool

        static func == (lhs: Tab, rhs: Tab) -> Bool {
            lhs.id == rhs.id &&
                lhs.title == rhs.title &&
                lhs.color == rhs.color &&
                lhs.keyEquivalent == rhs.keyEquivalent &&
                lhs.isSelected == rhs.isSelected &&
                lhs.isZoomed == rhs.isZoomed
        }
    }

    @Published private(set) var tabs: [Tab] = []

    /// The space above and below the terminal so the window's rounded corners
    /// don't clip it.
    /// This is managed by ``ZenTerminalWindow``.
    @Published var contentInsets = EdgeInsets()

    /// True while the sidebar is revealed with `macos-zen-tab-visibility = hover`.
    @Published private(set) var isRevealed: Bool = false

    /// The distance from the sidebar's window edge (in points) that the mouse
    /// must be within to reveal the sidebar.
    private static let revealTriggerWidth: CGFloat = 6

    /// Extra space beyond the sidebar that the mouse can move within before
    /// the sidebar is hidden again.
    private static let hideMargin: CGFloat = 16

    /// Delay before hiding the sidebar after the mouse leaves it.
    private static let hideDelay: TimeInterval = 0.3

    /// Pending work to hide the sidebar.
    private var hideWorkItem: DispatchWorkItem?

    /// The window that owns this sidebar.
    weak var window: NSWindow? {
        didSet { refresh() }
    }

    private var cancellables: Set<AnyCancellable> = []
    private var refreshScheduled: Bool = false

    init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .ghosttyZenTabsDidChange,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
        ]

        for name in names {
            center.publisher(for: name)
                .sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &cancellables)
        }

        // Switching visibility modes always starts with a hidden hover sidebar.
        ZenSidebarSettings.shared.$visibility
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.cancelHide()
                self?.isRevealed = false
            }
            .store(in: &cancellables)
    }

    // MARK: Hover

    /// Called by the window when the mouse moves anywhere within it.
    func mouseDidMove(to locationInWindow: NSPoint, windowWidth: CGFloat) {
        let settings = ZenSidebarSettings.shared
        guard settings.visibility == .hover else { return }

        let distanceFromEdge = settings.position == .left
            ? locationInWindow.x
            : windowWidth - locationInWindow.x
        if distanceFromEdge <= Self.revealTriggerWidth {
            reveal()
        } else if distanceFromEdge > settings.width + Self.hideMargin {
            if isRevealed { scheduleHide() }
        } else if isRevealed {
            // Within the sidebar, keep it visible.
            cancelHide()
        }
    }

    /// Called by the window when the mouse leaves it.
    func mouseDidExit() {
        if isRevealed { scheduleHide() }
    }

    private func reveal() {
        cancelHide()
        if !isRevealed { isRevealed = true }
    }

    private func scheduleHide() {
        guard hideWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWorkItem = nil

            // Don't hide while a mouse button is held down, e.g. when the user
            // is resizing the sidebar.
            if NSEvent.pressedMouseButtons != 0 {
                self.scheduleHide()
                return
            }

            self.isRevealed = false
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: workItem)
    }

    private func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    /// Coalesce refreshes so that bursts of changes (i.e. rapid title updates)
    /// only result in a single refresh. This also runs the refresh after AppKit
    /// has finished updating the tab group state (i.e. when a window closes).
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        guard let window else {
            if !tabs.isEmpty { tabs = [] }
            return
        }

        let tabGroup = window.tabGroup
        let windows = tabGroup?.windows ?? [window]
        let selected = tabGroup?.selectedWindow ?? window
        let newTabs: [Tab] = windows.map { tabWindow in
            let terminalWindow = tabWindow as? TerminalWindow
            return Tab(
                id: ObjectIdentifier(tabWindow),
                window: tabWindow,
                title: tabWindow.title.isEmpty ? "Terminal" : tabWindow.title,
                color: terminalWindow?.tabColor ?? .none,
                keyEquivalent: terminalWindow?.keyEquivalent,
                isSelected: tabWindow === selected,
                isZoomed: terminalWindow?.surfaceIsZoomed ?? false)
        }

        if newTabs != tabs { tabs = newTabs }
    }

    // MARK: Actions

    func select(_ tab: Tab) {
        guard let tabWindow = tab.window else { return }
        tabWindow.makeKeyAndOrderFront(nil)

        // Clicking the sidebar may have taken focus away from the terminal so
        // we always restore it to the focused surface of the selected tab.
        if let controller = tabWindow.windowController as? BaseTerminalController,
           let surface = controller.focusedSurface {
            tabWindow.makeFirstResponder(surface)
        }
    }

    func close(_ tab: Tab) {
        controller(for: tab)?.closeTab(nil)
    }

    func closeOthers(_ tab: Tab) {
        controller(for: tab)?.closeOtherTabs(nil)
    }

    func rename(_ tab: Tab) {
        controller(for: tab)?.promptTabTitle()
    }

    func setColor(_ color: TerminalTabColor, for tab: Tab) {
        (tab.window as? TerminalWindow)?.tabColor = color
    }

    func newTab() {
        (window?.windowController as? TerminalController)?.newTab(nil)
    }

    func canMove(_ tab: Tab, by amount: Int) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        return tabs.indices.contains(index + amount)
    }

    /// Move a tab up (negative) or down (positive) in the tab group.
    func move(_ tab: Tab, by amount: Int) {
        guard let tabWindow = tab.window,
              let index = tabWindow.tabGroup?.windows.firstIndex(of: tabWindow) else { return }
        move(tab, to: index + amount)
    }

    /// Move a tab to the given index in the tab group.
    func move(_ tab: Tab, to finalIndex: Int) {
        guard let tabWindow = tab.window,
              let tabGroup = tabWindow.tabGroup,
              let index = tabGroup.windows.firstIndex(of: tabWindow) else { return }
        guard finalIndex != index, tabGroup.windows.indices.contains(finalIndex) else { return }

        let wasSelected = tabGroup.selectedWindow === tabWindow
        let targetWindow = tabGroup.windows[finalIndex]

        // Remove the window and add it back next to the window currently at the
        // destination: after it when moving down, before it when moving up.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tabGroup.removeWindow(tabWindow)
        targetWindow.addTabbedWindowSafely(tabWindow, ordered: finalIndex > index ? .above : .below)
        if wasSelected { tabWindow.makeKey() }
        NSAnimationContext.endGrouping()

        (tabWindow.windowController as? TerminalController)?.relabelTabs()

        // Refresh immediately so the sidebar doesn't briefly show the old order
        // (e.g. when a drag ends).
        refresh()
    }

    private func controller(for tab: Tab) -> TerminalController? {
        tab.window?.windowController as? TerminalController
    }
}

/// The root view for a zen-style terminal window: the terminal content with a
/// vertical tab sidebar on the configured side.
struct ZenTerminalView<Content: View>: View {
    @ObservedObject var tabs: ZenTabsModel
    @ObservedObject var settings: ZenSidebarSettings = .shared
    let content: Content

    init(tabs: ZenTabsModel, @ViewBuilder content: () -> Content) {
        self.tabs = tabs
        self.content = content()
    }

    private var sidebarEdge: Edge {
        settings.position == .left ? .leading : .trailing
    }

    var body: some View {
        // NOTE: the structure here is important. The content must always be at the
        // same position in the view hierarchy so that SwiftUI doesn't recreate our
        // terminal surfaces when the sidebar position or visibility changes.
        ZStack(alignment: settings.position == .left ? .topLeading : .topTrailing) {
            HStack(spacing: 0) {
                if settings.visibility == .always && settings.position == .left {
                    ZenTabSidebar(model: tabs, settings: settings)
                }

                content
                    .environment(\.ghosttyContentInsets, tabs.contentInsets)

                if settings.visibility == .always && settings.position == .right {
                    ZenTabSidebar(model: tabs, settings: settings)
                }
            }

            // In hover mode the sidebar floats above the terminal so that the
            // terminal isn't resized (and reflowed) every time it is shown.
            if settings.visibility == .hover && tabs.isRevealed {
                ZenTabSidebar(model: tabs, settings: settings, isFloating: true)
                    .transition(.move(edge: sidebarEdge).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.18), value: tabs.isRevealed)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// The vertical list of tabs.
private struct ZenTabSidebar: View {
    @ObservedObject var model: ZenTabsModel
    @ObservedObject var settings: ZenSidebarSettings

    /// True if the sidebar floats above the terminal (hover mode).
    var isFloating: Bool = false

    /// The width at the start of a resize drag.
    @State private var dragStartWidth: CGFloat?

    /// The tab currently being dragged to reorder it.
    @State private var reorder: ReorderState?

    /// The height of a tab row plus the spacing between rows.
    private static let rowStride: CGFloat = ZenTabRow.height + rowSpacing
    private static let rowSpacing: CGFloat = 2

    /// The coordinate space of the tab list used for reorder drags.
    private static let listCoordinateSpace = "ZenTabList"

    private struct ReorderState {
        let id: ObjectIdentifier
        let startIndex: Int
        var translation: CGFloat
    }

    var body: some View {
        VStack(spacing: 0) {
            // Reserve room for the window buttons, which appear over the
            // sidebar when the titlebar is revealed.
            Color.clear.frame(height: settings.position == .left ? 32 : 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                        let isDragging = reorder?.id == tab.id
                        ZenTabRow(tab: tab, model: model, settings: settings)
                            .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 6, y: 2)
                            .offset(y: reorderOffset(for: index, tab: tab))
                            .zIndex(isDragging ? 1 : 0)
                            .gesture(reorderGesture(for: tab, at: index))
                    }

                    ZenNewTabRow(model: model)
                }
                .coordinateSpace(name: Self.listCoordinateSpace)
                .animation(.easeOut(duration: 0.15), value: reorderTargetIndex)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(width: settings.width)
        .frame(maxHeight: .infinity)
        .background(background)
        .overlay(alignment: settings.position == .left ? .trailing : .leading) {
            resizeHandle
        }
        .modifier(FloatingSidebarModifier(isFloating: isFloating))
        .contextMenu {
            ZenSidebarLayoutButtons(settings: settings)
        }
    }

    // MARK: Reordering

    /// The index the dragged tab would be dropped at.
    private var reorderTargetIndex: Int? {
        guard let reorder, !model.tabs.isEmpty else { return nil }
        let moved = Int((reorder.translation / Self.rowStride).rounded())
        return min(max(reorder.startIndex + moved, 0), model.tabs.count - 1)
    }

    /// The vertical offset of a row during a reorder drag. The dragged row follows
    /// the mouse and the rows between its start and target shift to make room.
    private func reorderOffset(for index: Int, tab: ZenTabsModel.Tab) -> CGFloat {
        guard let reorder, let target = reorderTargetIndex else { return 0 }
        if reorder.id == tab.id { return reorder.translation }

        let start = reorder.startIndex
        if start < target, index > start, index <= target { return -Self.rowStride }
        if target < start, index >= target, index < start { return Self.rowStride }
        return 0
    }

    private func reorderGesture(for tab: ZenTabsModel.Tab, at index: Int) -> some Gesture {
        // The minimum distance keeps clicks working to select tabs.
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.listCoordinateSpace))
            .onChanged { value in
                if reorder?.id != tab.id {
                    reorder = ReorderState(id: tab.id, startIndex: index, translation: 0)
                }
                reorder?.translation = value.translation.height
            }
            .onEnded { _ in
                let target = reorderTargetIndex

                // Clear the drag state without animation since the model is
                // reordered at the same time, so the rows are already in place.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    reorder = nil
                    if let target { model.move(tab, to: target) }
                }
            }
    }

    private var background: AnyShapeStyle {
        if isFloating {
            // Floating over terminal content, so we need a real background.
            return AnyShapeStyle(.regularMaterial)
        }

        return AnyShapeStyle(Color.primary.opacity(0.04))
    }

    /// An invisible handle on the inner edge of the sidebar used to resize it.
    private var resizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
        }
        .frame(width: 6)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? settings.width
                    if dragStartWidth == nil { dragStartWidth = start }

                    // Dragging towards the terminal content grows the sidebar.
                    let delta = settings.position == .left
                        ? value.translation.width
                        : -value.translation.width
                    let range = ZenSidebarSettings.widthRange
                    settings.width = min(max(start + delta, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                    settings.saveWidth()
                }
        )
    }
}

/// A single tab in the sidebar.
private struct ZenTabRow: View {
    static let height: CGFloat = 30

    let tab: ZenTabsModel.Tab
    @ObservedObject var model: ZenTabsModel
    @ObservedObject var settings: ZenSidebarSettings

    @State private var isHovering: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if let color = tab.color.displayColor {
                Circle()
                    .fill(Color(color))
                    .frame(width: 7, height: 7)
            }

            Text(tab.title)
                .font(.system(size: 12, weight: tab.isSelected ? .medium : .regular))
                .foregroundColor(tab.isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if tab.isZoomed {
                Image("ResetZoom")
                    .foregroundColor(.accentColor)
                    .help("Split Zoomed")
            }

            if isHovering {
                Button {
                    model.close(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Tab")
            } else if let keyEquivalent = tab.keyEquivalent, !keyEquivalent.isEmpty {
                Text(keyEquivalent)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { model.select(tab) }
        .help(tab.title)
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tab.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var backgroundColor: Color {
        if tab.isSelected { return Color.primary.opacity(0.14) }
        if isHovering { return Color.primary.opacity(0.07) }
        return .clear
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("New Tab") { model.newTab() }
        Divider()
        Button("Rename Tab...") { model.rename(tab) }
        Menu("Tab Color") {
            ForEach(TerminalTabColor.allCases, id: \.self) { color in
                Button {
                    model.setColor(color, for: tab)
                } label: {
                    if color == tab.color {
                        Label(color.localizedName, systemImage: "checkmark")
                    } else {
                        Text(color.localizedName)
                    }
                }
            }
        }
        Divider()
        Button("Move Tab Up") { model.move(tab, by: -1) }
            .disabled(!model.canMove(tab, by: -1))
        Button("Move Tab Down") { model.move(tab, by: 1) }
            .disabled(!model.canMove(tab, by: 1))
        Divider()
        Button("Close Tab") { model.close(tab) }
        Button("Close Other Tabs") { model.closeOthers(tab) }
            .disabled(model.tabs.count <= 1)
        Divider()
        ZenSidebarLayoutButtons(settings: settings)
    }
}

/// Styles a sidebar that floats above the terminal content.
private struct FloatingSidebarModifier: ViewModifier {
    let isFloating: Bool

    func body(content: Content) -> some View {
        if isFloating {
            content
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 12)
                .padding(6)
        } else {
            content
        }
    }
}

/// The "+ New Tab" row at the end of the tab list.
private struct ZenNewTabRow: View {
    @ObservedObject var model: ZenTabsModel

    @State private var isHovering: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
            Text("New Tab")
                .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { model.newTab() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Context menu buttons that change the sidebar side and visibility.
private struct ZenSidebarLayoutButtons: View {
    @ObservedObject var settings: ZenSidebarSettings

    var body: some View {
        switch settings.position {
        case .left:
            Button("Move Tabs to Right") { settings.position = .right }
        case .right:
            Button("Move Tabs to Left") { settings.position = .left }
        }

        switch settings.visibility {
        case .always:
            Button("Show Tabs on Hover") { settings.visibility = .hover }
        case .hover:
            Button("Always Show Tabs") { settings.visibility = .always }
        }
    }
}
