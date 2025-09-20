// UIViews.swift
//
// Summary: Shared macOS SwiftUI/AppKit bridge views and window controller for the clipboard history UI.
// - Keyboard handling via a representable NSView to intercept keyDown events
// - VisualEffectView wrapper for macOS materials
// - Shared root container for panel content
// - Custom focus-ringless NSTextField bridge
// - ContentView listing clipboard history with hover/keyboard interaction
// - ClipRow presentation and interactions
// - HistoryWindowController to show/close the non-activating floating panel

import SwiftUI
import AppKit
import Foundation
import Combine

// MARK: - KeyDown Handling View

/// A lightweight NSViewRepresentable that installs a local keyDown monitor while present in the view hierarchy.
///
/// This view:
/// - Adds a local monitor for `.keyDown` events in `makeNSView` and forwards them to `onKeyDown`.
/// - Removes the monitor in `dismantleNSView` to avoid leaks.
/// - Can be used via the `View.onKeyDown(_:)` modifier provided below.
struct KeyDownHandlingView: NSViewRepresentable {
    var onKeyDown: (NSEvent) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            onKeyDown(event)
            return event
        }
        context.coordinator.monitor = monitor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator { var monitor: Any? }
}

/// Convenience modifier to listen for keyDown events in a SwiftUI hierarchy.
/// - Parameter handler: Closure invoked for each intercepted `NSEvent` of type `.keyDown`.
/// - Returns: The modified view with an invisible background listener.
extension View {
    func onKeyDown(_ handler: @escaping (NSEvent) -> Void) -> some View {
        background(KeyDownHandlingView(onKeyDown: handler))
    }
}

// MARK: - Visual Effect Background

/// SwiftUI wrapper around `NSVisualEffectView` to render macOS materials with configurable blending and emphasis.
///
/// Use this to achieve blurred/transparent backgrounds consistent with system UI.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let isEmphasized: Bool

    init(material: NSVisualEffectView.Material = .hudWindow,
         blendingMode: NSVisualEffectView.BlendingMode = .withinWindow,
         isEmphasized: Bool = true) {
        self.material = material
        self.blendingMode = blendingMode
        self.isEmphasized = isEmphasized
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = isEmphasized
        view.wantsLayer = true
        view.layer?.cornerRadius = HistoryUI.cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.isEmphasized = isEmphasized
    }
}

// MARK: - Shared UI constants and container

/// Layout constants used throughout the clipboard history UI.
private enum HistoryUI {
    static let cornerRadius: CGFloat = 14
    static let panelWidth: CGFloat = 340
    static let panelHeight: CGFloat = 500
    static let contentWidth: CGFloat = 328 // inner list width
    static let contentHeight: CGFloat = 440

    static let outerPadding: CGFloat = 12
    static let innerHorizontal: CGFloat = 10
    static let innerVertical: CGFloat = 6
    static let rowCorner: CGFloat = 10
}

/// Root container used by both the menu bar window and the hotkey-triggered floating panel.
///
/// Provides the background material, rounded corners, subtle border, and embeds `ContentView`.
struct SharedHistoryRootView: View {
    let itemsVM: ItemsViewModel

    init(itemsVM: ItemsViewModel) {
        self.itemsVM = itemsVM
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Softer material for a cleaner look
            VisualEffectView(material: .sidebar, blendingMode: .withinWindow, isEmphasized: false)
                .clipShape(RoundedRectangle(cornerRadius: HistoryUI.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: HistoryUI.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 8)

            VStack(spacing: 0) {
                // Small grabber
                Capsule()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 32, height: 4)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                ContentView()
                    .environmentObject(itemsVM)
                    .padding(.horizontal, HistoryUI.innerHorizontal)
                    .padding(.bottom, HistoryUI.innerVertical)
            }
        }
        .padding(HistoryUI.outerPadding)
        .frame(width: HistoryUI.panelWidth, height: HistoryUI.panelHeight)
        .background(Color.clear)
    }
}

