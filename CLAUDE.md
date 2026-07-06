# Moshroom — the brain

**Rule your agents from anywhere.** Moshroom is an iOS terminal for **remote agentic coding from
the iPhone/iPad**: drive an AI agent (e.g. Claude Code) running on a remote machine over SSH/Mosh.
The terminal is a read-only transcript; everything you *send* goes through touch-first UI
(composer, quick keys, attach, snips).

- Bundle id: `com.alvarofranz.moshroom` · Team: `6STWTTP329` · Display name: **Moshroom**
- App Store: **v1.0 submitted for review 2026-07-03** (app id `6785947810`). Subtitle:
  *"Rule your agents from anywhere"* (EN) / *"Doma a tus agentes, donde sea"* (ES).
  iPad 13" screenshots live in the listing; app previews (videos) intentionally skipped.

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

### Xcode Cloud (CI/CD → TestFlight / App Store)

Every push to `main` triggers an Xcode Cloud build (workflow **Default**, iOS Archive, distribution
prep = App Store Connect) that delivers to TestFlight + App Store, and a **TestFlight internal
testing post-action** adds every build to the internal group automatically (configured in the
workflow's Post-Actions — without it builds sit "Ready to Submit", never installable). One
`ci_scripts/` script does the setup Xcode Cloud can't infer:
- `ci_post_clone.sh` — recreates the gitignored `developer_setup.xcconfig` from the workflow's
  **Environment Variables** (`TEAM_ID`, `BUNDLE_ID`, `GROUP_ID`, `CLOUD_ID`, `KEYCHAIN_ID1`) + the fixed
  build flags, then runs `swift package resolve` inside `xcfs/` (the `get_frameworks.sh` step — Xcode
  Cloud never runs it and `xcfs/.build` isn't in the repo, so the 8 xcframeworks + argument-parser must
  be fetched here, else "no XCFramework found" / "Missing package product 'ArgumentParser'").

**Build numbers are Xcode Cloud's, not the project's**: for archives with distribution prep, Xcode
Cloud stamps its own per-app, monotonically increasing counter as `CFBundleVersion` and CLOBBERS
whatever `CURRENT_PROJECT_VERSION` says (a pre-xcodebuild date-stamping script existed and was dead
weight — deleted). Early manual Xcode uploads used date-style numbers (…20260701), so the counter
was raised above them to **20270000** in ASC → Xcode Cloud → **Settings → Build Number** (numbers
only look like dates; it's a plain +1 counter). TestFlight compares the version string first and
the build number only within the same version, so mixing schemes inside one version train is what
caused the "install previous build?" prompts.

**Files that MUST stay committed for the cloud build** (gitignoring them → red builds):
`Moshroom.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (the SPM lock — Xcode
Cloud disables auto-resolution), `Resources/AppFont/app-font-{regular,bold}.ttf` (Info.plist `UIAppFonts`,
JetBrains Mono), and `main.m`. The GitHub remote must be plain `github.com` (an SSH host alias makes
Xcode Cloud mis-detect it as Enterprise) — this repo forces the right key via a repo-local
`core.sshCommand`, leaving `~/.ssh/config` untouched.

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
  **Tabs** (left) + **Settings** (right). Tabs opens **Moshtabs** (`MoshtabsController`, in this
  file): the full-screen tab manager — full-width rows with the WHOLE title visible (wrapping),
  active tab filled mushroom, per-row ×, long-press rename (the alert presents from the top VC),
  New tab row; adaptive colors + the system ✕ Close, matching the other full screens. **Tab titles**
  resolve custom name → **connected host alias** (`TermController.moshroomConnectedHost`) → the
  program's OSC title → "shell", so a tab connected to `myserver` IS "myserver" to the user.
- `Moshnector.swift` — **Moshnector**: the fresh-terminal quick-connect card. On a shell at the
  `moshroom>` prompt it offers one-tap connect (mode SSH/Mosh + a saved host alias → types
  `<mode> <alias>\r`). Plain overlay (never first responder, so typed text is never swallowed);
  shown whenever a terminal is a fresh, idle, unconnected `moshroom>` shell. The reveal is one method —
  `showMoshnectorIfIdle()` (checks `TermController.moshroomIsFreshShell`) — fired from triggers that
  cover every ordering deterministically, **no poll, no race**: (1) the session going live —
  `TermController._startSession()`/`resume(with:)` post `MoshroomPromptReadyNotification` right after
  `_session` is populated; (2) the shell printing its prompt (`MCPSession._postPromptReady`, e.g. after
  a command or when an ssh/mosh child exits); (3) view lifecycle (`viewDidAppear`, `TermViewReady`).
  All idempotent — shows for a fresh shell, hides for a connected ssh/mosh, hidden the instant you
  type, tap a key, switch tab, or connect. The tap also records the host on the tab
  (`noteConnection` → `moshroomConnectedHost`, Moshdrop's upload target AND the tab title source);
  the back-at-prompt clear honors a **3s grace window** (`moshroomConnectedHostSetAt`) so a reveal
  trigger racing the command spawn can't wipe a just-tapped connection.
  > **Restore path:** `TermController.resume(with:)` restores the UI state only if present and
  > **falls back to starting a fresh `MCPSessionPayload`** when the archive has no session — so a
  > relaunched terminal is always live (never a dead, sessionless prompt) and the card appears on a
  > normal (restored) launch, not just a first install.
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
- `Moshlight.swift` — **Moshlight**: the in-tree syntax highlighter + line-number gutter behind
  Moshxplore's code view. **One palette — "Mushroom"** — warm dark (soil bg, cream text, amanita
  keywords, honey strings, moss numbers, cap-cream keys, spore comments); there is deliberately
  NO light/dark pair, no theme picker, and it never follows the system appearance. Zero deps: a
  single-pass tokenizer (comments/strings mask first, then keywords/numbers/keys outside them),
  language by extension/leaf-name/shebang (`Moshlight.rules`), ~18 language families; unknown
  content stays plain cream. Colors are presentation attributes only — the byte-faithful editing
  round-trip is untouched. `MoshlightGutter` numbers LOGICAL lines (wrapped lines keep one number)
  drawing only the visible fragments via TextKit, so 1 MB files scroll clean;
  `highlightMaxLength` (300k UTF-16) stands the tokenizer down on huge files (still dark, still
  numbered). Editing re-highlights debounced (250ms) via `UITextViewDelegate`; the editor keyboard
  is dark; edit mode keeps the amanita ring.
- `Moshxplore.swift` — **Moshxplore**: a remote file explorer (download direction; the mirror of
  Moshdrop's upload). Presents **full screen** (`MoshxploreController` in a nav controller,
  `.fullScreen`, title + the same system ✕ Close as Settings) from the **folder button in the top
  bar, left of Settings** (`openMoshxplore`); works over **any tab, needs no shell/connection**;
  fresh instance per open, torn down on Close. Three steps: **host picker** (saved aliases, reuses
  `moshroomSavedHostAliases`; refreshes live on `MoshroomHostsDidSave` via `reloadHostsIfVisible`,
  only while that step is showing) → **browser** (`MoshxploreEntryRow`: name + size·date + chevron;
  folders descend, files open detail; dirs-first sort; an up button + a switch-host button) →
  **file detail** (`MoshxploreDetailView`: multiline name, size·date·path, an **inline preview**,
  and a bottom action row: **Download**, joined by **Edit** when the text decodes
  cleanly). **Text detection is universal, not a list**: anything that isn't an image or a
  known-binary extension (`MoshxplorePreview.binaryExt`) and fits 1 MB is fetched as candidate
  text — jsonl/ndjson, dotfiles, extensionless scripts, whatever — and the bytes decide (NUL
  sniff ⇒ "Binary content" placeholder; strict decode ⇒ editable; else lossy read-only preview).
  **Edit-in-place**: Edit turns the preview textarea into the editor right there
  (autocorrect/smart-quotes off), the bottom row steps aside, and a **compact Save capsule
  appears top-right next to the file name** (the name wraps onto multiple lines rather than
  fighting it for width); Save spins "Saving…" while it SFTP-uploads the bytes back onto the same
  remote path over the session's connection (`MoshxploreSession.upload`, `create` =
  O_CREAT|O_TRUNC overwrite) and lands back in view mode (Edit/Download again) with fresh
  size·date; back-while-editing = cancel (restores the fetched text, stays on the file); back
  after a save re-lists the folder. **Byte-faithful round-trip** (`MoshxploreTextFile`): UTF-8 BOM
  stripped for display + re-emitted on save, strict UTF-8 with lossless Latin-1 fallback (chars the
  original encoding can't hold upgrade to UTF-8), CRLF normalized to \n for editing and restored on
  save. While the keyboard is up the card pins above it (`keyboardLayoutGuide`, 999-priority) and
  the 990-priority preview height is what compresses. Listing is SFTP
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
  Dismissed (and the SSH connection torn down) on close or tab switch. **Text size is a user
  setting** (Settings → **Moshxplore** → Text Size: absolute px + stepper, exactly like the
  terminal's Font Size; defaults 15 px iPhone / 17 px iPad, range 12–24, key
  `MoshxploreTextSize`, 0 = never set): every explorer font routes through
  `MoshxploreStyle.font()/monoFont()` — one knob, layouts authored at 15 so all sizes shift
  together and proportions hold. The explorer is built fresh per open, so a change applies next
  open; anything font-like must NOT be a stored `static let` (it would pin the first launch's
  size — `codeFont` is computed for exactly this reason).

### Connection UX (ssh & mosh)

- **A connect can never look dead.** `mosh` prints `Connecting to <host>...` before the SSH
  bootstrap, prints the error **immediately** in the sink on failure, and stops its bootstrap
  runloop explicitly (`CFRunLoopStop`) so the command always returns to the prompt — the historical
  silent-hang (error swallowed because `SSHClient.run()` never exited) is fixed in
  `Moshroom/Commands/mosh/mosh.swift`.
- **ConnectTimeout defaults to 15s** (`SSH/SSHClientConfig.swift`) — a mobile client should report
  a dead host quickly; per-host ssh-config `ConnectTimeout` still overrides.
- **Host aliases can never contain whitespace**: the alias field in
  `Settings/ViewControllers/MoshHosts/HostView.swift` hyphenates spaces live as you type (pasted
  text included), and `_validate()` returns Bool — **Save is blocked** when validation fails (it
  used to show the error and save anyway).

### Big screens / iPad (incl. "My Mac (Designed for iPad)")

Same app, same logic, use the canvas: the **Moshkitor composer, Settings, Moshxplore and Moshtabs
present full screen on every device** (`.fullScreen` — no sheets, no centered cards; close is the
system ✕ / chevron + Esc). Only Quick Connect and the key pads float over the terminal. Moshxplore
uses **adaptive semantic colors** (`MoshxploreStyle`), lists run the full height, the detail viewer
bleeds edge-to-edge, images render centered at max 60% of the viewer per dimension, and the
explorer's bottom rides `keyboardLayoutGuide`. The Quick Connect card keeps its fixed light card
look over the terminal, filling the phone width and capping at a centered 640pt column on iPad.
`TARGETED_DEVICE_FAMILY = 1,2` (one universal binary); **Catalyst is OFF** (it can never link
against the device-slice-only frameworks) and **Designed for iPad is ON** — that's how to test iPad
layout without an iPad: Xcode → "My Mac (Designed for iPad)" → ⌘R (the Simulator can't be used; the
frameworks carry no simulator slice by design).

**Running the app on the Mac from the CLI** (used for iPad-size App Store screenshots): build with
`xcodebuild -scheme Moshroom -destination 'id=<mac-device-id>'` (the id from `-showdestinations`;
the `variant=Designed for [iPad,iPhone]` spelling does NOT parse — the inner comma splits the
specifier). `open` on the built .app fails ("incorrect executable format") — wrap it:
`MoshroomMac.app/Wrapper/Moshroom.app` + a `WrappedBundle` symlink, place it under `~/Applications`
(from /tmp it hangs as a zombie), `lsregister -f` after every replace, then `open` it. Capture by
**window id** (`CGWindowListCopyWindowInfo`, owner is "MoshroomMac", works even when occluded),
crop the 28pt title bar, scale with `sips` to exactly 2732×2048 — and **flatten the alpha channel**
(window captures carry transparency; App Store Connect rejects it). The window is 4:3 at
1120×868pt for best upscale quality. Deleting
`<container>/Library/Application Support/sessions` + `Saved Application State/…savedState` gives a
truly fresh launch (card visible). Synthetic clicks (CGEvent) work; synthetic keystrokes do NOT
reach the terminal input path on the Mac build (composer/Settings fields take them fine).

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
| `Moshroom/SpaceController.swift` | `Moshkeys.install` + `Moshnector.install`; the viewport is pinned inside the safe area with a strip reserved for the floating bars (**76pt top / 56pt bottom**); first-responder handling; `pressesBegan` → `MoshroomKeyboard`; `moshroomTabs()` builds the tab list + titles |
| `Moshroom/Terminal/LayoutConstraintManager.m` | one fixed terminal layout: a small uniform inset (the SpaceController pinning already handles safe area + bars). No user-facing layout modes |
| `Moshroom/WebKit/WKWebView.swift` | exactly two gesture sources survive — the two scroll pans and one **long-press** (enabled); long-press runs `term_selectWordAt` (word under the finger → single Copy menu). Alt-screen swipe reports the mouse wheel at the **live finger position** (not a fixed origin). All tap / 1-finger-pan / pinch / hover / cmd-click-drag recognizers were removed |
| `Resources/term.js` | leave-altscreen mouse reset; native text selection off (a swipe must scroll / report wheel to TUIs, not select); the wheel event is stamped with the terminal row/col (`_setTermCoordinates`) so a swipe scrolls the cell under the finger; `term_selectWordAt(x,y)` is the only path to a selection (long-press → select word → `selectionchange` → single Copy); both `<html>` and `<body>` get the terminal background (and `TermView.setBackgroundColor:` syncs the webview's `scrollView.backgroundColor` too) so a fast TUI scroll can't flash a black strip at the top; OSC 52 clipboard write on |

## iCloud sync — iCloud Drive mirror with conflict merge (off by default)

One **"Sync with iCloud"** section in Settings. Toggle persisted as
`MoshroomDefaults.iCloudSyncEnabled`, gated on `ubiquityIdentityToken != nil`. Only the
`CloudDocuments` entitlement + ubiquity container are used (no CloudKit).

- **Hosts** — `Moshroom/HostsCloudMirror.swift` mirrors the local blob `~/.moshroom/hosts` to
  `<ubiquity>/Documents/hosts`. The **local file stays the synchronous, authoritative source the
  connect path reads**. One sync path, `reconcile()` (didSave / foreground / launch / Sync Now):
  - **Normal case**: whole-file newest-wins by mtime — edits AND deletions propagate (only one side
    changed since this device's `marker*` UserDefaults dates).
  - **True conflict** (both sides changed since last sync, or iCloud forked the file into
    `NSFileVersion` unresolved versions): the lists are **merged** — union by alias; the same alias
    edited on both sides resolves by per-host **`MoshHosts.lastModified`** (stamped in
    `saveHost:`/`_replaceHost:`, encoded/decoded; nil = oldest). A conflict can never delete data.
    Conflict versions are folded in, marked resolved, and pruned. **Clobber valves**: an empty list
    never replaces a non-empty one through plain newest-wins, and an adopt that would silently drop
    more than half of this device's hosts re-routes through the merge too. `HostListView` refreshes
    live off `didChangeNotification` when a pull lands while the screen is open.
  - Settings shows **Sync Now** with a live **"Syncing…"** state, a best-fit **"last synced Xm/Xh/Xd
    ago"** label, and a one-line **honest readout of what the pass saw and did** — "2 hosts ·
    14 snips · fetched from iCloud / sent to iCloud / merged both sides / up to date / nothing to
    sync yet", or "iCloud container unavailable" (`isSyncing`, `lastSyncDate`, `lastSyncSummary`,
    `syncStateNotification`). Each pass also nudges every iCloud snip placeholder to download.
- **Snips** — file-based; `SnippetsLocations` points the folder at `<ubiquity>/Documents/snips`
  (iOS syncs the folder itself; Sync Now just nudges a download).
- **Keys & passwords ride the iCloud Keychain** (`kSecAttrSynchronizable`, E2E-encrypted — NOT the
  iCloud Drive mirror above, and independent of the Sync toggle): imported keys
  (`MoshPubKey.m .pkcard` service) and host passwords (`MoshHosts.m .pwd` service) survive an app
  reinstall and follow the user's devices. No migration code by choice (pre-release, no users) —
  anything saved by older builds stays readable (UICKeyChainStore reads match
  `kSecAttrSynchronizableAny`) but only syncs once re-saved. **Secure Enclave keys are
  hardware-bound by design and never leave the device** (`SEKey.swift`, untouched).
- **Cross-device wall clocks** order the whole-file LWW and per-host merge — skew beyond seconds could
  pick the "wrong" newer side, never lose both. **Must be verified on 2 devices.**

## Third-party & external dependencies

Moshroom is **pure GPLv3 under Moshroom copyright** (`COPYING`, plain GNU GPLv3 text). App, scheme,
module, source folder, the `.moshroom` runtime dir, `moshroom_*_main` command symbols, `MOSHROOM_*`
build vars and framework modules are all Moshroom-branded. **Bundled third-party licenses keep
their own terms** (in `about.html` + per-file headers): Mosh (GPLv3, with the Mosh project's own
iOS/App-Store waiver — `COPYING.iOS`), libssh2, the fonts, UICKeyChainStore, Protobuf, React,
ios_system, etc. Keep these verbatim — they are legally required.

### Binary frameworks — self-hosted, slimmed (see `FRAMEWORKS.md`)

The app links **exactly 8** prebuilt xcframeworks (the SSH/Mosh/crypto engine + ios_system runtime):
`mosh`, `Protobuf_C_`, `LibSSH`, `libssh2`, `openssl`, `OpenSSH`, `ios_system`, `network_ios`. They are
declared in `xcfs/Package.swift` and fetched by `./get_frameworks.sh` (`swift package resolve`) into the
git-ignored `xcfs/.build/artifacts/`. **All self-hosted on this repo's own `deps-v1` GitHub release**
(no third-party hosting) and **slimmed to the iOS-device slice only** (no simulator/tvOS/watchOS/
macOS/Catalyst, no dSYMs → ~886 MB down to ~104 MB). Source deps: **swift-argument-parser** is Apple's
own (`.exact("0.5.0")`); **SSHConfig** is vendored in-tree at `xcfs/SSHConfig/`. There is no
build-from-source step. Every ios_system command *module* the app never used (`awk`, `bc`,
`tar`, `text`, `files`, `shell`, `curl_ios`, `xxd`, `ssh_cmd`) was removed — no local iPhone shell by
design; the working commands (`ssh`/`scp`/`sftp`/`mosh`/`config`/…) are Moshroom's own in-executable
`*_main`s. To update a framework (only ever needed for a security bump — watch `openssl 1.1.1w`, which
is EOL), follow the recipe in `FRAMEWORKS.md`. Versions in the current slices: libssh 0.9.8
(interactive ssh — **verified compatible with OpenSSH 9.9/RHEL9 servers**, full trace-proven
handshake), libssh2 1.9.0 (SFTP paths).

## Debugging connectivity — read this before blaming the app

Modern OpenSSH (9.8+) ships **PerSourcePenalties**: failed auths AND bannerless TCP probes (an `nc`
banner read counts) get the source IP temporarily refused — first `Not allowed at this time`
pre-banner, later connections just dropped mid-handshake ("Socket error: disconnected"). This
masquerades perfectly as an app bug and it is not one. **Never diagnose by repeatedly probing the
same server from the tested IP** — each probe extends the ban. Verify from a different IP, or wait
a few minutes between single attempts, or check the server's `sshd` logs. (Confirmed the hard way
2026-07-03: a full evening of "the app can't connect to modern servers" that was really the demo
VPS banning the Mac's IP.) Also remember mosh needs **UDP 60000–61000** open on the server's
firewall — the SSH bootstrap succeeding + a silent wait means UDP is blocked, not mosh broken.

## On-device debugging (the pro method)

`print`/`NSLog` go to the **unified log**, which `idevicesyslog` does NOT relay on modern iOS; `log
collect` needs **root**; `idevicescreenshot` needs the Developer disk image mounted. The reliable,
no-root, works-over-WiFi technique is **write-to-Documents + pull-with-devicectl**:

1. **Instrument** — append diagnostic lines to the app's `Documents/` (works because `Info.plist` has
   `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`). A 3-line file-append helper:
   ```swift
   func _mdbg(_ s: String) {
     let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("moshdbg.txt")
     guard let d = ("\(s)\n").data(using: .utf8) else { return }
     if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; h.seekToEndOfFile(); h.write(d) } else { try? d.write(to: url) }
   }
   ```
   Log *decisions and ordering* — which trigger fired, a predicate's sub-values, `sessionNil=…`, etc.
   For SSH issues, the `SSHClientConfigProvider.logger` sink already routes libssh's log to the
   terminal — set the host's `LogLevel` (or temporarily force `loggingVerbosity` to `.trace` in
   `MoshSSHHost.sshClientConfig`) and mirror the sink into `_mdbg` to capture a full handshake trace.
2. **Reproduce** — `xcrun devicectl device process launch --terminate-existing --device <UDID> com.alvarofranz.moshroom`
   (a `--terminate-existing` relaunch reproduces the state-restoration path, which is where the nasty
   bugs live — not a fresh install).
3. **Pull** — `xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier com.alvarofranz.moshroom --source Documents/moshdbg.txt --destination <local>`.
4. **Read** the trace, find the exact failing line, fix, repeat. **Strip all `_mdbg`/`moshdbg` before shipping.**

On the Mac (Designed for iPad) it's simpler: the container lives at
`~/Library/Containers/<UUID>/Data` (find it by `MCMMetadataIdentifier` = the bundle id) — read
`Documents/moshdbg.txt` directly. `idevicescreenshot -n -u <udid>` (libimobiledevice over network)
is a fallback for *visual* checks on-device, but needs the dev image; `idevice_id -n` lists the
network UDID.

## Recommended next (do WITH device testing)

0. **`LocalFile.read(max:)` readLoop race** (`MoshroomFiles/LocalFiles.swift`) — reading a local
   file via the `Reader` protocol fails with EBADF under an eager consumer (the readLoop
   demand/semaphore machinery, whose own TODOs admit fragility). No production caller — app file
   reads go through `writeTo`, which uses bounded demand and works — so the API is kept only for
   protocol conformance. Fix the demand handling before ever building on `read(max:)`.
   (The repo carries no test targets by deliberate choice — verification is driving the real app.)

1. **Composer suggestion caching** — `_commandSuggestions` calls `MoshkitorSnips.flat()` (a synchronous
   snippets-dir enumeration) on every keystroke. Only bites with many snips, and only if typing feels
   laggy. Safe to cache: `flat()` returns just `(label, url)` — **no file content** (content is read
   fresh in `_applySuggestion`), and matching is by filename label, so a cache can never serve stale
   *content*; key it on the snips root + subfolder mtimes (catches add/remove/rename) or a short TTL.
   Deferred as a *measured* optimization — confirm the lag on-device before adding the moving part.
2. **Soft-keyboard accessory (never shown under `scratchOnly`)** — what remains of the legacy web
   keyboard is **load-bearing, not dead**: `SmarterTermInput` (the terminal's input sink) inherits
   from `KBWebView : KBWebViewBase : WKWebView`, which provide its responder/copy/paste plumbing;
   `KBView` holds the `KBTraits` (hardware-keyboard-attached state the shortcuts read);
   `KBTraits`/`KBDevice` feed the hardware-keyboard shortcuts (kept — Settings → Keyboard). The only
   still-dead bit is the accessory *bar* (`KBAccessoryView`/`KBProxy`), but it's woven into
   `SmarterTermInput` — extracting it risks the core input for marginal gain, so it stays (inert,
   not a bug). **Do WITH device testing** if ever touched.

## License

GPLv3 (`COPYING`, plain GNU GPLv3 text) + per-file copyright headers under Moshroom copyright.
As sole copyright holder of Moshroom's own code, Alvaro Franz additionally grants permission to
distribute through Apple's App Store (an additional permission under GPLv3 §7 — see README).
Bundled third-party components keep their own licenses (Mosh's GPLv3 iOS waiver, fonts, etc.) as
noted above.
