# Clip-Board
A lightweight, privacy‑minded macOS clipboard history manager (SwiftUI + AppKit). Secure at rest (AES‑GCM), fast in memory, minimal UI, no telemetry.

> Status: Early-stage but functional. Focus: Reliability, clarity, and security of local history.

---

## Contents
- Overview
- Features
- Screenshots / Demo
- Quick Start
- Usage
- Keyboard & Pointer Actions
- Architecture
- Data Flow & Lifecycle
- Security & Privacy
- Limitations
- Roadmap
- Troubleshooting
- Project Structure
- Contributing
- License
- Acknowledgements

---

## Overview
Clip-Board continuously watches the macOS pasteboard for new textual copies, normalizes and deduplicates them, and stores a secure, locally-encrypted history you can recall from:
- A floating, non‑activating panel (hotkey).
- A Menu Bar window (same shared UI).

Pinned items persist beyond the rolling limit. Nothing leaves your machine.

---

## Features

### Core
- Continuous clipboard capture (plain text types).
- Whitespace normalization + duplicate surfacing (moves existing to top).
- Pinned vs non‑pinned retention (default limit: 100 non‑pinned).

### UI / Interaction
- Shared SwiftUI root (menu bar + floating panel).
- Fast keyboard navigation (↑ ↓ ⏎ Esc).
- Hover, selection, subtle theming with macOS visual materials.
- Lazy incremental loading (performance on long histories).
- Context menu: Pin / Unpin / Copy / Delete.

### Performance & Reliability
- Debounced background persistence (JSON → encrypt → atomic write).
- Polling strategy (0.5s) tuned for low overhead.
- Minimal allocations in hot loops.

### Security
- AES‑GCM (256‑bit) via CryptoKit for persisted history.
- Symmetric key stored in Keychain (WhenUnlockedThisDeviceOnly, non‑sync).
- Tight file permissions (0700 dir / 0600 file where supported).
- No network code / telemetry paths.

### Developer Friendly
- Clear separation: Model / Persistence / UI / Bridging / Hotkey.
- AppKit bridges only where needed (keypress, text field, window panel).
- Composable SwiftUI view models.

---

## Screenshots / Demo
(You can add screenshots or a short GIF here)
```
coming soon
```

---

## Quick Start

Prereqs:
- macOS 13+
- Xcode (recent toolchain supporting Swift Concurrency & CryptoKit)

Build / Run:
```
git clone https://github.com/your-user/clip-board.git
cd clip-board
# Open in Xcode and build the Clip_Board target
```

First launch:
- Generates encryption key (Keychain).
- Creates encrypted history file.
- Registers global hotkey (Ctrl + Option + Cmd + V).
- Registers launch-at-login (macOS 13+; always-on in current build).

---

## Usage

Open history:
1. Press Ctrl + Option + Cmd + V (default hotkey).
2. Or click the Menu Bar icon.

Interact:
- Click a row → Copies and closes floating panel.
- Pin important entries.
- Use search to filter (debounced).
- Clear (un-pinned) items with the Clear button.

---

## Keyboard & Pointer Actions

| Action | Keys / Gesture | Notes |
| ------ | -------------- | ----- |
| Navigate list | Up / Down | Wraps at ends only when re-invoked after selection cleared. |
| Copy selected | Return | Copies + closes panel. |
| Clear search / Close panel | Esc | If search text present → clears; else closes. |
| Pin / Unpin | Context menu | (Right-click or control-click). |
| Load more | Scroll near end | Lazy expansion (in batches). |
| Instant search | Type in field | Debounced 180ms commit. |

---

## Architecture

High-level layers:
1. Model: `ClipItem`
2. ViewModel: `ItemsViewModel` (limit enforcement, dedupe, pin logic, debounced save)
3. Services:
   - `ClipboardWatcher` (poll-based change detection)
   - `HotkeyManager` (Carbon event hotkey)
   - `PersistenceManager` (JSON + encrypt)
   - `KeyManager` (Keychain-backed symmetric key)