// MARK: - Focus ringless TextField (macOS)

/// An AppKit-backed text field without a visible focus ring, bridged into SwiftUI.
///
/// - Mirrors text changes back to the bound `text` using an `NSTextFieldDelegate`.
/// - Optionally requests first responder once when `isFocused` becomes true.
struct FocusRinglessTextField: NSViewRepresentable {
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusRinglessTextField
        init(_ parent: FocusRinglessTextField) { self.parent = parent }

        /// Syncs the NSTextField's current string back to the SwiftUI binding.
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }
    }

    var title: String
    @Binding var text: String
    var isFocused: Bool

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: text)
        tf.placeholderString = title
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        tf.delegate = context.coordinator
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != title {
            nsView.placeholderString = title
        }
        nsView.focusRingType = .none

        // Only become first responder once when requested and not already editing
        if isFocused,
           nsView.window != nil,
           nsView.currentEditor() == nil,
           nsView.acceptsFirstResponder {
            nsView.becomeFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
}

// MARK: - ContentView

/// Main content listing clipboard items with search, hover highlight, keyboard navigation, and actions.
///
/// Behavior:
/// - Filters items by `searchText`.
/// - Arrow keys move selection; Return copies; Escape clears or closes the panel.
/// - Hovering a row selects it for visual highlight.
/// - Selecting/copying/pasting closes the floating history window.
struct ContentView: View {
    @EnvironmentObject var itemsVM: ItemsViewModel
    @State private var searchText: String = ""
    @State private var selectedID: UUID? = nil
    @State private var copiedID: UUID? = nil
    @State private var hoverID: UUID? = nil
    @FocusState private var searchFocused: Bool

    @State private var visibleLimit: Int = 30
    private let maxVisible: Int = 200

