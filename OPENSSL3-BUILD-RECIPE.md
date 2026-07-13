# OpenSSL 3 / LibSSH 0.12 crypto-stack rebuild — the working recipe

Branch `openssl3-libssh-bump`. This is the **proven, hands-on** recipe that produced a Catalyst
build linking the full OpenSSL-3 SSH stack (2026-07-13). Environment: macOS, Xcode 26.5, cmake +
autoconf + perl present. All work in a scratchpad; final xcframeworks land in
`xcfs/.build/artifacts/xcfs/<name>/<name>.xcframework` (the path the pbxproj links).

Slices built: **`ios-arm64` (device) + `ios-arm64-maccatalyst` (Apple-Silicon Mac)**. No
simulator, no Intel-macabi (matches deps-v2 policy).

## Versions
- **openssl 3.5.4** (LTS) — from stock `openssl/openssl` `openssl-3.5.4`.
- **libssh 0.12.0** — our vendored patched libssh 0.12.0 (the PATCHED fork: it keeps
  the custom callbacks Moshroom's SSH layer needs — `session_exception_function`,
  `set_proxycommand_function`, `ssh_set_agent_callback`, `ssh_client_send_keepalive` — plus the
  Objective-C `IO` socket class in `socket.m`, and stock `sftp_aio`). Stock libssh will NOT work:
  it lacks those callbacks.
- **libssh2 1.11.1** — stock `libssh2/libssh2` (only `ssh-copy-id` uses it).
- **OpenSSH 8.9p1** — stock `openssh/openssh-portable` `V_8_9_P1`, built as its internal
  `libssh.a` + `libopenbsd-compat.a` + `ssh-sk.o` (we only use `sshkey_*`/`sshbuf_*`/
  `ssh_digest_alg_by_name`/`sshsk_sign` — key parsing + agent, NOT the ssh binary).

## 1. openssl 3.5.4 (both slices, static)
```
# ios-arm64
./Configure ios64-xcrun no-shared no-tests no-legacy no-async -mios-version-min=15.0 --prefix=<out-ios>
make -j build_libs && make install_dev
# maccatalyst (openssl has no macabi target → inject the triple via CC)
CC="clang -target arm64-apple-ios15.0-macabi -isysroot $(xcrun --sdk macosx --show-sdk-path)" \
  ./Configure darwin64-arm64-cc no-shared no-tests no-legacy no-async --prefix=<out-macabi>
make -j build_libs && make install_dev
```
The app links openssl as a **dylib framework** (not static): merge per slice with
`clang -dynamiclib -Wl,-all_load libssl.a libcrypto.a -install_name @rpath/openssl.framework/openssl`.

## 2. libssh 0.12 (both slices, static) — our patched fork
cmake, `-DBUILD_SHARED_LIBS=OFF -DWITH_GSSAPI=OFF -DWITH_SERVER=OFF -DWITH_ZLIB=OFF
-DWITH_EXAMPLES=OFF -DUNIT_TESTING=OFF -DWITH_NACL=OFF -DWITH_PCAP=OFF`, pointing
`OPENSSL_ROOT_DIR/OPENSSL_*_LIBRARY` at the openssl build. macabi: `-DCMAKE_SYSTEM_NAME=Darwin`
+ `-DCMAKE_C_FLAGS="-target arm64-apple-ios15.0-macabi -isysroot <macos sdk>"`; ios:
`-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64
-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0`. **Their `ssh` target links as a dylib and pulls the ObjC
runtime** (socket.m/session.m) → don't build the executable/shared target. Instead
`cmake --build . --target ssh` to compile the objects, then archive them yourself:
`ar qc libssh.a src/CMakeFiles/ssh.dir/**/*.o` (72 objects; includes the `IO` class from socket.m).

## 3. libssh2 1.11.1 (both slices) — stock
cmake `-DBUILD_SHARED_LIBS=OFF -DCRYPTO_BACKEND=OpenSSL -DENABLE_ZLIB_COMPRESSION=OFF` vs the openssl build. Trivial.

