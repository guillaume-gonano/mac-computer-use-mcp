// swift-tools-version: 6.0
import PackageDescription

// Mac Computer Use MCP: lets AI agents read and drive macOS app windows through the accessibility API, in the
// background (the user's pointer and keyboard are left alone). ComputerUseCore holds the engine, the MCP server and
// the line protocol; the executable is the command-line entry point.
let package = Package(
    name: "MacComputerUseMCP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mac-computer-use-mcp", targets: ["mac-computer-use-mcp"]),
        .library(name: "ComputerUseCore", targets: ["ComputerUseCore"])
    ],
    targets: [
        .target(name: "ComputerUseCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "mac-computer-use-mcp", dependencies: ["ComputerUseCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ComputerUseCoreTests", dependencies: ["ComputerUseCore"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
