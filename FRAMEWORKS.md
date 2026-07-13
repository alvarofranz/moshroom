# Moshroom — binary dependencies

Everything Moshroom links, in one place. **100% self-hosted, zero third-party hosting.**

Moshroom is an **iPhone/iPad + native Mac (Catalyst)** app. Every prebuilt xcframework here is **slimmed to
the iOS-device (arm64) + Mac-Catalyst (arm64 macabi) slices** — no simulator / tvOS / watchOS / macOS, no
`dSYMs`. **Mac Catalyst was enabled 2026-07-07** — build, link, and launch verified on Apple Silicon; see the
**Mac Catalyst** section below for exactly how the slices were produced.

## How it works

`./get_frameworks.sh` runs `swift package resolve` inside [`xcfs/`](xcfs/Package.swift). That:

1. Downloads the 7 binary `.xcframework`s below from **this repo's own release** (`deps-v2`) into
   `xcfs/.build/artifacts/` (git-ignored). The Xcode project links them from there.
2. Checks out Apple's **swift-argument-parser** into `xcfs/.build/checkouts/`.

`SSHConfig` is **vendored in-tree** ([`xcfs/SSHConfig/`](xcfs/SSHConfig)) — no download at all.

There is **no build-from-source step and no framework-builder tooling** — the manifest just points at
prebuilt, self-hosted zips.

## The 7 binary frameworks (release `deps-v2`)

The SSH/Mosh/crypto engine + the ios_system command runtime. Moshroom's own features are the only things
that use them (audited — see the API-surface notes at the bottom). Every one now carries a **Mac Catalyst
(arm64 macabi)** slice alongside the iOS-device slice.