## 4. OpenSSH 8.9p1 internal libs (both slices) — stock, PATCHED configure
```
autoreconf
# configure rejects openssl 3.5 → widen the version check in ./configure:
#   replace  300*)   ;;   with  30*)    ;; # any 3.x
CC="clang -target <triple> -isysroot <sdk>" CFLAGS="... -I<openssl>/include" LDFLAGS="... -L<openssl>/lib" \
  ./configure --host=aarch64-apple-darwin --with-ssl-dir=<openssl> --without-zlib-version-check --disable-utmp
make libssh.a                    # openssh core key lib
make -C openbsd-compat libopenbsd-compat.a   # portability shims (closefrom, explicit_bzero, EVP_CIPHER_CTX_set_iv, ...)
clang ... -c ssh-sk.c            # security-key signing (sshsk_sign) — not in libssh.a
```
**macabi vs ios gotchas** (configure runs on the host, so macabi is easy but ios needs care):
- ios `config.h`: `#undef HAVE_UTMP_H HAVE_UTMPX_H HAVE_LASTLOG_H HAVE_READPASSPHRASE
  HAVE_READPASSPHRASE_H` (host has them, iOS doesn't); stub `platform-tracing.c` (ptrace);
  compile openbsd-compat `.c` DIRECTLY with the ios triple (the Makefile re-appends configure's
  `-target macabi` to CFLAGS, so `make -C` produces macabi objects even with a CC override — bypass it);
  `arc4random.c` is native on iOS (skip); provide a tiny `closefrom` shim (no `libproc.h` on iOS).
- Merge: `OpenSSH-final.a` = openssh `libssh.a` objects + openbsd-compat objects + `ssh-sk.o`.

## 5. Headers (framework packaging)
- The Mac filesystem is **case-insensitive**, so `<libssh/x.h>` resolves to `LibSSH.framework` and
  `<openssl/x.h>` to `openssl.framework` by name. Flat `Headers/` + `module <Name> { umbrella "." export * }`.
- OpenSSH headers are NOT self-contained: prepend `#include <sys/types.h>` + `<stddef.h>` +
  `<stdint.h>` + `<stdio.h>` to each (size_t/u_int/u_char/uint*_t).
- openssl 3.5 `configuration.h` differs per slice → each xcframework slice carries its own headers
  (no dispatcher needed). openssl framework is DYLIB; on Catalyst it needs the **versioned** bundle
  layout (`Versions/A/…` + symlinks) — reuse the deps-v2 openssl.xcframework structure and swap only
  the binary + headers per slice.

## 6. The symbol-collision fix (critical)
libssh AND openssh both bundle the same OpenBSD symbols (`match_hostname`, `match_pattern_list`,
`match_pattern`, `ssh_init`, `ssh_free`, `channel_new`, `channel_free`, `bcrypt_pbkdf`, `Blowfish_*`)
as globals → duplicate-symbol link errors. The app uses these FROM libssh (the SSH transport);
openssh's copies are internal to its key handling. Fix: **merge all OpenSSH objects into ONE
relocatable object with `ld -r` and localize the collision set** so they're internal-but-resolvable
and not exported:
```
ld -r -arch arm64 *.o -unexported_symbols_list collisions.txt -o OpenSSH-merged.o
```
where `collisions.txt` = intersection of libssh's exported `T` symbols ∩ openssh's exported `T`
symbols (11 symbols) + the 3 `match_*`. Compute it with `comm -12`. Also **exclude** `dns.o` +
`getrrsetbyname.o` (SSHFP DNS, unused — pull `res_9_*`) and `match.o` isn't needed globally.

## 7. Swift migration (the app side — SSH/*.swift)
- **SFTP.swift**: the patched `sftp_async_write`/`sftp_async_write_end` (id model) → stock
  `sftp_aio_begin_write`/`sftp_aio_wait_write` (opaque `sftp_aio` handle). `inflightWrites` becomes
  `[(aio: OpaquePointer?, len: Int)]`; begin_write returns bytes QUEUED (may be < requested) so
  accounting sums real bytes. Reads unchanged (`sftp_async_read*` is stock). `SSH_AGAIN` is a plain
  `Int32` in Swift → `rc == Int(SSH_AGAIN)`.
- **SSHClient.swift**: reverse-forward callback renamed + widened: type
  `ssh_channel_open_request_forward_callback` → `ssh_channel_open_request_forwarded_tcpip_callback`,
  field `channel_open_request_forward_function` → `channel_open_request_forwarded_tcpip_function`,
  closure sig `(session, port, userdata)` → `(session, destAddr, destPort, origAddr, origPort, userdata)`
  (use `destPort`). Everything else (`session_exception_function`, `set_proxycommand_function`,
  `ssh_set_agent_callback`, `ssh_client_send_keepalive`) is UNCHANGED because our patched 0.12 fork keeps them.

## 7b. One more app-side fix found by device verification
- **SSHClient.swift**: libssh 0.11+ no longer derives the per-user known_hosts path from
  `SSH_OPTIONS_SSH_DIR` alone at write time — `ssh_session_update_known_hosts` fails ("Error
  updating known_hosts file") on first connect to a new host. Fix: also set
  `SSH_OPTIONS_KNOWNHOSTS` to `<sshDir>/known_hosts`. Without it, accepting an unknown host errors
  instead of saving the key.

## 8. App Store delivery gotchas (found 2026-07-13, after the first 1.0.3 upload)

A Catalyst RUN and a green `xcodebuild build`/`archive` do NOT prove the archive will DELIVER.
Both 1.0.3 archives passed archiving but failed at delivery, each for a different reason. Both
are now fixed and verified in the built binaries (iOS + Catalyst). Diagnosed by pulling the Xcode
Cloud logs via the App Store Connect API (JWT signed with the `KFU79QBU22` team key + issuer id;
`/v1/ciBuildActions/<id>/issues` for the headline, `/artifacts` for the LOG_BUNDLE + the exported
`app-store.zip` IPA to `nm`).

**iOS — `ITMS-90338 Non-public API usage: SSH.framework/SSH __progname`.** OpenSSH's `log.c`
(merged into `OpenSSH-final.a`, which the app's `SSH` framework target statically links) references
the BSD global `__progname` to prefix log lines. On Apple platforms `__progname` is a NON-PUBLIC
runtime symbol, so it stays an *unresolved import* in `SSH.framework` and App Store static analysis
rejects the upload. The old deps-v2 LibSSH prebuilt didn't have this; our OpenSSH-from-source rebuild
introduced it. **Fix (app-side, no framework rebuild): `SSH/SSHProgname.c` defines
`char *__progname = "moshroom";`** in the `SSH` target. That turns the dangling import into our own
data symbol — `nm` then shows `___progname` as `D` (defined), not `U`. Standard documented fix.
Verify: `nm -u <app>/Frameworks/SSH.framework/SSH | grep progname` must be EMPTY. (Only `__progname`
was flagged; `___assert_rtn`, `_getprogname`, the `__sFILE`/stdin-stdout Swift accessors are all
PUBLIC and shipped fine in 1.0.2 — don't chase them.)

**macOS — `Exporting for App Store Distribution failed` / "archive contains invalid products".**
The openssl **dylib** framework's Catalyst slice needs the versioned macOS bundle layout with
SYMLINKS (`openssl -> Versions/Current/openssl`, `Headers`/`Resources` -> `Versions/Current/...`,
`Versions/Current -> A`). The deps-v3 zip had been made with plain `zip -rX`, whose missing `-y`
**dereferenced those symlinks into real duplicated files** → not a valid macOS framework bundle →
export rejects the whole archive. iOS never hit this (its frameworks are flat). The static
frameworks (LibSSH/libssh2/OpenSSH `.a`) are flat too — only the openssl DYLIB needs symlinks.
**Fix: re-zip the openssl xcframework with `zip -y -rX` (symlinks preserved), `gh release upload
deps-v3 openssl.xcframework.zip --clobber`, bump the openssl checksum in `xcfs/Package.swift`,**
then clear SwiftPM state (`~/Library/Caches/org.swift.swiftpm`, `~/Library/org.swift.swiftpm`,
`xcfs/.build/workspace-state.json`, `xcfs/Package.resolved`) and re-resolve — SwiftPM refuses a
changed-checksum artifact until the recorded state is gone. Verify: the openssl.framework EMBEDDED
in the built Catalyst `.app` (`Contents/Frameworks/openssl.framework`) has `openssl` and
`Versions/Current` as symlinks.

## Status — VERIFIED WORKING on Mac Catalyst against the real server (2026-07-13)
- ✅ Catalyst + iOS builds link clean with the full openssl-3 stack.
- ✅ **Full interactive SSH session** to `awesomehost` (212.227.90.133, OpenSSH 9.9): connect →
  KEX (openssl 3.5.4) → host-key accept + known_hosts write → auth → PTY → live shell
  `[demo@moshroom-demo ~]$` with the server MOTD.
- ✅ **SFTP** over the new stack: Moshxplore listed `/home/demo` (directoryFilesAndAttributes).
- ✅ Cross-validated: a standalone C test with the built openssl 3.5.4 + libssh got the SAME
  ed25519 host key SHA256 as the system `ssh` (`X2thZcII9SqpG4ToeJ8GFI0HzF7A0UlD3yUFVXYw+EA`).
- ✅ **SFTP write** round-trip verified: Moshxplore edit-save on README.txt uploaded via the
  sftp_aio write path — server confirmed 200→240 bytes + fresh mtime.
- ✅ **deps-v3 published + wired**: all 7 xcframeworks on the `deps-v3` GitHub release (the 4 rebuilt
  + the 3 unchanged carried over verbatim from deps-v2, identical checksums). `xcfs/Package.swift`
  points at a single `deps-v3` base; `swift package resolve` fetches + checksum-verifies clean, and
  iOS + Catalyst build green from the freshly-resolved artifacts. (Zips must be built WITHOUT
  AppleDouble `._*` files AND WITH symlinks preserved — use
  `find -name '._*' -delete; xattr -cr; zip -y -rX`, NOT `ditto -c -k` (leaks `._callbacks.h`,
  breaks the umbrella module) and NOT plain `zip -rX` (the missing `-y` **dereferences symlinks
  into real duplicated files** — see the "invalid products" gotcha in §8).)
- **Shipped to TestFlight 2026-07-13**: merged to `main` (deps-v3 wired) → Xcode Cloud builds the
  iOS + Catalyst archives → TestFlight. **iOS on-device verification happens there** (Álvaro's own
  TestFlight testing — that's the plan of record; Catalyst was fully verified here).
- Post-ship watch items: **mosh** on iOS (awesomehost's UDP 60000-61000 range is confirmed open, and
  mosh's SSH bootstrap uses this same verified libssh stack — its data transport is mosh's own
  AES-OCB, independent of OpenSSL), and a broader multi-server SSH/SFTP soak.
- Note during testing: the demo VPS applied OpenSSH **PerSourcePenalties** IP bans under repeated
  attempts (native `ssh` also refused "Not allowed at this time") — wait for the ban to clear, don't
  probe repeatedly.
- ⏳ Runtime verification pending: the demo VPS `awesomehost` had this Mac's IP under OpenSSH
  PerSourcePenalties during testing (native `ssh` also refused with "Not allowed at this time"), so a
  clean SSH/SFTP round-trip must be re-run once the ban clears. **DO NOT publish deps-v3 or merge to
  main until a real SSH + SFTP + mosh session is verified on device.**
- deps-v3 hosting: 4 xcframeworks zipped + checksummed, ready to `gh release create deps-v3` and wire
  into `xcfs/Package.swift` AFTER verification.