4. UI:
   - `ContentView`, `ClipRow`, `SharedHistoryRootView`
   - AppKit bridges: keyDown monitor, focus-ringless field, visual effect panel
5. Window mgmt: `HistoryWindowController` (non-activating floating `NSPanel`)

Bridging choices:
- `NSPanel` for non-activating floating UI.
- Custom local key monitor for keyboard list control without first-responder churn.

---

## Data Flow & Lifecycle

1. User copies text → macOS pasteboard updates.
2. `ClipboardWatcher` (timer) detects `changeCount` diff.
3. Reads text, normalizes whitespace, trims.
4. Passes to `ItemsViewModel.addItem`.
5. View model:
   - Surfaced duplicate? Move to top (date refresh).
   - Insert new? Enforce non-pinned limit.
   - Publish change.
6. Debounced save pipeline:
   - Encode JSON (ISO8601).
   - Encrypt (AES‑GCM) with symmetric key.
   - Atomic write with permissions.
7. UI renders updated in-memory array (no blocking on disk).

---

## Security & Privacy

Threat model (basic local integrity & confidentiality):
- Protects at-rest clipboard history from casual file inspection.
- Key not synced (prevents iCloud/keychain propagation).
- No remote transmission code present.

Non-goals (currently):
- Secure erase of prior plaintext pages in RAM.
- Defense against a locally privileged attacker while app is open.
- Multi-user / multi-device synchronization.

Key Loss:
- Deleting the Keychain entry = history unrecoverable (expected design).

---

## Limitations

Current:
- Text-only support (no attributed strings, images, files).
- No preferences UI (hotkey / history size / launch toggle static).
- Polling (0.5s) vs event (API limitation).
- No localization.
- Minimal accessibility auditing (screen reader pass basic).
- No automated tests yet.

---

## Roadmap (Potential)
- Preferences panel (hotkey remap, history size, launch toggle).
- Rich content types (images, RTF) with secure binary storage.
- Export/import (encrypted bundle).
- Better accessibility focus order & VoiceOver labels.
- Optional plain (unencrypted) mode for debugging.
- Diagnostics panel (key presence, file stats).
- Unit + UI tests (persistence, watcher correctness).
- Migration handling for schema changes.

---

## Troubleshooting

| Issue | Checklist |
| ----- | --------- |
| No items recorded | Verify you copy plain text; check console; ensure app not sandboxed. |
| Panel not showing | Confirm hotkey not intercepted by another app; try clicking menu bar icon. |
| Hotkey fails | Rebuild after clean; ensure app has Input Monitoring (if prompted). |
| History lost | Keychain key removed → expected unrecoverable loss. |
| Launch at login missing | Development signing may block `SMAppService`; verify entitlements. |

---

## Project Structure (Key Files)

```
AppAndCrypto.swift     // App entry, KeyManager, PersistenceManager
History.swift          // ClipItem, ItemsViewModel, ClipboardWatcher, HotkeyManager, utilities
UIViews.swift          // All SwiftUI/AppKit bridging views + HistoryWindowController
```

---

## Contributing

Welcome.
1. Discuss major changes via Issue first (avoids divergence).
2. Follow Swift API Design Guidelines.
3. Add doc comments to new public types.
4. Keep UI additions macOS-native (avoid custom heavy styling).
5. For security-impacting changes: describe threat model shift & migration path.
6. Prefer small, focused PRs.
7. Testing (future): add unit tests where logic-heavy (persistence, trimming, dedupe).

---

## Building Notes
- macOS 13 APIs (MenuBarExtra, SMAppService) used.
- For earlier macOS support, conditional compilation + alternative launch agent strategy needed.

---

## License
MIT (see LICENSE file).

---

## Acknowledgements
- Swift, SwiftUI, AppKit, CryptoKit.
- Standard macOS interaction patterns.
- Prior community clipboard tools for conceptual inspiration.

---

## Contact
Author: SNGWN  
(Replace with GitHub profile / issues page link)
