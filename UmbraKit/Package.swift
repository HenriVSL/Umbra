// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UmbraKit",
    platforms: [.macOS(.v13), .iOS(.v16), .visionOS(.v1)],
    products: [
        .library(name: "UmbraCore", targets: ["UmbraCore"]),
        .library(name: "UmbraServer", targets: ["UmbraServer"]),
        .library(name: "UmbraClient", targets: ["UmbraClient"]),
        .library(name: "UmbraQR", targets: ["UmbraQR"]),
        .executable(name: "umbra-server", targets: ["umbra-server"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "UmbraCore",
            dependencies: [
                // Apple platforms use CryptoKit directly; swift-crypto provides the same API on Linux.
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "UmbraNet",
            dependencies: [
                "UmbraCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .target(name: "UmbraServer", dependencies: ["UmbraCore", "UmbraNet"]),
        .target(name: "UmbraClient", dependencies: ["UmbraCore", "UmbraNet"]),
        /// QR codes and JPEG output without system libraries, so the static Linux server can draw its invite.
        .target(name: "UmbraQR"),
        .executableTarget(name: "umbra-server", dependencies: ["UmbraServer", "UmbraQR"]),
        .testTarget(
            name: "UmbraKitTests",
            dependencies: [
                "UmbraCore", "UmbraNet", "UmbraServer", "UmbraClient", "UmbraQR",
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
    ]
)
