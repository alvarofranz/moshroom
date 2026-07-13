// swift-tools-version:5.3
import PackageDescription

// Moshroom's binary dependency manifest — the ONLY frameworks the app links: the SSH/Mosh/crypto
// engine and the ios_system command runtime. `swift package resolve` (get_frameworks.sh) fetches them
// into .build/artifacts, which the Xcode project references. See FRAMEWORKS.md for what each is, its
// version, upstream source, and when to update.
//
// 100% self-hosted: every xcframework is mirrored to THIS repo's own GitHub release (deps-v2), slimmed
// to the iOS-device (arm64) + Mac Catalyst (arm64 macabi) slices only — no simulator/tvOS/watchOS/macOS,
// no dSYMs — so the app builds for both iPhone/iPad and native Mac Catalyst. No third-party hosting.
// The lone source dependency is Apple's own swift-argument-parser; SSHConfig is vendored in-tree
// (../xcfs/SSHConfig). network_ios was dropped in deps-v2 (unused link-only dep — see FRAMEWORKS.md).

// deps-v3 is the whole compiled-deps set: the OpenSSL-3.5.4 crypto stack (openssl + libssh 0.12 +
// libssh2 1.11.1 + OpenSSH 8.9p1, all rebuilt vs OpenSSL 3) plus the 3 unchanged frameworks carried
// over verbatim from deps-v2 (mosh, Protobuf_C_, ios_system — identical bytes/checksums). One release,
// one base URL. See FRAMEWORKS.md.
let base = "https://github.com/alvarofranz/moshroom/releases/download/deps-v3"

var binaryTargets: [PackageDescription.Target] = [
  ("Protobuf_C_", "924c5b69b1dbf1c7c06d5c0ede174aea43299af180331dbc02cfedfe7e4143ef"),
  ("mosh",        "e0427f8a953370070b3d9b715ab802b7a4154b9ac3172a193decf92df8775f8a"),
  ("ios_system",  "e8f5f5965384af82912017d716f3c56a40a45eb9cee475ce0cf4e6124e933c61"),
  ("openssl",     "7a78a1724351423666b2a1dfc5e6928baa2729020953f8d3cdf4f0a7f4e15003"),
  ("LibSSH",      "ef4da477a422e8d24dac08a185fcb17a433c9f1dfb6a4b5e7a7bd570022e35d0"),
  ("libssh2",     "f3cb7f3dd0fa5a4f501c4be1c42a948bde3562a8e200b6b9202f1151e0db3d20"),
  ("OpenSSH",     "fbdbb1ac15799dc773adebe6482573abdf1c60c1e94c3188dfab39f381fc6e2a"),
].map { name, checksum in
  PackageDescription.Target.binaryTarget(name: name, url: "\(base)/\(name).xcframework.zip", checksum: checksum)
}

_ = Package(
  name: "deps",
  platforms: [.macOS("11")],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", .exact("0.5.0")),
  ],
  targets: binaryTargets
)
