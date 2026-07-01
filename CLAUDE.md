# Moshroom — the brain

Moshroom is an iOS terminal for **remote agentic coding from the iPhone**: drive an AI agent
(e.g. Claude Code) running on a remote machine over SSH/Mosh. It is a **standalone app**
(`com.alvarofranz.moshroom`) — not maintained as a fork: there is no upstream remote and no
sync workflow. Free rein to refactor, delete, redesign.

> Heritage (maintainers only): the terminal engine, SSH/Mosh stack and config began as
> existing GPLv3 code (the `BK*` / `BLK*` ObjC internals). The original author granted permission
> to relicense; Moshroom **stays GPLv3** (`COPYING`) for consistency, now under **Moshroom's own
> copyright** — all prior third-party-app branding, attribution and App-Store-exception text have
> been removed. The app is Moshroom-branded and Moshroom-copyrighted throughout, with **zero "Blink"
> brand anywhere and zero `github.com/blinksh` dependency** — every binary framework is self-hosted on
> this repo's own release and every source dep is Apple-upstream or vendored in-tree (see `FRAMEWORKS.md`).
> Bundled third-party components keep their own licenses (`about.html`).

- Bundle id: `com.alvarofranz.moshroom` · Team: `6STWTTP329` · Display name: **Moshroom**

## Build & deploy

`./deploy.sh` — incremental build + install + launch on the connected iPhone. First build is
slow; later builds are incremental. Needs full Xcode, the gitignored `developer_setup.xcconfig`
(TEAM_ID + bundle/group/cloud/keychain ids), and prebuilt frameworks from `./get_frameworks.sh`.

### Build-compat flags (Xcode 16+/26)

Built-in commands dispatch via `dlsym(RTLD_MAIN_ONLY, <cmd>_main)`. Modern Xcode breaks that,
so `developer_setup.xcconfig` / `template_setup.xcconfig` set:
- `ENABLE_DEBUG_DYLIB = NO` — keep app code in the main executable so the command symbols resolve.
- `MOSHROOM_OTHER_LDFLAGS = -Xlinker -export_dynamic` — export globals so `dlsym` finds them.
Every target uses `DEVELOPMENT_TEAM = $(TEAM_ID)`.

## The Moshroom feature layer (this is ours)

In `Moshroom/`, gated by `Moshroom.scratchOnly` (defined in `Moshkitor.swift`):

- `Moshkitor.swift` — the `Moshroom` flag; **Moshkitor** composer (system keyboard + dictation;
  attributed text so Moshdrop chips sit inline; iPhone-Notes-style auto `-` bullet lists — Enter
  continues, Enter on an empty bullet ends, sent as literal `-`; control bar above the keyboard, a
  **command/snip completion strip** — built-ins + `claude`/`opencode`,
  plus Snips matched by filename that insert the snip's content — surviving draft, `Ctrl+Enter` to
  send); the **Snips** gallery + editor; the shared `MoshkitorSnips` disk enumerator (one source of
  truth for both the gallery and the completion strip); the `open*` `SpaceController` extension;
  `MoshroomKeyboard` (hardware-keyboard routing).
- `Moshkeys.swift` — **Moshkeys** floating round quick-keys + the shared `moshkeyRoundButton`
  house style (reused by the Moshkitor control bar). Bottom bar: ⌃ (one centered special-keys
  pad) / 123 / abc / ↕ / ⏎ + a compose button; top bar (no background, mirrors the bottom):
  **Tabs** (left) + **Settings** (right).
