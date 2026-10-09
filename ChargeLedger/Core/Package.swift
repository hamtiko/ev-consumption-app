// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChargeLedgerCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ChargeLedgerCore", targets: ["ChargeLedgerCore"])],
    targets: [
        .target(name: "ChargeLedgerCore"),
        .testTarget(name: "ChargeLedgerCoreTests", dependencies: ["ChargeLedgerCore"])
    ]
)