    /// Items filtered by the current `searchText`. Returns all items when the query is empty.
    private var filteredItems: [ClipItem] {
        let base = itemsVM.items
        guard !searchText.isEmpty else { return base }
        return base.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    private var pinnedItems: [ClipItem] { filteredItems.filter { $0.pinned } }
    private var unpinnedItems: [ClipItem] { filteredItems.filter { !$0.pinned } }
    private var orderedItems: [ClipItem] { pinnedItems + unpinnedItems }

    private var displayItems: [ClipItem] {
        Array(orderedItems.prefix(min(visibleLimit, maxVisible)))
    }
    private var displayPinned: [ClipItem] { displayItems.filter { $0.pinned } }
    private var displayUnpinned: [ClipItem] { displayItems.filter { !$0.pinned } }

    @ViewBuilder
    private func rows(for items: [ClipItem]) -> some View {
        ForEach(items, id: \.id) { item in
            ClipRow(
                item: item,
                isSelected: selectedID == item.id,
                isCopied: copiedID == item.id
            )
            .contentShape(Rectangle())
            .onTapGesture { selectAndCopyByID(item.id) }
            .onHover { hovering in
                if hovering {
                    hoverID = item.id
                    selectedID = item.id
                } else if hoverID == item.id {
                    hoverID = nil
                    if selectedID == item.id { selectedID = nil }
                }
            }
            .contextMenu {
                Button(item.pinned ? "Unpin" : "Pin") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        itemsVM.togglePin(item.id)
                    }
                }
                Button("Copy") {
                    NSPasteboard.general.copyString(item.text)
                }
                Button("Paste") {
                    pasteItemByID(item.id)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    itemsVM.deleteItem(item.id)
                    if selectedID == item.id { selectedID = nil }
                }
            }
            .onAppear {
                if let last = displayItems.last, last.id == item.id {
                    let total = orderedItems.count
                    if visibleLimit < min(total, maxVisible) {
                        visibleLimit = min(visibleLimit + 30, min(total, maxVisible))
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .imageScale(.medium)
                    .foregroundStyle(.secondary)
                Text("Clipboard")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, HistoryUI.innerHorizontal)
            .padding(.top, 30)
            .padding(.bottom, 6)

            searchBar
                .padding(.horizontal, HistoryUI.innerHorizontal)
                .padding(.bottom, 8)

            Divider()
                .opacity(0.6)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if displayItems.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 6)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            // Pinned section
                            if !displayPinned.isEmpty {
                                rows(for: displayPinned)

                                // Divider between pinned and others
                                Divider()
                                    .opacity(0.6)
                                    .padding(.vertical, 2)
                            }

                            // Unpinned section
                            rows(for: displayUnpinned)
                        }
                        .padding(.horizontal, 7)
                        // Give extra bottom inset so the last item can scroll fully into view
                        .padding(.bottom, 56)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: "historyScroll")
            .frame(width: HistoryUI.contentWidth, height: HistoryUI.contentHeight)
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 8)
            }
            .transaction { txn in
                // Prevent implicit animations on bulk updates to avoid jitter
                txn.animation = nil
            }
            .onKeyDown(handleKeyEvent(_:))
        }
        .onAppear {
            // Defer focus slightly to ensure window is key and view is in hierarchy
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.searchFocused = true
            }
        }
        .onChange(of: searchText) { _ in
            visibleLimit = 30
        }
    }

    private func indexInFiltered(for id: UUID) -> Int? {
        filteredItems.firstIndex { $0.id == id }
    }

    private func selectAndCopyByID(_ id: UUID) {
        guard let idx = indexInFiltered(for: id) else { return }
        selectedID = id
        copyItem(at: idx)
        // HistoryWindowController.shared.close() // removed per instructions
    }

    private func pasteItemByID(_ id: UUID) {
        guard let idx = indexInFiltered(for: id) else { return }
        copiedID = id
        PasteHelper.paste(text: filteredItems[idx].text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [id] in
            if copiedID == id { copiedID = nil }
        }
        // HistoryWindowController.shared.close() // removed per instructions
    }

    /// Shown when no items match the current filter.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("No items found")
                .foregroundStyle(.secondary)
                .font(.footnote)
        }
        .padding(.vertical, 18)
    }

    /// Search field with clear button and a trailing "Clear" action to remove unpinned history.
    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                FocusRinglessTextField(title: "Search clipboard",
                                       text: $searchText,
                                       isFocused: searchFocused)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, HistoryUI.innerVertical)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.06))
            )

            Button(role: .destructive, action: { clearHistory(removePinned: false) }) {
                Image(systemName: "trash")
                Text("Clear")
            }
            .font(.footnote)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Clear unpinned items")
        }
    }

    /// Clears clipboard history via the view model.
    /// - Parameter removePinned: When true, also removes pinned entries.
    private func clearHistory(removePinned: Bool) {
        itemsVM.clearHistory(removePinned: removePinned)
        selectedID = nil
        copiedID = nil
        searchText = ""
    }

    /// Selects the item at `index`, copies it to the pasteboard, and closes the window.
    private func selectAndCopy(_ index: Int) {
        guard filteredItems.indices.contains(index) else { return }
        selectedID = filteredItems[index].id
        copyItem(at: index)
        // HistoryWindowController.shared.close() // removed per instructions
    }

    /// Copies the item text at `index` to the pasteboard and closes the window.
    private func copyItem(at index: Int) {
        guard filteredItems.indices.contains(index) else { return }
        NSPasteboard.general.copyString(filteredItems[index].text)
        copiedID = filteredItems[index].id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [index] in
            if let id = copiedID, filteredItems.indices.contains(index), filteredItems[index].id == id {
                copiedID = nil
            }
        }
        // Close the history window after copying
        HistoryWindowController.shared.close()
    }

    /// Pastes the item at `index` using `PasteHelper` and closes the window.
    private func pasteItem(at index: Int) {
        guard filteredItems.indices.contains(index) else { return }
        PasteHelper.paste(text: filteredItems[index].text)
        copiedID = filteredItems[index].id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [index] in
            if let id = copiedID, filteredItems.indices.contains(index), filteredItems[index].id == id {
                copiedID = nil
            }
        }
        // Close the history window after pasting
        HistoryWindowController.shared.close()
    }

    /// Handles arrow/return/escape keys for list navigation and actions.
    /// - Up/Down: move selection
    /// - Return: copy selected
    /// - Escape: clear search or close panel
    private func handleKeyEvent(_ event: NSEvent) {
        switch event.keyCode {
        case 125: // down
            guard !orderedItems.isEmpty else { return }
            if let currentID = selectedID, let idx = orderedItems.firstIndex(where: { $0.id == currentID }) {
                let next = min(idx + 1, orderedItems.count - 1)
                selectedID = orderedItems[next].id
            } else {
                selectedID = orderedItems.first?.id
            }
        case 126: // up
            guard !orderedItems.isEmpty else { return }
            if let currentID = selectedID, let idx = orderedItems.firstIndex(where: { $0.id == currentID }) {
                let prev = max(idx - 1, 0)
                selectedID = orderedItems[prev].id
            } else {
                selectedID = orderedItems.last?.id
            }
        case 36: // return
            if let id = selectedID, let idx = orderedItems.firstIndex(where: { $0.id == id }) {
                // Map orderedItems index to filteredItems index for copyItem(at:)
                if let filteredIdx = filteredItems.firstIndex(where: { $0.id == orderedItems[idx].id }) {
                    copyItem(at: filteredIdx)
                }
            }
        case 53: // escape
            if !searchText.isEmpty {
                searchText = ""
            } else {
                selectedID = nil
                HistoryWindowController.shared.close()
            }
        default:
            break
        }
    }
}

