// swift-tools-version:5.3
import PackageDescription

// A small, dependency-free SSH config parser, vendored into Moshroom as a local Swift package so the
// whole app is self-contained in this repo.

let package = Package(
  name: "SSHConfig",
  products: [
    .library(name: "SSHConfig", targets: ["SSHConfig"]),
  ],
  targets: [
    .target(name: "SSHConfig", dependencies: []),
  ]
)
