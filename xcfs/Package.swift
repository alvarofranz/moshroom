// swift-tools-version:5.3
import PackageDescription

// Moshroom's binary dependency manifest — the ONLY frameworks the app links: the SSH/Mosh/crypto
// engine and the ios_system command runtime. `swift package resolve` (get_frameworks.sh) fetches them
// into .build/artifacts, which the Xcode project references. See FRAMEWORKS.md for what each is, its
// version, upstream source, and when to update.
//
// 100% self-hosted: every xcframework is mirrored to THIS repo's own GitHub release (deps-v1), slimmed
// to the iOS-device slice only (no simulator/tvOS/watchOS/macOS/Catalyst, no dSYMs). No third-party
// hosting, no Blink. The lone source dependency is Apple's own swift-argument-parser; SSHConfig is
// vendored in-tree (../xcfs/SSHConfig).

let base = "https://github.com/alvarofranz/moshroom/releases/download/deps-v1"

var binaryTargets: [PackageDescription.Target] = [
  ("Protobuf_C_", "ffe1dd7f45d7ebc8e7a7f9066235b501e5c3917fbffdc08ac7a6db3067c99430"),
  ("mosh",        "37e3c01e799c985ec53f585a0e3e0253235dd5341178d29a0a0050e86fe4a279"),
  ("LibSSH",      "ed0c78cd145ccd39464995da0e4af321b5cb3550fb1cef331952140f92b98fa8"),
  ("OpenSSH",     "477545d0101fdbf38da1061deb45e315cc0c28495bf56bf164f44111ff3f9da2"),
  ("openssl",     "87c789e29d10dfae71a0254468868e2deaa119471a1d2b5c37a614374be32a2e"),
  ("libssh2",     "cac1d0ded4523c48c727cd9cbb27717f0aefd94df9f426506cc4d7222c2a2acf"),
  ("ios_system",  "d826660338e250e14f80c4a8fbf5785071f6ae00d2ea70ff54d284dd60775d50"),
  ("network_ios", "6d62db3e939c4b8c18a23018eb560085f5c45b9ee00fd7bfc6a5e389d9da6dec"),
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