- `Moshnector.swift` — **Moshnector**: the fresh-terminal quick-connect card. On a shell at the
  `moshroom>` prompt it offers one-tap connect (mode SSH/Mosh + a saved host alias → types
  `<mode> <alias>`). Plain overlay (never first responder, so typed text is never swallowed);
  shown whenever a terminal is a fresh, idle, unconnected `moshroom>` shell. The reveal is one method —
  `showMoshnectorIfIdle()` (checks `TermController.moshroomIsFreshShell`) — fired from triggers that
  cover every ordering deterministically, **no poll, no race**: (1) the session going live —
  `TermController._startSession()`/`resume(with:)` post `MoshroomPromptReadyNotification` right after
  `_session` is populated (this is the fix: the view-readiness triggers used to run *before* `_session`
  existed — `_session` = `_sessionPayload?.session` is nil until the payload starts — so the card never
  appeared); (2) the shell printing its prompt (`MCPSession._postPromptReady`, e.g. after a command or
  when an ssh/mosh child exits); (3) view lifecycle (`viewDidAppear`, `TermViewReady`). All idempotent
  — `showMoshnectorIfIdle` shows for a fresh shell and hides for a connected ssh/mosh. Hidden the instant
  you type, tap a key, switch tab, or connect.
  > **Restore path:** `TermController.resume(with:)` no longer aborts when the suspend archive is empty
  > (it was being marked `isSuspended` even when `_sessionPayload` was nil, so the archive carried no
  > `termUIState`/payload). It now restores the UI state only if present and **falls back to starting a
  > fresh `MCPSessionPayload`** when the archive has no session — so a relaunched terminal is always live
  > (never a dead, sessionless prompt) and `moshroomIsFreshShell` is true, which is what makes the card
  > appear on a normal (restored) launch, not just a first install.
