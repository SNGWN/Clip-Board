# Clip-Board

A lightweight macOS clipboard manager written in Swift (SwiftUI + AppKit bridge). Clip-Board monitors the system pasteboard, stores a recent history of copied text entries, and exposes a polished floating history panel and a menu bar item for quick access. Stored history is encrypted on disk using AES‑GCM and a symmetric key saved in the user's Keychain.

---

Table of Contents
- About
- Key Features
- Architecture & Components
- Security & Privacy
- Limitations & Known Weaknesses
- Building & Running
- Usage
- Troubleshooting
- Contributing
- License

---

About
-----
Clip-Board is designed to be a focused, secure clipboard-history utility for macOS that "just works" — quickly capturing text copied to the clipboard, keeping recent items, letting you pin favorites, and recalling items via a floating panel or menu bar entry.

Key Features
------------
- Continuous clipboard monitoring with deduplication and whitespace normalization.
- Stores a history of clipboard text items (default limit: 100 non‑pinned items).
- Pin items so they persist beyond the history limit.
- Persisted history is encrypted on disk with AES‑GCM (256 bit).
- Symmetric encryption key stored securely in the macOS Keychain (WhenUnlockedThisDeviceOnly).
- Floating, non-activating history panel implemented with a SwiftUI/AppKit bridge for a native look (visual materials, rounded corners, subtle borders, shadows).
- Menu bar extra with shared UI to open/inspect history.
- Hotkey support to show/hide the floating history panel (HotkeyManager).
- Debounced persistence to minimize write I/O and keep UI responsive.
- Attempts to be privacy-friendly: encryption, non-synchronizable keychain entry, file permissions for stored data.

Architecture & Components
-------------------------
High-level components (files and responsibilities):

- History.swift
  - ClipItem: data model for a clipboard entry (id, text, date, pinned).
  - ItemsViewModel: ObservableObject that holds in-memory items, enforces limit, deduplication, pin/toggle/delete, debounced save.
  - ClipboardWatcher: polls NSPasteboard.changeCount (timer every 0.5s) and normalizes text; calls ItemsViewModel.addItem when new text is detected.

- AppAndCrypto.swift
  - KeyManager: generates, stores, loads, deletes a SymmetricKey in the Keychain. Provides encrypt/decrypt using CryptoKit (AES.GCM).
  - PersistenceManager: encodes/decodes items to JSON (ISO8601 dates), encrypts/decrypts data, writes/reads to Application Support with secure file permissions (700 folder, 600 file).
  - Clip_BoardApp: app entry using @main. Sets up KeyManager, starts services (ClipboardWatcher, HotkeyManager), creates MenuBarExtra. Registers launch-at-login via ServiceManagement (macOS 13+).

- UIViews.swift
  - Contains SwiftUI views and small AppKit wrappers:
    - KeyDownHandlingView: intercepts keyDown locally for keyboard navigation.
    - VisualEffectView: NSVisualEffectView wrapper for macOS materials.
    - SharedHistoryRootView and ContentView: shared SwiftUI root used by menu and floating panel.
    - ClipRow: view for each history row with hover/selection effects, pin badge, meta info.
    - HistoryWindowController: manages non-activating floating panel (transient floating panel, ignores cycle, closes on outside click, installs global mouse monitors).
    - Misc bridging views (focus-ringless NSTextField, onKeyDown modifier, etc.)

Design notes:
- UI uses modern macOS materials and subtle shadows to blend with native UI.
- Persistence is done on a background queue to avoid main thread blocking.
- Saves are debounced (300ms) to group rapid changes.

Security & Privacy
------------------
- History is encrypted at rest using AES‑GCM via CryptoKit.
- Symmetric key is stored in Keychain with:
  - kSecAttrAccessibleWhenUnlockedThisDeviceOnly
  - kSecAttrSynchronizable = false (not synced)
- The app stores files in Application Support/ClipboardManager/history.json.enc.
- Folders and files are created with restrictive permissions (folder 0700, file 0600 where possible).
- No telemetry or network calls are present in the codebase (no networking code found).
- Note: The symmetric key will be lost if the keychain entry is deleted — encrypted history will not be recoverable without it.

