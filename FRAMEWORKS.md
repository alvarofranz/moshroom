# Moshroom — binary dependencies

Everything Moshroom links, in one place. **100% self-hosted, zero third-party hosting.**

Moshroom is today an **iPhone/iPad (arm64) app**. Every prebuilt xcframework here is currently **slimmed to
the iOS-device slice only** — no simulator / tvOS / watchOS / macOS / Mac-Catalyst slices and no `dSYMs`.
That took the bundle from **~886 MB → ~104 MB** on disk (and ~40 MB zipped). See **Roadmap A** below — that
slimming is what we selectively undo to enable Mac Catalyst.

## How it works

`./get_frameworks.sh` runs `swift package resolve` inside [`xcfs/`](xcfs/Package.swift). That:

1. Downloads the 8 binary `.xcframework`s below from **this repo's own release** (`deps-v1`) into
   `xcfs/.build/artifacts/` (git-ignored). The Xcode project links them from there.
2. Checks out Apple's **swift-argument-parser** into `xcfs/.build/checkouts/`.

`SSHConfig` is **vendored in-tree** ([`xcfs/SSHConfig/`](xcfs/SSHConfig)) — no download at all.

There is **no build-from-source step and no framework-builder tooling** — the manifest just points at
prebuilt, self-hosted zips.

## The 8 binary frameworks (release `deps-v1`)

The SSH/Mosh/crypto engine + the ios_system command runtime. Moshroom's own features are the only things
that use them (audited — see the API-surface notes at the bottom). The **Catalyst slice** column is the
status of the *upstream* release zip these were built from (see Roadmap A).

| Framework | Version | What it is | Upstream Catalyst slice? | Our code calls it? | License |
|---|---|---|---|---|---|
| `mosh` | 1.4.0 | Mosh (mobile shell) client | **YES** (`ios-arm64_x86_64-maccatalyst`) | tiny (`mosh_main`) | GPLv3 |
| `Protobuf_C_` | 3.21.1 | Google Protocol Buffers **C++** (mosh's wire lib; the `_C_` is a naming quirk, NOT the protobuf-c project) | **YES** | no (link-only) | BSD-3 |
| `LibSSH` | 0.9.8 | libssh — the interactive SSH **and** SFTP stack (`import LibSSH`) | **YES** | **heavy** (~100 fns, 11 files) | LGPLv2.1 |
| `libssh2` | 1.9.0 | libssh2 — **vestigial**, no direct calls (SFTP actually runs on LibSSH); candidate to drop | **YES** | no | BSD-3 |
| `openssl` | 1.1.1w | Crypto backend for the SSH libs | **NO** (rebuild) | no (link-only) | Apache-2.0 |
| `OpenSSH` | 8.9.0 (8.9p1) | Key/agent parsing (`sshkey_*`/`sshbuf_*`/`sshsig_*`) — a **library**, not a process | **NO** (rebuild) | yes (`SSHKeys.swift`) | BSD-style |
| `ios_system` | 3.0.3 | Command runtime — the `moshroom>` prompt dispatcher | **YES** | yes (dispatch + stdio) | BSD-3 |
| `network_ios` | 0.3 | Networking shim for ios_system | **NO** (rebuild) | no (link-only) | BSD-3 |

> **Versions are OLD and pinned by checksum.** They work and are fine for years, but they are **not current**
> and this is a **security** matter, not a functional one:
> - ⚠️ **`openssl` 1.1.1w is EOL** (end of the 1.1.1 line since 2023-09-11 — no more fixes).
> - **`libssh2` 1.9.0 is from 2019**; **`LibSSH` 0.9.8** and **`OpenSSH` 8.9p1** are 2022-era.
> - `mosh` 1.4.0 is the **latest** mosh release; `Protobuf_C_`/`ios_system`/`network_ios` move slowly.
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

### Removed 2026-07-07 — dead SwiftPM packages (Blink Shell heritage, 0 code imports)

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

## Roadmap A — Mac Catalyst (planned; frameworks are the gate)

Goal: a **real native Mac app** (Catalyst, `-macabi`, Intel + Apple Silicon), not "Designed for iPad".
The **only** framework blocker is the missing `maccatalyst` slice — and the CLAUDE.md premise that "Catalyst
can never link the device-only frameworks" is **self-imposed**: our slimming step *deleted* Catalyst slices
that upstream already ships. Verified by downloading each upstream zip at our pinned version:

- **5 already ship a fat `ios-arm64_x86_64-maccatalyst` slice → just re-extract, don't rebuild:**
  `libssh2`, `LibSSH`, `mosh`, `Protobuf_C_`, `ios_system`.
- **3 do not → rebuild with `.Catalyst` enabled (all EASY, no novel porting):**
  `openssl`, `OpenSSH`, `network_ios`.

### Re-slice recipe (the 5) — the inverse of our slimming step

Modify the slimming recipe below to **KEEP** the `ios-arm64_x86_64-maccatalyst` slice instead of deleting it:
re-download the upstream fat `.xcframework.zip` (URLs below), keep both the `ios-arm64/` and
`ios-arm64_x86_64-maccatalyst/` slice folders + their `AvailableLibraries` entries in the xcframework's
`Info.plist`, drop only simulator/tvOS/etc. Re-zip, `swift package compute-checksum`, host on a new
`deps-v2` release, update `xcfs/Package.swift`.

### Rebuild recipe (the 3) — FMake with Catalyst

Blink builds these via per-library repos using **FMake** (which has first-class Catalyst:
`-target <arch>-apple-ios14.0-macabi`). For each: clone the builder, add `.Catalyst` to its platforms array,
`swift run`, then slim + host + re-pin as above.
- `openssl` — `blinksh/openssl-apple` `build-libssl.sh` already carries `mac-catalyst-{x86_64,arm64}`
  plumbing (unshipped). If rebuilding anyway, do it as part of **Roadmap B** (OpenSSL 3.x).
- `OpenSSH` — `blinksh/openssh-apple`: switch `[.iPhoneOS, .iPhoneSimulator]` → include `.Catalyst`.
  It's a library (key parsing), so the iOS fork/exec worry is moot; Catalyst is *less* sandboxed than iOS.
- `network_ios` — `holzschu/network_ios`: add `.Catalyst`; **smoke-test it** (raw BSD networking is the one
  place a macabi API-availability quirk could surface). Precedent: sibling `ios_system` builds Catalyst clean.

Upstream release URLs (pinned versions): libssh2 `blinksh/libssh2-apple` v1.9.0 · LibSSH `blinksh/libssh-apple`
v0.9.8 · mosh `blinksh/mosh-apple` v1.4.0+blink-18.4.5 · Protobuf_C_ `blinksh/protobuf-apple` v3.21.1 ·
ios_system `holzschu/ios_system` v3.0.3 · openssl `blinksh/openssl-apple` v1.1.1w · OpenSSH
`blinksh/openssh-apple` v8.9.0 · network_ios `holzschu/network_ios` v0.3.

> **Hazard:** `leetal/ios-cmake` #172 mis-targets MacCatalyst x86_64 as `-apple-macos` (won't link as
> Catalyst). Blink's FMake builders avoid it via explicit `-target …-macabi`. Read builders at the **pinned
> tag**, not `main` (e.g. `libssh-apple` `main` has since moved to libssh 0.12 + OpenSSL 3).

