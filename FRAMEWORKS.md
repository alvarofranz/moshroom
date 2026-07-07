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
| `LibSSH` | 0.9.8 | libssh — the interactive SSH **and** SFTP stack (`import LibSSH`) | upstream fat macabi | **heavy** (~100 fns, 11 files) | LGPLv2.1 |
| `libssh2` | 1.9.0 | libssh2 — **vestigial**, no direct calls (SFTP actually runs on LibSSH); candidate to drop | upstream fat macabi | no | BSD-3 |
| `openssl` | 1.1.1w | Crypto backend for the SSH libs | **rebuilt** arm64 macabi | no (link-only) | Apache-2.0 |
| `OpenSSH` | 8.9.0 (8.9p1) | Key/agent parsing (`sshkey_*`/`sshbuf_*`/`sshsig_*`) — a **library**, not a process | **rebuilt** arm64 macabi | yes (`SSHKeys.swift`) | BSD-style |
| `ios_system` | 3.0.3 | Command runtime — the `moshroom>` prompt dispatcher | upstream fat macabi | yes (dispatch + stdio) | BSD-3 |

**`network_ios` 0.3 was dropped in deps-v2** — a link-only dep (0 code refs; `ios_system`'s macabi lib has
no undefined network symbols) whose bundled bind9 sources don't compile under Catalyst's module system.
Removed from `xcfs/Package.swift` and the app project. **Note:** the rebuilt `openssl`/`OpenSSH` slices are
**arm64-macabi only** (Apple-Silicon Catalyst) — Intel Macs would need an added `x86_64` macabi build.

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

## Mac Catalyst — how it was built (DONE 2026-07-07)

Moshroom is a **real native Mac Catalyst app** (`-macabi`). Verified on Apple Silicon: `xcodebuild
-destination 'platform=macOS,variant=Mac Catalyst'` → **BUILD SUCCEEDED**, and the produced `.app`
(platform 6 / MacCatalyst binary, Mac-style `Contents/`) **launches and runs** (the `dlsym(*_main)` command
dispatch works under macabi). The iOS build still succeeds from the same `deps-v2` frameworks.

**How each framework got its `maccatalyst` slice** — downloaded each upstream zip at our pinned version and
inspected slices:

- **5 already shipped a fat `ios-arm64_x86_64-maccatalyst` slice → re-extracted, not rebuilt:**
  `libssh2`, `LibSSH`, `mosh`, `Protobuf_C_`, `ios_system` (our slimming had been deleting that slice).
- **2 rebuilt from source (Blink's FMake `*-apple` builders, `.Catalyst` added), arm64-macabi:**
  - `openssl` (`blinksh/openssl-apple` @ v1.1.1w): on Xcode 26.5, `config/20-all-platforms.conf` hardcoded
    `ios13.0-macabi` (clang 21 rejects "invalid version number") and `build-libssl.sh` set
    `IOS_MIN_SDK_VERSION=26.0` → both bumped to **15.0**; `create-openssl-framework.sh` only iterated
    `iPhoneOS`/`iPhoneSimulator` → added `Catalyst` to `ALL_SYSTEMS`.
  - `OpenSSH` (`blinksh/openssh-apple` @ v8.9.0): FMake hardcodes `ios14.0-macabi` + builds `x86_64` too →
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
**CLAUDE.md → "Mac Catalyst"**.

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
