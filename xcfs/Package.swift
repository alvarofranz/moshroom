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

let base = "https://github.com/alvarofranz/moshroom/releases/download/deps-v2"

var binaryTargets: [PackageDescription.Target] = [
  ("Protobuf_C_", "924c5b69b1dbf1c7c06d5c0ede174aea43299af180331dbc02cfedfe7e4143ef"),
  ("mosh",        "e0427f8a953370070b3d9b715ab802b7a4154b9ac3172a193decf92df8775f8a"),
  ("LibSSH",      "bf8a25844ce4c854de9c8fd58caf90930aea3ba90ebd4ab7181d46b4cb00dab9"),
  ("OpenSSH",     "55dcc7ec84767aa968241c817f9df74e977f8d47249ea92ddcc2571062899faf"),
  ("openssl",     "a0cf72cc5bab66dc15781ef398bfebb9f657933c87e73dc6349bc098b0265edc"),
  ("libssh2",     "ea4ed7517743928f4fe82ff7401e6562c63d1d5f7be272bc7fc7d72f9cbe11b4"),
  ("ios_system",  "e8f5f5965384af82912017d716f3c56a40a45eb9cee475ce0cf4e6124e933c61"),
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
