// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Nevermore", defaultLocalization: "en", platforms: [.macOS(.v26)],
    products: [.executable(name: "Nevermore", targets: ["NevermoreApp"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3"),
        .package(url: "https://github.com/socketio/socket.io-client-swift.git", exact: "16.1.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1"),
        .package(url: "https://github.com/nodes-app/swift-markdown-engine.git", exact: "0.14.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.7.3")
    ],
    targets: [
        .target(name: "RavenProtocol", dependencies: [.product(name: "SocketIO", package: "socket.io-client-swift")]),
        .target(name: "CPreviewTransport", linkerSettings: [.linkedLibrary("curl")]),
        .target(name: "NevermoreCore", dependencies: ["RavenProtocol", "CPreviewTransport", .product(name: "GRDB", package: "GRDB.swift"), "SwiftSoup", .product(name: "Markdown", package: "swift-markdown")], resources: [.process("Resources")]),
        .executableTarget(name: "NevermoreApp", dependencies: ["NevermoreCore", "RavenProtocol", .product(name: "Sparkle", package: "Sparkle"), .product(name: "MarkdownEngine", package: "swift-markdown-engine")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "RavenProtocolTests", dependencies: ["RavenProtocol"]),
        .testTarget(name: "NevermoreCoreTests", dependencies: ["NevermoreCore"])
    ], swiftLanguageModes: [.v6])