// MARK: - ClipRow View

/// A single clipboard entry row displaying text, pin state, timestamp, and quick actions.
///
/// Visual states:
/// - Hovered: subtle background and higher control opacity
/// - Selected: accent-tinted background
/// - Copied: green-tinted background
struct ClipRow: View {
    let item: ClipItem
    var isSelected: Bool
    var isCopied: Bool
    @EnvironmentObject var itemsVM: ItemsViewModel
    @State private var isHovered: Bool = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .short
        return f
    }()

    private var timeString: String { Self.formatter.string(from: item.date) }

    private var titleText: some View {
        Text(item.text)
            .lineLimit(2)
            .truncationMode(.tail)
            .font(.system(size: 13))
            .foregroundColor(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pinBadge: some View {
        Group {
            if item.pinned {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 16, height: 16)
                        .allowsHitTesting(false)
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                }
                .transition(.opacity.combined(with: .scale))
                .animation(.easeInOut(duration: 0.15), value: item.pinned)
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            pinBadge
            Text(timeString)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var pinButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                itemsVM.togglePin(item.id)
            }
        }) {
            Image(systemName: item.pinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.pinned ? Color.accentColor : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            item.pinned
                            ? Color.accentColor.opacity(0.18)
                            : ((isHovered || isSelected) ? Color.secondary.opacity(0.12) : Color.clear)
                        )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            Color.white.opacity(item.pinned ? 0.18 : ((isHovered || isSelected) ? 0.08 : 0.04)),
                            lineWidth: 1
                        )
                )
                .transition(.opacity.combined(with: .scale))
                .animation(.easeInOut(duration: 0.15), value: item.pinned)
                .animation(.easeInOut(duration: 0.12), value: isHovered || isSelected)
        }
        .buttonStyle(.plain)
        .help(item.pinned ? "Unpin" : "Pin")
    }

    private var copyButton: some View {
        Button(action: { NSPasteboard.general.copyString(item.text) }) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .help("Copy to Clipboard")
    }

    private var trailingActions: some View {
        HStack(spacing: 6) {
            pinButton
            copyButton
        }
        .opacity(isHovered ? 1 : 0.7)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: HistoryUI.rowCorner, style: .continuous)
            .fill(backgroundColor)
    }

    private var rowStroke: some View {
        RoundedRectangle(cornerRadius: HistoryUI.rowCorner, style: .continuous)
            .stroke(Color.white.opacity((isHovered || isSelected) ? 0.14 : 0.07), lineWidth: 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                titleText
                metaRow
            }

            Spacer(minLength: 8)

            trailingActions
        }
        .padding(.vertical, HistoryUI.innerVertical)
        .padding(.horizontal, 9)
        .background(rowBackground)
        .overlay(rowStroke)
        .clipShape(RoundedRectangle(cornerRadius: HistoryUI.rowCorner, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: HistoryUI.rowCorner, style: .continuous))
        .scaleEffect(isHovered ? 1.035 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: isHovered)
        .onHover { hover in
            isHovered = hover
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Clipboard item"))
        .accessibilityValue(Text(item.text))
    }

    private var backgroundColor: Color {
        if isCopied { return Color.green.opacity(0.15) }
        if isSelected { return Color.accentColor.opacity(0.14) }
        if isHovered { return Color.gray.opacity(0.06) }
        return Color.white.opacity(0.02)
    }
}