Limitations & Known Weaknesses
------------------------------
- Clipboard types supported:
  - Focuses on textual clipboard types (NSString / .string). Non-text types (images, rich text with attributes, file URLs) are not preserved.
- ClipboardWatcher uses a polling timer (0.5s) that checks NSPasteboard.changeCount. This is a common approach but:
  - Slightly less efficient than event-based approaches if they existed; however, NSPasteboard does not provide push notifications.
  - Polling might detect rapid successive changes and could miss or duplicate in some edge timing cases (the deduplication and normalization reduce noise).
- No UI for advanced preferences:
  - Launch-at-login toggle was intentionally removed in favor of always starting at login (see code comments). Some users might prefer a toggle.
  - Hotkey is registered, but customization of the hotkey is not exposed via UI in the current code.
  - No explicit settings for history size or autosave behavior in the shipped UI.
- No unit tests or CI configuration in the repository.
- Target macOS / APIs:
  - Uses MenuBarExtra and SMAppService which requires macOS 13+; older macOS versions are not fully supported in current code.
- Error reporting / UX:
  - Most failures are printed to console; user-facing error handling and recovery flows are minimal.
- No automatic migration or clear recovery flows if the keychain entry becomes unavailable or corrupted.
- No localization (strings are in source).

Build & Run (Developer)
-----------------------
Requirements:
- Xcode (version compatible with macOS 13+ SDK)
- macOS 13 or later to get MenuBarExtra and SMAppService features

Steps:
1. Open the Xcode project/workspace (if present) or create one and add the source files from the repository.
2. Ensure your target macOS version in the project is macOS 13.0 or later (or guard runtime with availability checks).
3. Build and run the app.
4. On first run, the app will generate a symmetric key stored in your Keychain and create an encrypted history file in Application Support.

Notes:
- Development builds may need to be codesigned appropriately for SMAppService.register() to succeed.
- If you run into "failed to register launch at login" messages in console, check entitlements and provisioning; SMAppService.mainApp.register() can fail in development builds without proper signing or helper app setup.

Usage (End User)
----------------
- Once running, Clip-Board monitors your clipboard and records copied text items automatically.
- Open the history:
  - Press the configured hotkey (registered by HotkeyManager) to show the floating history panel at the mouse location.
  - Or click the menu bar icon (menu bar extra) to reveal the same UI.
- Interacting with items:
  - Click an item to copy it back to the pasteboard.
  - Pin items to keep them persistent through history trims.
  - Delete items as needed.
- The floating panel hides when you click outside it.

Troubleshooting
---------------
- Nothing appears in history:
  - Ensure the app is running and services have started (check console logs).
  - Confirm the clipboard actually contains plain text.
- History is empty after reinstall:
  - If the Keychain entry for the symmetric key was deleted or lost, the encrypted history cannot be decrypted. This repository does not implement an import/recovery of keys.
- Hotkey doesn't work:
  - HotkeyManager registers a global hotkey — macOS privacy/permissions can interfere. Check System Preferences > Security & Privacy > Input Monitoring if needed.
- Launch-at-login registration failures:
  - SMAppService requires proper code signing and right bundle configuration. In development signing may be missing.

Contributing
------------
Contributions are welcome. Good first steps:
- Add unit tests for ClipboardWatcher, PersistenceManager, and KeyManager behaviors.
- Add a preferences UI to allow:
  - Toggle launch at login (and fall back for macOS < 13).
  - Configure max history size.
  - Configure/choose hotkey.
  - Export/import (securely) history.
- Add support for non-text clipboard types (images, RTF) with secure storage considerations.
- Add localization and accessibility improvements.
- Improve user-facing error handling and UI for recovery (keychain missing, corrupted history).

When contributing:
- Follow Swift API design guidelines, document public types/functions.
- New features that touch security/persistence should include migration and recovery strategies.

License
-------
This project is licensed under the MIT License. See LICENSE for details.

Acknowledgements
----------------
- Built with Swift, SwiftUI, AppKit bridging, and CryptoKit.
- Inspiration drawn from common clipboard managers and macOS UI patterns.

Contact
-------
Repository owner: SNGWN (see GitHub profile)
