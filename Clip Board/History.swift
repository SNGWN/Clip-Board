import SwiftUI
import AppKit
import Foundation
import Combine
import Carbon

// MARK: - Data Model

struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    var date: Date
    var pinned: Bool = false
}

// MARK: - ViewModel

final class ItemsViewModel: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    private let limit = 100
    private let saveSubject = PassthroughSubject<Void, Never>()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        items = PersistenceManager.shared.load()

        saveSubject
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] in
                guard let self else { return }
                PersistenceManager.shared.save(items: self.items)
            }
            .store(in: &cancellables)
    }

    private func scheduleSave() { saveSubject.send(()) }

    func addItem(_ text: String) {
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let newText = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else { return }

        if let existingIndex = items.firstIndex(where: { $0.text == newText }) {
            var existing = items.remove(at: existingIndex)
            existing.date = Date()
            items.insert(existing, at: 0)
            scheduleSave()
            return
        }

        let newItem = ClipItem(id: UUID(), text: newText, date: Date())
        items.insert(newItem, at: 0)
        trimIfNeeded()
        scheduleSave()
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        trimIfNeeded()
        scheduleSave()
    }

    func deleteItem(_ id: UUID) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items.remove(at: idx)
            scheduleSave()
        }
    }

    func clearHistory(removePinned: Bool = false) {
        if removePinned {
            items.removeAll()
        } else {
            items.removeAll(where: { !$0.pinned })
        }
        scheduleSave()
    }

    private func trimIfNeeded() {
        let nonPinned = items.filter { !$0.pinned }
        if nonPinned.count > limit {
            let toRemove = nonPinned.dropFirst(limit)
            let idsToRemove = Set(toRemove.map { $0.id })
            items.removeAll { idsToRemove.contains($0.id) }
        }
    }
}

// MARK: - Clipboard Watcher

final class ClipboardWatcher {
    static let shared = ClipboardWatcher()
    private init() {}

    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var lastStoredText: String?
    private var onNewItem: ((String) -> Void)?

    deinit { timer?.invalidate() }

    func start(onNewItem: @escaping (String) -> Void) {
        self.onNewItem = onNewItem
        stop()
        lastChangeCount = -1

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        DispatchQueue.main.async { [weak self] in
            self?.checkClipboard()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        let change = pb.changeCount
        guard change != lastChangeCount else { return }
        lastChangeCount = change

        var text: String?
        if let s = pb.string(forType: .string) {
            text = s
        } else if let objects = pb.readObjects(forClasses: [NSString.self], options: nil) as? [NSString],
                  let first = objects.first {
            text = first as String
        }

        guard var copiedString = text else { return }
        copiedString = copiedString.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        copiedString = copiedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copiedString.isEmpty else { return }

        guard copiedString != lastStoredText else { return }
        lastStoredText = copiedString

        onNewItem?(copiedString)
    }
}

// MARK: - Hotkey Manager

final class HotkeyManager {
    static let shared = HotkeyManager()
    private init() {}

    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var eventHandlerRef: EventHandlerRef?

    // Internal so InstallEventHandler can access
    static var eventSpec = EventTypeSpec(
        eventClass: OSType(Int32(kEventClassKeyboard)),
        eventKind: UInt32(Int32(kEventHotKeyPressed))
    )

    static let signature: OSType = { OSType("Clip".fourCharCodeValue) }()

    static let eventHandlerCallback: EventHandlerUPP = { _, eventRef, _ in
        var receivedID = EventHotKeyID()
        let err = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedID
        )
        if err == noErr {
            if receivedID.signature == HotkeyManager.signature && receivedID.id == 1 {
                HotkeyManager.shared.handler?()
            }
        } else {
            print("⚠️ GetEventParameter failed: \(err)")
        }
        return noErr
    }

    func registerHotkey(handler: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.handler = handler

            if let ref = self.hotKeyRef {
                let status = UnregisterEventHotKey(ref)
                if status != noErr { print("⚠️ Failed to unregister existing hotkey: \(status)") }
                self.hotKeyRef = nil
            }

            if self.eventHandlerRef == nil {
                var ref: EventHandlerRef?
                let installStatus = InstallEventHandler(
                    GetApplicationEventTarget(),
                    HotkeyManager.eventHandlerCallback,
                    1,
                    [HotkeyManager.eventSpec],
                    nil,
                    &ref
                )
                if installStatus != noErr {
                    print("⚠️ Failed to install hotkey event handler: \(installStatus)")
                } else {
                    self.eventHandlerRef = ref
                }
            }

            let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: UInt32(1))
            let modifiers: UInt32 = UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)

            let status = RegisterEventHotKey(
                UInt32(kVK_ANSI_V),
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &self.hotKeyRef
            )

            if status == noErr {
                print("✅ Hotkey registered (Ctrl+Option+Cmd+V)")
            } else {
                print("⚠️ Failed to register hotkey (Ctrl+Option+Cmd+V): \(status)")
            }
        }
    }

    func unregisterHotkey() {
        if let ref = hotKeyRef {
            let status = UnregisterEventHotKey(ref)
            if status != noErr { print("⚠️ Failed to unregister hotkey: \(status)") }
            hotKeyRef = nil
        }
        if let handlerRef = eventHandlerRef {
            RemoveEventHandler(handlerRef)
            eventHandlerRef = nil
        }
        handler = nil
    }
}

// MARK: - Utilities

extension String {
    var fourCharCodeValue: FourCharCode {
        var result: FourCharCode = 0
        for scalar in unicodeScalars {
            result = (result << 8) + FourCharCode(scalar.value)
        }
        return result
    }
}

extension NSPasteboard {
    func copyString(_ string: String) {
        clearContents()
        setString(string, forType: .string)
    }
}
