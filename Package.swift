// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Earbar",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TandemCore", targets: ["TandemCore"]),
               .executable(name: "Earbar", targets: ["Earbar"])],
    targets: [.target(name: "TandemCore"),
              .executableTarget(name: "Earbar", dependencies: ["TandemCore"],
                                linkerSettings: [.linkedFramework("IOBluetooth")]),
              .testTarget(name: "TandemCoreTests", dependencies: ["TandemCore"]),
              .testTarget(name: "EarbarTests", dependencies: ["Earbar", "TandemCore"])],
    swiftLanguageModes: [.v5]
)