- `Moshdrop.swift` — **Moshdrop**: attach a local file (Photos / Files / Clipboard) → it appears
  **inline at the cursor** in Moshkitor immediately, as a `MoshdropAttachment : NSTextAttachment`
  (a small ~30pt thumbnail for images, a compact "[icon] name" chip otherwise, vertically centred on
  the prose). Nothing uploads until you **send**:
  then every attachment is SFTP'd to `~/.moshroom/uploads/` on a saved SSH host (reuses saved
  keys/config, mirrors `Moshroom/Commands/ssh/CopyFiles.swift`, own run-loop thread) behind an
  "Uploading N of M" overlay with a real mushroom-red progress bar (true SFTP byte counts via
  `CopyProgressInfo`) and a ✕ that cancels the upload straight back into the editor (text + chips
  intact). Only then is the command written — each inline chip swapped for its remote path, so
  files land at the exact spot you put them in the prose; only the chips still present at send are
  uploaded (remove one and it's gone). Any upload failure drops you back in the editor with
  everything intact. Only attaches what the agent can read — images / PDFs / text & code
  (`isAgentReadable`); no video, audio, archives or apps. **Images are downsized + re-encoded to JPEG
  on-device before upload** (`Moshdrop.compressedImage`: long edge ≤ `imageMaxPixel` = 1568, quality
  `jpegQuality` = 0.8 via ImageIO — a multi-MB photo becomes a couple hundred KB, and iPhone HEIC→JPEG
  so the agent/vision can actually read it; PDFs/text/code and GIFs pass through byte-for-byte, and the
  JPEG is kept only when it's smaller than the original or the source was HEIC). All of this is local —
  the remote needs nothing installed. Each lands under a clean **md5-slug**
  name (`<md5>.<ext>`, so `~/.moshroom/uploads/` never collects weird filenames and identical
  content de-dups), and every upload also best-effort prunes remote files older than **48h** over
  the same SFTP session (`sweepRemote`, fail-safe + scoped to the uploads dir; deletes walk a
  `cloneWalkTo` so they never mutate the shared upload translator). Files stage under
  `Caches/moshdrop/` between pick and send. The picker is `MoshdropPicker`; the per-file SFTP
  uploader is `MoshdropUploader`.
- `Moshxplore.swift` — **Moshxplore**: a remote file explorer (download direction; the mirror of
  Moshdrop's upload). A floating card (the Quick-Connect look, `MoshxploreStyle` palette) opened from
  a **folder button in the top bar, left of Settings** (`openMoshxplore`); runs over **any tab, needs
  no shell/connection** (own subview of `sc.view`). Three steps: **host picker** (saved aliases, reuses
  `moshroomSavedHostAliases`; refreshes live on `MoshroomHostsDidSave` via `reloadHostsIfVisible`,
  only while that step is showing) → **browser** (`MoshxploreEntryRow`: name + size·date + chevron;
  folders descend, files open detail; dirs-first sort; an up button + a switch-host button) →
  **file detail** (`MoshxploreDetailView`: name, size·date·path, an **inline preview** — image or
  text/code when small & readable — and one **Download to Files** button). Listing is SFTP
  `directoryFilesAndAttributes` (the robust structural equivalent of `ls -lsa`, never screen-scraped);
  download/preview are SFTP `copy` (the same Combine SSH/SFTP stack as Moshdrop/CopyFiles), all driven
  by `MoshxploreSession` on its **own persistent run-loop thread** (`connect`/`list`/`download(into:)`/
  `cancelDownload`/`stop`; one connection reused via `cloneWalkTo`). Tapping a previewable file fetches
  it into a temp cache (`MoshxploreDownloads.previewCache()`) and renders it; **Download** saves into
  `Documents/<host>/` (`MoshxploreDownloads.directory(host:)`, sanitized) — Files.app already shows the
  app container as "Moshroom", so saves group as **Moshroom › host › file** rather than nesting another
  "Moshroom" — reusing the already-fetched temp copy when present, else SFTP-ing straight in with the
  mushroom-red progress overlay. On success the overlay offers **Open** (a `UIActivityViewController`
  share sheet on the saved file — `presentShare`, set in install) + **Done**.
  **Folders are navigate-only** (no recursive download). Preview gates: image ≤ 8 MB, text ≤ 1 MB
  (`MoshxplorePreview`); larger/binary shows "download to open". **Mutually exclusive with Quick
  Connect** — `openMoshxplore` hides Moshnector, `showMoshnectorIfIdle` bails while
  `moshroomMoshxploreIsOpen`, and `dismissMoshxplore` re-reveals Quick Connect if the shell is fresh.
  Dismissed (and the SSH connection torn down) on close or tab switch.

### Per-host "Command on connect"

A per-host `MoshHosts.commandOnConnect` (Settings → Hosts → **ON CONNECT**; e.g. `cd dev && claude`) is
**typed into the interactive session right after connecting, for SSH and Mosh alike**, and is
**independent of `moshStartup`** (the Mosh server command: `screen -r` / `tmux attach`) — it runs
*inside* whatever session comes up (so with tmux it lands in the attached pane). Injected as terminal
input via `TermDevice.write` (→ `writeInDirectly`, the session's stdin pipe that both clients read):
- **SSH** (`ssh.swift startInteractiveSessions`): written synchronously right after `s.connect(...)`,
  only for an interactive login (`command == nil`) — deterministic; the remote PTY buffers it.
- **Mosh** (`mosh.swift moshMain`): mosh flushes stdin as it takes over the TTY, so pre-buffering would
  be dropped — instead it fires ~0.5s after `mosh_main` starts (once, on a fresh connect; nil on the
  restore path). Model plumbing: property + coder in `MoshHosts.{h,m}`, a `commandOnConnect:` param on
  `saveHost:`, and the field in `HostView.swift` (set after the if/else, not part of `initWithAlias:`).

### Seams into the terminal core (keep minimal)

| File | Seam |
|------|------|
| `Moshroom/SmarterKeys/SmarterTermInput.swift` | `becomeFirstResponder` returns `false` under `Moshroom.scratchOnly` (terminal never shows a keyboard) |
| `Moshroom/SpaceController.swift` | `Moshkeys.install` + `Moshnector.install`; the viewport is pinned inside the safe area with a symmetric **56pt strip reserved top + bottom** for the floating bars; first-responder handling; `pressesBegan` → `MoshroomKeyboard` |
| `Moshroom/Terminal/LayoutConstraintManager.m` | one fixed terminal layout: a small uniform inset (the SpaceController pinning already handles safe area + bars). No user-facing layout modes |
| `Moshroom/WebKit/WKWebView.swift` | exactly two gesture sources survive — the two scroll pans and one **long-press** (enabled); long-press runs `term_selectWordAt` (word under the finger → single Copy menu). Alt-screen swipe reports the mouse wheel at the **live finger position** (not a fixed origin). All tap / 1-finger-pan / pinch / hover / cmd-click-drag recognizers were removed |
| `Resources/term.js` | leave-altscreen mouse reset; native text selection off (a swipe must scroll / report wheel to TUIs, not select); the wheel event is stamped with the terminal row/col (`_setTermCoordinates`) so a swipe scrolls the cell under the finger; `term_selectWordAt(x,y)` is the only path to a selection (long-press → select word → `selectionchange` → single Copy); both `<html>` and `<body>` get the terminal background (and `TermView.setBackgroundColor:` syncs the webview's `scrollView.backgroundColor` too) so a fast TUI scroll can't flash a black strip at the top; OSC 52 clipboard write on |

## iCloud sync — one way: iCloud Drive (off by default)

One unified **"Sync with iCloud"** toggle (Settings → Configuration), **off by default**, persisted as
`MoshroomDefaults.iCloudSyncEnabled` and gated on `FileManager.default.ubiquityIdentityToken != nil`.
The legacy **CloudKit** sync (`MoshiCloudSyncHandler`, the iCloud-config storyboard scene, the
`MoshHosts` CK fields, the two old `iCloudSync`/`iCloudKeysSync` toggles) is **fully removed** — only the
`CloudDocuments` entitlement + the ubiquity container remain.

- **Hosts** — `MoshroomConfig/HostsCloudMirror.swift` (main target) mirrors the local blob
  `~/.moshroom/hosts` to `<ubiquity>/Documents/hosts`. The **local file stays the synchronous,
  authoritative source the connect path reads** (untouched); iCloud is a background mirror with
  **whole-file last-writer-wins** by modification date. It self-installs from `AppDelegate` and: **pushes**
  on every save (`MoshHosts saveHosts` posts `MoshroomHostsDidSave`), **pulls** on foreground + launch
  (`pullFromICloudIfNewerAndReload` → `startDownloadingUbiquitousItem` + `NSFileCoordinator`, then
  `[MoshHosts loadHosts]`). Toggling sync on does an immediate pull-then-push. All file work is off-main.
- **Snips** — already file-based; `SnippetsLocations` just reads the unified flag and points the folder at
  `<ubiquity>/Documents/snips`.
- **Keys & passwords stay local by design** — private keys live in the Keychain (`sh.moshroom.pkcard`),
  passwords in (`sh.moshroom.pwd`); iCloud Drive can't sync the Keychain. A synced host that uses a key or
  password is set up per device (expected, not a bug).
- **Caveat:** last-writer-wins can drop one side of a simultaneous offline edit on two devices, and a
  resume into a live mosh before re-toggling won't have re-pulled — both acceptable for v1.
- **Must be verified on 2 devices** (sync is unverifiable on one). Compiles clean; device testing pending.

## Third-party & external dependencies

Moshroom is **pure GPLv3 under "Moshroom" copyright** — all prior third-party-app branding and its
App-Store-exception text have been removed (with the original author's permission), so `COPYING` and
`about.html` are now plain GPLv3 + the legally-required third-party sections only. App, scheme, module,
source folder, the `.moshroom` runtime dir, `moshroom_*_main` command symbols, `MOSHROOM_*` build vars,
framework modules, and the ~86 `BK*`/`BLK*` ObjC classes are all Moshroom-branded.

**Bundled third-party licenses keep their own terms** (in `about.html` + per-file headers): Mosh
(GPLv3, with the Mosh project's own iOS/App-Store waiver — `COPYING.iOS`), libssh2, the fonts,
UICKeyChainStore, Protobuf, React, ios_system, etc. Keep these verbatim — they are legally required.

### Binary frameworks — self-hosted, slimmed, zero Blink (see `FRAMEWORKS.md`)

The app links **exactly 8** prebuilt xcframeworks (the SSH/Mosh/crypto engine + ios_system runtime):
`mosh`, `Protobuf_C_`, `LibSSH`, `libssh2`, `openssl`, `OpenSSH`, `ios_system`, `network_ios`. They are
declared in `xcfs/Package.swift` and fetched by `./get_frameworks.sh` (`swift package resolve`) into the
git-ignored `xcfs/.build/artifacts/`. **All self-hosted on this repo's own `deps-v1` GitHub release**
(no `blinksh`/`holzschu` hosting) and **slimmed to the iOS-device slice only** (no simulator/tvOS/watchOS/
macOS/Catalyst, no dSYMs → ~886 MB down to ~104 MB). Source deps: **swift-argument-parser** is Apple's
own (`.exact("0.5.0")`); **SSHConfig** is vendored in-tree at `xcfs/SSHConfig/`. The old Blink
framework-builder (`xcfs/Sources/build-project` + `FMake` + the `BlinkCore` project) is **deleted** —
there is no build-from-source step. Every ios_system command *module* the app never used (`awk`, `bc`,
`tar`, `text`, `files`, `shell`, `curl_ios`, `xxd`, `ssh_cmd`) was removed — no local iPhone shell by
design; the working commands (`ssh`/`scp`/`sftp`/`mosh`/`config`/…) are Moshroom's own in-executable
`*_main`s. To update a framework (only ever needed for a security bump — watch `openssl 1.1.1w`, which
is EOL), follow the recipe in `FRAMEWORKS.md`.

## Recommended next (do WITH device testing)

1. **Composer suggestion caching** — `_commandSuggestions` calls `MoshkitorSnips.flat()` (a synchronous snippets-dir enumeration) on every keystroke. Only bites with many snips, and only if typing feels laggy. Safe to cache: `flat()` returns just `(label, url)` — **no file content** (content is read fresh in `_applySuggestion`), and matching is by filename label, so a cache can never serve stale *content*; key it on the snips root + subfolder mtimes (catches add/remove/rename) or a short TTL. Deferred as a *measured* optimization — confirm the lag on-device before adding the moving part.
2. **Soft-keyboard accessory (never shown under `scratchOnly`)** — the dead web-keyboard JS
   (`blink-uio.min.js`) and its `kb.html` loader (`_loadKB`) were removed. What remains is **load-bearing,
   not dead**: `SmarterTermInput` (the terminal's input sink) inherits from `KBWebView : KBWebViewBase :
   WKWebView`, which provide its responder/copy/paste plumbing; `KBView` holds the `KBTraits`
   (hardware-keyboard-attached state the shortcuts read); `KBTraits`/`KBDevice` feed the hardware-keyboard
   shortcuts (kept — Settings → Keyboard). The only still-dead bit is the accessory *bar*
   (`KBAccessoryView`/`KBProxy`), but it's woven into `SmarterTermInput` — extracting it risks the core
   input for marginal gain, so it stays (inert, not a bug). **Do WITH device testing** if ever touched.
3. **Candidate-cruft commands (`udptunnel`, `xcall`) — KEPT for now** — both are niche and unused by the
   core remote-agent flow: `udptunnel` is a UDP-over-TCP relay, `xcall` is x-callback-url automation.
   They still build and ship; flagged here as candidates for a possible future removal, not removed yet.

## On-device debugging (the pro method)

`print`/`NSLog` go to the **unified log**, which `idevicesyslog` does NOT relay on modern iOS; `log
collect` needs **root**; `idevicescreenshot` needs the Developer disk image mounted. The reliable,
no-root, works-over-WiFi technique that nailed every hard bug here (the Moshnector race, the restore
failure, the Copy-menu validation) is **write-to-Documents + pull-with-devicectl**:

1. **Instrument** — append diagnostic lines to the app's `Documents/` (works because `Info.plist` has
   `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`). A 3-line file-append helper:
   ```swift
   func _mdbg(_ s: String) {
     let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("moshdbg.txt")
     guard let d = ("\(s)\n").data(using: .utf8) else { return }
     if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; h.seekToEndOfFile(); h.write(d) } else { try? d.write(to: url) }
   }
   ```
   (ObjC: `NSFileHandle fileHandleForWritingAtPath:` on `NSSearchPathForDirectoriesInDomains(NSDocumentDirectory…)`.)
   Log *decisions and ordering* — which trigger fired, a predicate's sub-values, `sessionNil=…`, etc.
2. **Reproduce** — `xcrun devicectl device process launch --terminate-existing --device <UDID> com.alvarofranz.moshroom`
   (a `--terminate-existing` relaunch reproduces the state-restoration path, which is where the nasty
   bugs live — not a fresh install).
3. **Pull** — `xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier com.alvarofranz.moshroom --source Documents/moshdbg.txt --destination <local>`.
4. **Read** the trace, find the exact failing line, fix, repeat. **Strip all `_mdbg`/`moshdbg` before shipping.**

`idevicescreenshot -n -u <udid>` (libimobiledevice over network) is a fallback for *visual* checks,
but needs the dev image. `idevice_id -n` lists the network UDID.

## License

GPLv3 (`COPYING`, plain GNU GPLv3 text — no app-specific addendum) + per-file copyright headers
under "Moshroom" copyright. Stays GPLv3 **by choice** — the original author permitted relicensing, but
GPL is kept for consistency. Bundled third-party components keep their own licenses (Mosh's GPLv3 iOS
waiver, fonts, etc.) as noted above.
