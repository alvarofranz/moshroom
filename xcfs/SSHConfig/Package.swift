// swift-tools-version:5.3
import PackageDescription

// Vendored into Moshroom (was github.com/blinksh/SSHConfig @ 0.0.5) — a small, dependency-free SSH
// config parser. Kept as a local Swift package so the whole app is self-contained in this repo.

let package = Package(
  name: "SSHConfig",
  products: [
    .library(name: "SSHConfig", targets: ["SSHConfig"]),
  ],
  targets: [
    .target(name: "SSHConfig", dependencies: []),
  ]
)