The app-level Catalyst work (project settings, entitlements, native menu bar, distribution) lives in
**CLAUDE.md → "Mac Catalyst — roadmap"**.

## Roadmap B — OpenSSL 3.x security bump (planned; separable from Catalyst)

Catalyst does **not** need this — the slices exist at current versions. This is the EOL-openssl fix, and it's
**coupled**: bumping `openssl` forces minimum co-versions.

| Component | Bump to | Note |
|---|---|---|
| `openssl` | **3.5.x LTS** (e.g. 3.5.7) | supported to 2030; via Blink's `krzyzanowskim/OpenSSL` (3.x) train |
| `libssh2` | **1.11.1** | 1.9.0 predates OpenSSL 3; ≥1.10.0 required |
| `LibSSH` | **0.11.x** | 0.10.0 is the OpenSSL-3 floor; **big API jump from 0.9.8** — see risk |
| `OpenSSH` | **stay 8.9p1**, rebuilt vs OpenSSL 3.x | Blink maintains iOS patches only for 8.9p1; ≥8.0 supports OpenSSL 3; our code binds ~26 private symbols — do **not** jump to 10.x |
| `mosh` / `Protobuf_C_` | stay 1.4.0 / **3.21.x** | no newer mosh; protobuf must stay pre-Abseil (C++11) for mosh 1.4 |

> ⚠️ **Critical-path risk — LibSSH 0.9.8 → 0.11/0.12:** ~100 call sites across 11 `SSH/*.swift` files
> (async SFTP API, `ssh_*_callbacks_struct` layouts, known-hosts enums). **Even Blink has not migrated their
> own app to 0.12 yet** — no reference implementation. Do it on a branch, lean on the symbol inventory, and
> **device-test the full SSH/SFTP handshake**. This is why Roadmap B is separate from (and after) Catalyst.

New App Store peajes when adopting OpenSSL 3.x: privacy manifest (`PrivacyInfo.xcprivacy`, else ITMS-91061),
framework signature (ITMS-91065), export compliance (`ITSAppUsesNonExemptEncryption`).

---

## Slimming recipe / updating — when and how

You **never need to rebuild for the app to keep working** — pinned by version + checksum. Rebuild only for
**newer versions** (a security decision) or to add the **Catalyst slice** (Roadmap A).

To refresh, bump, or re-slice a framework:

1. Get an iOS `.xcframework` for the target version (Blink's `*-apple` release asset, or build it).
2. Slim it: keep only the wanted slices in the `.xcframework`'s `Info.plist` `AvailableLibraries` — **for
   iOS-only keep `ios-arm64`; for Catalyst ALSO keep `ios-arm64_x86_64-maccatalyst`** — delete the rest and
   any `dSYMs`/`.bcsymbolmap`.
3. `zip -r name.xcframework.zip name.xcframework`, then `swift package compute-checksum name.xcframework.zip`.
4. `gh release upload deps-v2 name.xcframework.zip --repo alvarofranz/moshroom --clobber`.
5. Update the version/URL/checksum in [`xcfs/Package.swift`](xcfs/Package.swift).
6. `./get_frameworks.sh && ./deploy.sh`.
