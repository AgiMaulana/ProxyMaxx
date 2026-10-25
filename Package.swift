// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ProxyMaxx",
    platforms: [.macOS(.v14)],
    products: [
        // SwiftPM product name; the bundle script installs this binary as `ProxyMaxx`
        // inside the .app.
        .executable(name: "ProxyMaxxApp", targets: ["ProxyMaxxApp"]),
        .executable(name: "proxymaxx-cli", targets: ["ProxyMaxxCLI"]),
        // The browser companion's native messaging host: Chrome launches it, it answers
        // from the state file the app publishes. See Browser/README.md.
        .executable(name: "proxymaxx-browser-host", targets: ["BrowserHost"]),
        .library(name: "ProxyKit", targets: ["ProxyKit"]),
        .library(name: "CertKit", targets: ["CertKit"]),
        .library(name: "FlowKit", targets: ["FlowKit"]),
        .library(name: "RuleKit", targets: ["RuleKit"]),
        .library(name: "SystemKit", targets: ["SystemKit"]),
        .library(name: "CodeGenKit", targets: ["CodeGenKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.8.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/facebook/zstd.git", from: "1.5.7"),
        .package(url: "https://github.com/f-meloni/SwiftBrotli.git", from: "0.1.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        /// Product identity shared by every component that writes user data.
        .target(name: "Branding"),

        .target(
            name: "FlowKit",
            dependencies: [
                .product(name: "libzstd", package: "zstd"),
                .product(name: "SwiftBrotli", package: "SwiftBrotli"),
            ]
        ),

        .target(
            name: "CertKit",
            dependencies: [
                "Branding",
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        .target(
            name: "RuleKit",
            dependencies: ["FlowKit", "Branding", .product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),

        .target(
            name: "ProxyKit",
            dependencies: [
                "FlowKit",
                "CertKit",
                "RuleKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        .target(name: "SystemKit", dependencies: ["Branding"]),
        .target(name: "CodeGenKit", dependencies: ["FlowKit"]),

        .executableTarget(
            name: "ProxyMaxxApp",
            dependencies: ["ProxyKit", "FlowKit", "CertKit", "RuleKit", "SystemKit", "CodeGenKit", "Branding"]
        ),

        // The companion CLI (`proxymaxx-cli`), a headless driver for AI agents. It lives
        // outside Sources on purpose: like Android/, it is a companion project that
        // reuses ProxyKit/CertKit/RuleKit/FlowKit instead of duplicating any of them.
        .executableTarget(
            name: "ProxyMaxxCLI",
            dependencies: ["ProxyKit", "FlowKit", "CertKit", "RuleKit", "SystemKit", "Branding"],
            path: "cli",
            exclude: ["README.md"]
        ),

        // Like cli/ and Android/, the browser companion is a separate project that reuses
        // SystemKit rather than duplicating it. Only the host half is Swift; the extension
        // itself lives in Browser/ProxyMaxxExtension.
        .executableTarget(
            name: "BrowserHost",
            dependencies: ["Branding"]
        ),

        .testTarget(
            name: "ProxyKitTests",
            dependencies: [
                "ProxyKit", "CertKit", "FlowKit", "RuleKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .testTarget(
            name: "FlowKitTests",
            dependencies: [
                "FlowKit",
                .product(name: "SwiftBrotli", package: "SwiftBrotli"),
            ]
        ),
        .testTarget(
            name: "RuleKitTests",
            dependencies: ["RuleKit", .product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
        .testTarget(name: "CodeGenKitTests", dependencies: ["CodeGenKit", "FlowKit"]),
        .testTarget(name: "CertKitTests", dependencies: ["CertKit"]),
        .testTarget(name: "SystemKitTests", dependencies: ["SystemKit"]),
    ]
)