| Framework | Version | What it is | Catalyst slice | Our code calls it? | License |
|---|---|---|---|---|---|
| `mosh` | 1.4.0 | Mosh (mobile shell) client | upstream fat macabi | tiny (`mosh_main`) | GPLv3 |
| `Protobuf_C_` | 3.21.1 | Google Protocol Buffers **C++** (mosh's wire lib; the `_C_` is a naming quirk, NOT the protobuf-c project) | upstream fat macabi | no (link-only) | BSD-3 |
| `LibSSH` | **0.12.0** (deps-v3) | libssh — the interactive SSH **and** SFTP stack (`import LibSSH`). Our vendored patched fork (keeps the custom callbacks + ObjC IO). SFTP write migrated to `sftp_aio` | **rebuilt** arm64 macabi | **heavy** (~177 lines, 17 files) | LGPLv2.1 |
| `libssh2` | **1.11.1** (deps-v3) | libssh2 — transport for `ssh-copy-id` (via SSHCopyIDSession→SSHSession); NOT vestigial, keep it | **rebuilt** arm64 macabi | via ssh-copy-id | BSD-3 |
| `openssl` | **3.5.4 LTS** (deps-v3) | Crypto backend for the SSH libs (dynamic framework) | **rebuilt** arm64 + macabi | no (link-only) | Apache-2.0 |
| `OpenSSH` | 8.9.0 (8.9p1), **vs OpenSSL 3** (deps-v3) | Key/agent parsing (`sshkey_*`/`sshbuf_*`/`sshsig_*`) — a **library**, not a process | **rebuilt** arm64 + macabi | yes (`SSHKeys.swift`) | BSD-style |
| `ios_system` | 3.0.3 | Command runtime — the `moshroom>` prompt dispatcher | upstream fat macabi | yes (dispatch + stdio) | BSD-3 |

**`network_ios` 0.3 was dropped in deps-v2** — a link-only dep (0 code refs; `ios_system`'s macabi lib has
no undefined network symbols) whose bundled bind9 sources don't compile under Catalyst's module system.
Removed from `xcfs/Package.swift` and the app project. **Note:** the rebuilt `openssl`/`OpenSSH` slices are
**arm64-macabi only** (Apple-Silicon Catalyst) — Intel Macs would need an added `x86_64` macabi build.

> **The EOL-OpenSSL security bump is DONE (deps-v3, 2026-07-13).** The SSH/crypto stack was rebuilt on
> **OpenSSL 3.5.4 LTS** (supported to 2030) + libssh 0.12 + libssh2 1.11.1 + OpenSSH 8.9p1-vs-OpenSSL-3,
> for ios-arm64 + maccatalyst, hosted on the `deps-v3` release. Verified on Catalyst end-to-end (SSH
> session + SFTP read/write); iOS on-device verification happens via TestFlight. Full reproducible recipe
> in **`OPENSSL3-BUILD-RECIPE.md`**. (`mosh` 1.4.0 is still the latest mosh; `Protobuf_C_`/`ios_system`
> carried over from deps-v2 unchanged.)
>
> See **Roadmap B** for the coordinated bump.

### Source (SwiftPM) dependencies — the real list

Corrected 2026-07-07 (this file previously claimed argument-parser was the *only* one; it was not):

- **swift-argument-parser** — Apple's own, `.exact("0.5.0")`. The `ssh`/`mosh`/`scp` command parsers.
- **SSHConfig** — vendored in-tree ([`xcfs/SSHConfig/`](xcfs/SSHConfig)), dependency-free SSH-config parser.
- **Runestone** `0.5.2` (+ its **TreeSitter** / **TreeSitterLanguages** / `TreeSitterBash*` products) — the
  code editor behind the **Snips editor** (`Moshroom/Snippets/*`). *Not* related to Moshxplore's viewer,
  which uses the in-tree **Moshlight** highlighter.
- **SwiftCBOR** (`master`) — COSE/CBOR encoding for **WebAuthn / FIDO2 security keys**
  (`Settings/.../NewSecurityKeyView.swift`, `MoshroomConfig/WebAuthnKey.swift`).

### Removed 2026-07-07 — dead SwiftPM packages (0 code imports)

Verified unused (zero `import` in the whole app) and removed from `project.pbxproj` + `Package.resolved`;
the app builds clean without them:

- **ConfettiSwiftUI** — onboarding confetti (feature gone).
- **swiftui-cached-async-image** (`CachedAsyncImage`) — remote image loading (unused).
- **Base32Kit** — Base32 for TOTP/2FA (feature gone).
- **ZIPFoundation** — zip archives (unused; was linked into 2 targets).
- **SQLite.swift** — declared but not even linked (not a Runestone transitive dep — confirmed by a clean
  package re-resolve after removal).

(RevenueCat/`purchases-ios` had already been removed earlier.)

## What was removed from ios_system (and why it was safe)

The app is a **remote-agent launcher** — you connect (`ssh`/`mosh`/`scp`/`sftp`/`config`) and do the real
work on the remote. It needs **no local iPhone shell**, so every ios_system command *module* was dropped:
`awk`, `bc`, `tar`, `text`, `files`, `shell`, `curl_ios`, `xxd`, and the never-linked `ssh_cmd`.
`ssh`/`scp`/`sftp`/`mosh`/`config`/`clear`/`help`/`history` are Moshroom's own in-executable commands.

---

## Mac Catalyst — how it was built (DONE 2026-07-07)

Moshroom is a **real native Mac Catalyst app** (`-macabi`). Verified on Apple Silicon: `xcodebuild
-destination 'platform=macOS,variant=Mac Catalyst'` → **BUILD SUCCEEDED**, and the produced `.app`
(platform 6 / MacCatalyst binary, Mac-style `Contents/`) **launches and runs** (the `dlsym(*_main)` command
dispatch works under macabi). The iOS build still succeeds from the same `deps-v2` frameworks.

**How each framework got its `maccatalyst` slice** — downloaded each upstream zip at our pinned version and
inspected slices:

- **5 already shipped a fat `ios-arm64_x86_64-maccatalyst` slice → re-extracted, not rebuilt:**
  `libssh2`, `LibSSH`, `mosh`, `Protobuf_C_`, `ios_system` (our slimming had been deleting that slice).
- **2 rebuilt from source (the `*-apple` FMake builder repos below, `.Catalyst` added), arm64-macabi:**
  - `openssl` (the `openssl-apple` FMake builder @ v1.1.1w): on Xcode 26.5, `config/20-all-platforms.conf` hardcoded
    `ios13.0-macabi` (clang 21 rejects "invalid version number") and `build-libssl.sh` set
    `IOS_MIN_SDK_VERSION=26.0` → both bumped to **15.0**; `create-openssl-framework.sh` only iterated
    `iPhoneOS`/`iPhoneSimulator` → added `Catalyst` to `ALL_SYSTEMS`.
  - `OpenSSH` (the `openssh-apple` FMake builder @ v8.9.0): FMake hardcodes `ios14.0-macabi` + builds `x86_64` too →
    patched the FMake checkout to **arm64-only @ 15.0**. macabi binaries run on the host, so `configure`
    mis-detected snprintf and set `BROKEN_SNPRINTF` → bsd-snprintf.c compiled its own vsnprintf and clashed
    with `_FORTIFY_SOURCE` → strip `BROKEN_SNPRINTF` from `config.h` after configure.
- **1 dropped:** `network_ios` — its bundled bind9 sources fail Catalyst's module compilation (`struct
  ipstat` conflicts), and it's a link-only, zero-reference dep, so it was removed entirely.

Then: slim each to iOS-device + macabi, zip, `swift package compute-checksum`, `gh release create deps-v2`,
update `xcfs/Package.swift` (URLs + checksums, network_ios removed).

> **arm64-only Catalyst (Apple-Silicon Macs).** The two rebuilt slices are arm64-macabi only; Intel-Mac
> Catalyst would need an `x86_64` macabi build of `openssl` + `OpenSSH` too (the 5 upstream already carry fat
> macabi). Acceptable for 2026; revisit if Intel support is wanted.
>
> **Hazard for future rebuilds:** `leetal/ios-cmake` #172 mis-targets MacCatalyst x86_64 as `-apple-macos`;
> read the `*-apple` builders at the **pinned tag**, not `main` (which has moved to libssh 0.12 + OpenSSL 3).

The app-level Catalyst config (project settings, entitlements, and the remaining native-feel work) lives in
the Xcode project settings (targets + entitlements) and the internal build notes.

## Roadmap B — OpenSSL 3.x security bump (✅ DONE 2026-07-13, deps-v3 — see OPENSSL3-BUILD-RECIPE.md)

> The plan below is kept as background. It was executed: openssl 3.5.4 + libssh 0.12 + libssh2 1.11.1 +
> OpenSSH 8.9p1 vs OpenSSL 3, hosted on deps-v3, wired in `xcfs/Package.swift`, verified on Catalyst,
> shipped to TestFlight for iOS on-device verification. The `OPENSSL3-BUILD-RECIPE.md` is the authoritative
> record of what was actually built and how.

Catalyst does **not** need this — the slices exist at current versions. This is the EOL-openssl fix, and it's
**coupled**: bumping `openssl` forces minimum co-versions.

> **Hands-on build attempt 2026-07-12 — what's proven, and the concrete wall.** This env can build
> (network + perl/make/cmake/autoconf + iOS/macOS SDK 26.5).
> - ✅ **openssl 3.5.4 builds clean for `ios-arm64`** from stock source, static libs, in a few minutes.
>   Exact recipe: `./Configure ios64-xcrun no-shared no-tests no-legacy no-async -mios-version-min=15.0`
>   then `make -j build_libs` → `libcrypto.a` (~8.6 MB) + `libssl.a` (~1.6 MB). macabi is the analogous
>   `Configure` with a macabi target. So the openssl foundation is a solved problem.
> - ✅ **What actually needs OpenSSL-3 rebuilds:** `LibSSH` (interactive ssh + SFTP — the main path),
>   `libssh2` (ssh-copy-id only), and the `OpenSSH` framework — which our code uses **only for
>   `sshkey_*`/`sshbuf_*` key parsing + the agent** (`SSH/SSHKeys.swift`, `SSH/Agent.swift`), NOT the ssh
>   binary (interactive ssh is `moshroom_ssh_main` over LibSSH).
> - ⛔ **The wall — OpenSSH for Catalyst vs OpenSSL 3 has no prebuilt.** The `openssh-apple`
>   `v8.9.0` prebuilt xcframework ships slices **`ios-arm64` + `ios-simulator` only — NO
>   `maccatalyst`** (verified: its `Info.plist` `AvailableLibraries`), and the published
>   `openssl-apple` is still 1.1.1w (its openssl-3 build is unpublished → unknown ABI). Moshroom SHIPS
>   Catalyst, so patched OpenSSH must be **cross-built from source for `ios-arm64_x86_64-maccatalyst` vs
>   openssl 3** — the gnarliest build (same `BROKEN_SNPRINTF` / min-version gotchas hit for the 1.1.1w
>   macabi rebuild, see above), with ~26 private symbols our code binds that must stay exported.
> - ⛔ **The other wall — verification.** A rebuilt crypto/transport stack needs byte-exact SFTP
>   (up+down) + handshake + known-hosts accept/reject + mosh, across BOTH platforms and multiple server
>   OpenSSH versions, on real hardware. Not doable headless; the demo VPS alone (PerSourcePenalties) is
>   insufficient. **Any built-but-unverified branch is DO-NOT-MERGE.**
>
> **Bottom line:** the pieces are individually tractable (openssl proven; libssh/libssh2 are cmake builds;
> the SFTP write path maps cleanly to `sftp_aio`, see below), but a correct, ABI-consistent 4-library
> stack for TWO platforms — including a from-source patched-OpenSSH macabi build — plus real-hardware
> multi-server verification is a focused, device-in-the-loop effort, not an autonomous one-shot.

| Component | Bump to | Note |
|---|---|---|
| `openssl` | **3.5.x LTS** (e.g. 3.5.7) | supported to 2030; via the `krzyzanowskim/OpenSSL` (3.x) Apple package |
| `libssh2` | **1.11.1** | 1.9.0 predates OpenSSL 3; ≥1.10.0 required |
| `LibSSH` | **0.11.x** | 0.10.0 is the OpenSSL-3 floor; **big API jump from 0.9.8** — see risk |
| `OpenSSH` | **stay 8.9p1**, rebuilt vs OpenSSL 3.x | the available iOS OpenSSH patch set targets 8.9p1; ≥8.0 supports OpenSSL 3; our code binds ~26 private symbols — do **not** jump to 10.x |
| `mosh` / `Protobuf_C_` | stay 1.4.0 / **3.21.x** | no newer mosh; protobuf must stay pre-Abseil (C++11) for mosh 1.4 |

> ⚠️ **Critical-path risk — LibSSH 0.9.8 → 0.11/0.12:** ~177 lines / 65 unique `ssh_*`/`sftp_*` symbols
> across 17 `SSH/*.swift` files, with no ready reference implementation to crib from. Do it on a branch,
> lean on the symbol inventory, and **device-test the full SSH/SFTP handshake**. This is why Roadmap B is
> separate from (and after) Catalyst.

### Concrete execution plan (assessed 2026-07-12 — read before starting)

Environment IS capable (network to GitHub, `perl`/`make`/`cmake`/`autoconf`, iOS+macOS SDK 26.5 present).
Hosting is NOT a blocker — we self-host `deps-*` releases; a `deps-v3` is one `gh release create`. The real
work, in order, and its two genuinely hard gates:

1. **`openssl` 3.5.x** — the `krzyzanowskim/OpenSSL` SPM package vends a prebuilt xcframework; confirm it
   carries BOTH `ios-arm64` and `ios-arm64-maccatalyst` slices, or rebuild via a `*-apple` FMake builder.
   A prebuilt openssl alone is NOT independently usable — the other three link against it (ABI), so all
   four must ship together.
2. **`libssh2` 1.11.x** — rebuild vs openssl 3 (cmake). Straightforward; only `ssh-copy-id`/`ssh2`/`mosh1`
   use it (see main doc — libssh2 is NOT droppable while ssh-copy-id exists).
3. **`LibSSH` 0.11.x — THE HARD GATE (custom C patch).** Our current LibSSH 0.9.8 is **patched**, not stock:
   `sftp_async_write` + `sftp_async_write_end` are declared `LIBSSH_API` in our `sftp.h` but **do not exist
   in upstream libssh** (upstream ships async *read* only; writes were sync `sftp_write`). `SFTP.swift`'s
   upload path depends on them. So a 0.11 bump must EITHER (a) re-port that async-write patch onto 0.11
   source (may not apply cleanly across two majors), OR (b) **migrate `SFTP.swift` to upstream's new
   `sftp_aio` API** (added in 0.11: `sftp_aio_begin_write`/`sftp_aio_wait_write`, and the read counterparts)
   — the cleaner long-term path, but it rewrites the SFTP async engine. The known-hosts API is already the
   modern one (`ssh_session_is_known_server`/`ssh_get_server_publickey`/`ssh_session_update_known_hosts`),
   so that part carries low risk.
4. **`OpenSSH` 8.9p1** — rebuild vs openssl 3 (autoconf). Gotchas from the last macabi rebuild recur:
   `BROKEN_SNPRINTF` mis-detection (strip from config.h post-configure), and our code binds ~26 private
   symbols that must stay exported — do NOT jump to 10.x.
5. **Swift migration** — the 177 lines; mostly signature-compatible (we already use the modern API), the
   real delta is the SFTP async engine (step 3b) if chosen.
6. **Package + host** — slim each to iOS-device + macabi, checksum, `gh release create deps-v3`, update
   `xcfs/Package.swift` URLs+checksums.
7. **THE OTHER HARD GATE — verification.** A rebuilt crypto/transport stack MUST be device-tested before it
   can merge: full SSH handshake + interactive session, **byte-exact SFTP upload (Moshdrop) AND download
   (Moshxplore)** — a mistranslation corrupts files silently — the security-critical known-hosts accept/reject
   path, and mosh over the new stack, on BOTH platforms and ideally several server OpenSSH versions. The demo
   VPS alone (with its PerSourcePenalties) is NOT sufficient coverage. **This gate is why the bump cannot be
   completed in a headless session that can't drive real multi-server SFTP verification** — build + migrate is
   doable; proving a crypto stack correct is not, here. Treat any built-but-unverified branch as **DO NOT
   MERGE** until this gate passes on real hardware.

New App Store peajes when adopting OpenSSL 3.x: privacy manifest (`PrivacyInfo.xcprivacy`, else ITMS-91061),
framework signature (ITMS-91065), export compliance (`ITSAppUsesNonExemptEncryption`).

---

## Slimming recipe / updating — when and how

You **never need to rebuild for the app to keep working** — pinned by version + checksum. Rebuild only for
**newer versions** (a security decision) or to add the **Catalyst slice** (Roadmap A).

To refresh, bump, or re-slice a framework:

1. Get an iOS `.xcframework` for the target version (a prebuilt `*-apple` release asset, or build it).
2. Slim it: keep only the wanted slices in the `.xcframework`'s `Info.plist` `AvailableLibraries` — **for
   iOS-only keep `ios-arm64`; for Catalyst ALSO keep `ios-arm64_x86_64-maccatalyst`** — delete the rest and
   any `dSYMs`/`.bcsymbolmap`.
3. `zip -r name.xcframework.zip name.xcframework`, then `swift package compute-checksum name.xcframework.zip`.
4. `gh release upload deps-v2 name.xcframework.zip --repo alvarofranz/moshroom --clobber`.
5. Update the version/URL/checksum in [`xcfs/Package.swift`](xcfs/Package.swift).
6. `./get_frameworks.sh && ./deploy.sh`.
