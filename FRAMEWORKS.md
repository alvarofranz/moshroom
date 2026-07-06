# Moshroom — binary dependencies

Everything Moshroom links, in one place. **100% self-hosted, zero third-party hosting.**

Moshroom is an **iPhone (arm64) app**. Every prebuilt xcframework here is **slimmed to the iOS-device
slice only** — no simulator / tvOS / watchOS / macOS / Mac-Catalyst slices and no `dSYMs`. That took the
bundle from **~886 MB → ~104 MB** on disk (and ~40 MB zipped).

## How it works

`./get_frameworks.sh` runs `swift package resolve` inside [`xcfs/`](xcfs/Package.swift). That:

1. Downloads the 8 binary `.xcframework`s below from **this repo's own release** (`deps-v1`) into
   `xcfs/.build/artifacts/` (git-ignored). The Xcode project links them from there.
2. Checks out Apple's **swift-argument-parser** into `xcfs/.build/checkouts/`.

`SSHConfig` is **vendored in-tree** ([`xcfs/SSHConfig/`](xcfs/SSHConfig)) — no download at all.

There is **no build-from-source step and no framework-builder tooling** — the manifest just points at
prebuilt, self-hosted zips.

## The 8 binary frameworks (release `deps-v1`)

All are standard open-source libraries — the SSH/Mosh/crypto engine + the ios_system command runtime.
Moshroom's own features are the only things that use them (verified: nothing else is linked).

| Framework | Version | What it is | Upstream project | License |
|---|---|---|---|---|
| `mosh` | 1.4.0 | Mosh (mobile shell) client | [mobile-shell/mosh](https://github.com/mobile-shell/mosh) | GPLv3 |
| `Protobuf_C_` | 3.21.1 | Protocol Buffers — required by mosh | [protocolbuffers/protobuf](https://github.com/protocolbuffers/protobuf) | BSD-3 |
| `LibSSH` | 0.9.8 | libssh — the SFTP/SSH stack (`import LibSSH`) | [libssh.org](https://www.libssh.org) | LGPLv2.1 |
| `libssh2` | 1.9.0 | libssh2 — SSH transport | [libssh2.org](https://www.libssh2.org) | BSD-3 |
| `openssl` | 1.1.1w | Crypto | [openssl/openssl](https://github.com/openssl/openssl) | Apache-2.0 |
| `OpenSSH` | 8.9.0 | Key parsing / agent | [openssh.com](https://www.openssh.com) | BSD-style |
| `ios_system` | 3.0.3 | Command runtime — the `moshroom>` prompt dispatcher | [holzschu/ios_system](https://github.com/holzschu/ios_system) | BSD-3 |
| `network_ios` | 0.3 | Networking shim for ios_system | [holzschu/network_ios](https://github.com/holzschu/network_ios) | BSD-3 |

### Source dependencies

- **swift-argument-parser** — Apple's own, pinned `.exact("0.5.0")`
  ([apple/swift-argument-parser](https://github.com/apple/swift-argument-parser)). Used by the
  `ssh`/`mosh`/`scp` command parsers.
- **SSHConfig** — a small, dependency-free SSH-config parser, vendored in-tree at
  [`xcfs/SSHConfig/`](xcfs/SSHConfig) so the app is fully self-contained.

## What was removed (and why it was safe)

The app is a **remote-agent launcher** — you connect (`ssh`/`mosh`/`scp`/`sftp`/`config`) and do the real
work on the remote. It needs **no local iPhone shell**, so every ios_system command *module* was dropped:
`awk`, `bc`, `tar`, `text`, `files`, `shell`, `curl_ios`, `xxd`, and the never-linked `ssh_cmd`. Audit
proof: the app only ever invokes commands in two places — the SSH proxy (its own `ssh`) and the
`moshroom>` prompt (whatever the user types) — so nothing internal depended on them, and the build links
clean without them. `ssh`/`scp`/`sftp`/`mosh`/`config`/`clear`/`help`/`history` are Moshroom's own
in-executable commands, not ios_system modules.

## Updating / rebuilding — when and how

You **never need to rebuild for the app to keep working** — these are pinned by version + checksum and
are fine for years. Rebuild only when you want **newer versions**, which is a **security** decision:

- ⚠️ **`openssl` 1.1.1w is EOL** (end of the 1.1.1 line, no more fixes). This is the one to watch — if a
  serious OpenSSL CVE lands, you'll want an OpenSSL 3.x build. The rest (`mosh`, `libssh2`, `LibSSH`,
  `OpenSSH`) move slowly; update on CVEs.

To refresh or bump a framework:

1. Get an iOS `.xcframework` for the new version (build it, or grab a prebuilt one).
2. Slim it to the iOS-device slice + strip `dSYMs` (keep only the `ios-arm64*` library in the
   `.xcframework`'s `Info.plist`; delete the other slice folders and any `dSYMs`/`.bcsymbolmap`).
3. `zip -r name.xcframework.zip name.xcframework`, then `swift package compute-checksum name.xcframework.zip`.
4. `gh release upload deps-v1 name.xcframework.zip --repo alvarofranz/moshroom --clobber`.
5. Update the version + checksum in [`xcfs/Package.swift`](xcfs/Package.swift).
6. `./get_frameworks.sh && ./deploy.sh`.

The current slimmed zips are reproducible from any full xcframework with the steps above.
