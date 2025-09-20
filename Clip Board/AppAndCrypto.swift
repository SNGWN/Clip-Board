import SwiftUI
import AppKit
import Foundation
import CryptoKit
import Security
import ServiceManagement

// MARK: - KeyManager

enum KeyManagerError: Error {
    case keyGenerationFailed
    case keychainError(status: OSStatus)
    case keyNotFound
    case encryptionFailed
    case decryptionFailed
    case invalidUTF8
}

final class KeyManager {
    static let shared = KeyManager()
    private init() {}

    private let service = "com.clipboard.manager"
    private let account = "com.clipboard.manager.symmetrickey"
    private var cachedKey: SymmetricKey?

    func ensureKeyExists() throws {
        if (try? loadKey()) != nil { return }
        let key = SymmetricKey(size: .bits256)
        try storeKeyInKeychain(key: key)
        cachedKey = key
    }

    func deleteKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyManagerError.keychainError(status: status)
        }
        cachedKey = nil
    }

    func encrypt(data: Data) throws -> Data {
        let key = try getOrLoadKey()
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else { throw KeyManagerError.encryptionFailed }
            return combined
        } catch {
            throw KeyManagerError.encryptionFailed
        }
    }

    func decrypt(_ encryptedData: Data) throws -> Data {
        let key = try getOrLoadKey()
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            let decrypted = try AES.GCM.open(sealedBox, using: key)
            return decrypted
        } catch {
            throw KeyManagerError.decryptionFailed
        }
    }

    private func loadKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeyManagerError.keyNotFound
        }
        let key = SymmetricKey(data: data)
        cachedKey = key
        return key
    }

    private func storeKeyInKeychain(key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data($0) }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        SecItemDelete(addQuery as CFDictionary)
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyManagerError.keychainError(status: status)
        }
        cachedKey = key
    }

    private func getOrLoadKey() throws -> SymmetricKey {
        if let key = cachedKey { return key }
        return try loadKey()
    }
}

// MARK: - Persistence

final class PersistenceManager {
    static let shared = PersistenceManager()
    private init() {}

    private let fileName = "history.json.enc"

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let ioQueue = DispatchQueue(label: "PersistenceManager.IO", qos: .utility)

    private var fileURL: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("ClipboardManager", isDirectory: true)
        if !fm.fileExists(atPath: folder.path) {
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [
                    .posixPermissions: 0o700
                ])
            } catch {
                print("⚠️ Failed to create app support folder: \(error)")
            }
        }
        return folder.appendingPathComponent(fileName)
    }

    func save(items: [ClipItem]) {
        let url = fileURL
        ioQueue.async {
            do {
                let jsonData = try PersistenceManager.encoder.encode(items)
                let encrypted = try KeyManager.shared.encrypt(data: jsonData)
                try encrypted.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                print("⚠️ Failed to save history: \(error)")
            }
        }
    }

    func load() -> [ClipItem] {
        do {
            let data = try Data(contentsOf: fileURL)
            let decrypted = try KeyManager.shared.decrypt(data)
            let items = try PersistenceManager.decoder.decode([ClipItem].self, from: decrypted)
            return items
        } catch {
            return []
        }
    }
}

// MARK: - App Entry

@main
struct Clip_BoardApp: App {
    @StateObject private var itemsVM = ItemsViewModel()

    // Removed @AppStorage toggle to enforce "always start on login"
    @State private var servicesStarted = false

    init() {
        do {
            try KeyManager.shared.ensureKeyExists()
        } catch {
            print("⚠️ Failed to setup encryption key: \(error)")
        }

        // Always start on login (macOS 13+)
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                print("✅ Launch at login registered")
            } catch {
                print("⚠️ Failed to register launch at login: \(error)")
            }
        }
    }

    var body: some Scene {
        MenuBarExtra("Clipboard", systemImage: "doc.on.clipboard") {
            // Use the same shared root used by the hotkey window
            SharedHistoryRootView(itemsVM: itemsVM)
                .onAppear(perform: startServicesIfNeeded)
        }
        .menuBarExtraStyle(.window)
    }

    private func startServicesIfNeeded() {
        guard !servicesStarted else { return }
        servicesStarted = true

        ClipboardWatcher.shared.start { [weak itemsVM] newText in
            itemsVM?.addItem(newText)
        }

        HotkeyManager.shared.registerHotkey { [weak itemsVM] in
            guard let itemsVM else { return }
            let loc = NSEvent.mouseLocation
            HistoryWindowController.shared.toggle(at: loc, itemsVM: itemsVM)
        }

        Clip_BoardApp.syncLaunchAtLoginStatusStatic()
    }

    static func syncLaunchAtLoginStatusStatic() {
        if #available(macOS 13.0, *) {
            _ = SMAppService.mainApp.status
        }
    }
}