// MARK: - History Window Controller

/// Manages the non-activating floating panel that hosts the history UI.
///
/// Responsibilities:
/// - Create and configure an `NSPanel` with transparent background and rounded content.
/// - Position the panel near a screen point.
/// - Install a global mouse-down monitor to close when clicking outside.
/// - Provide a shared singleton for easy access.
final class HistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = HistoryWindowController()

    private var window: NSPanel?
    private var outsideClickMonitor: Any?

    private override init() {}

    /// Shows the panel if hidden or closes it if visible.
    func toggle(at screenPoint: NSPoint, itemsVM: ItemsViewModel) {
        if let win = window, win.isVisible {
            close()
        } else {
            show(at: screenPoint, itemsVM: itemsVM)
        }
    }

    /// Creates and presents the floating history panel at a position near `screenPoint`.
    func show(at screenPoint: NSPoint, itemsVM: ItemsViewModel) {
        // Use the same shared root view used by MenuBarExtra
        let hosting = NSHostingView(rootView: SharedHistoryRootView(itemsVM: itemsVM))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: HistoryUI.panelWidth, height: HistoryUI.panelHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.isOpaque = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.delegate = self
        panel.animationBehavior = .utilityWindow
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false

        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = containerView

        containerView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: containerView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            containerView.widthAnchor.constraint(equalToConstant: HistoryUI.panelWidth),
            containerView.heightAnchor.constraint(equalToConstant: HistoryUI.panelHeight)
        ])

        if let screen = NSScreen.main {
            let halfW: CGFloat = HistoryUI.panelWidth / 2
            var origin = NSPoint(x: screenPoint.x - halfW, y: screenPoint.y - 20 - HistoryUI.panelHeight)
            let visible = screen.visibleFrame
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - HistoryUI.panelWidth - 8))
            origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - 8))
            panel.setFrameOrigin(origin)
        }

        NSApp.activate(ignoringOtherApps: false)
        panel.orderFront(nil)

        installOutsideClickMonitor()
        self.window = panel
    }

    /// Closes the panel and removes any installed outside-click monitor.
    func close() {
        if let win = window {
            win.orderOut(nil)
            removeOutsideClickMonitor()
        }
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }

    /// Installs a global mouse-down monitor that closes the panel when the user clicks outside it.
    private func installOutsideClickMonitor() {
        outsideClickMonitor.map(NSEvent.removeMonitor)
        outsideClickMonitor = nil
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func removeOutsideClickMonitor() {
        outsideClickMonitor.map(NSEvent.removeMonitor)
        outsideClickMonitor = nil
    }
}

