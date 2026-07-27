// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "RemoteDesktop",
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "RDPDomain", targets: ["RDPDomain"]),
        .library(name: "RDPTransport", targets: ["RDPTransport"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"])
    ],
    targets: [
        .target(name: "RDPDomain", path: "Sources/RDPDomain"),
        .target(
            name: "Diagnostics",
            dependencies: ["RDPDomain"],
            path: "Sources/Diagnostics"
        ),
        .target(
            name: "RDPTransport",
            dependencies: ["RDPDomain", "Diagnostics"],
            path: "Sources/RDPTransport"
        ),
        .target(
            name: "Persistence",
            dependencies: ["RDPDomain", "Diagnostics"],
            path: "Sources/Persistence",
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Security")]
        ),
        .testTarget(
            name: "RDPDomainTests",
            dependencies: ["RDPDomain"],
            path: "Tests/Unit/RDPDomainTests"
        ),
        .testTarget(
            name: "RDPTransportTests",
            dependencies: ["RDPTransport"],
            path: "Tests/Unit/RDPTransportTests"
        ),
        .testTarget(
            name: "DiagnosticsTests",
            dependencies: ["Diagnostics"],
            path: "Tests/Unit/DiagnosticsTests"
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence"],
            path: "Tests/Unit/PersistenceTests"
        )
    ]
)
