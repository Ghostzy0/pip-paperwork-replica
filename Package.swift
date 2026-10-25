// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PaperworkReplica", platforms: [.macOS(.v14)], products: [
    .library(name: "PaperworkCore", targets: ["PaperworkCore"]),
    .executable(name: "Paperwork", targets: ["Paperwork"])
], targets: [
    .target(name: "PaperworkCore", exclude: ["Resources"], linkerSettings: [.linkedFramework("PDFKit"), .linkedFramework("Vision"), .linkedFramework("AppKit")]),
    .executableTarget(name: "Paperwork", dependencies: ["PaperworkCore"]),
    .testTarget(name: "PaperworkCoreTests", dependencies: ["PaperworkCore"], exclude: ["Fixtures"])
])
