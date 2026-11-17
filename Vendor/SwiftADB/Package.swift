// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftADB",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "SwiftADB",
            targets: ["SwiftADB"]
        ),
        .library(
            name: "ADBPairing",
            targets: ["ADBPairing"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0")
    ],
    targets: [
        // MARK: - ADBPairing (SPAKE2 + Pairing Protocol)
        // Pure-Swift SPAKE2-over-Ed25519 pairing layer.
        // No external dependencies — uses CryptoKit for SHA-512, HKDF, AES-GCM.
        .target(
            name: "ADBPairing",
            dependencies: [],
            path: "Sources/ADBPairing"
        ),

        // MARK: - SwiftADB (main ADB protocol library)
        .target(
            name: "SwiftADB",
            dependencies: [
                "BigInt",
                "ADBPairing",
                .product(name: "SwiftASN1", package: "swift-asn1")
            ],
            path: "Sources/SwiftADB"
        ),

    ],
    swiftLanguageModes: [.v6]
)
