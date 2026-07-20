// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "daw-pro",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DAWCore", targets: ["DAWCore"]),
        .library(name: "DAWEngine", targets: ["DAWEngine"]),
        .library(name: "DAWControl", targets: ["DAWControl"]),
        .library(name: "AIServices", targets: ["AIServices"]),
        .library(name: "DAWAppKit", targets: ["DAWAppKit"]),
        .executable(name: "DAWApp", targets: ["DAWApp"]),
    ],
    targets: [
        .target(name: "DAWCore"),
        // C11 stdatomic shim for render-thread-shared state (Swift 6 on the
        // macOS 14 floor has no RT-safe atomics in the SDK). DAWCore must NOT
        // depend on this — the domain stays dependency-free.
        .target(name: "CAtomics"),
        // ObjC @try/@catch barrier for the engine seam (m16-a Leg 1, the
        // CAtomics-target precedent — tiny, dependency-free, plain SwiftPM/
        // CLT). Swift cannot unwind NSExceptions; AVFAudio raises on
        // control-plane entry points are caught here and handed back as
        // values (see DAWEngine's `withObjCExceptionBarrier`). DAWCore must
        // NOT depend on this — the domain stays dependency-free.
        .target(
            name: "ObjCExceptionGuard",
            linkerSettings: [
                .linkedFramework("Foundation")
            ]
        ),
        // Flat-C shim over the vendored signalsmith-stretch header-only C++
        // (offline time-stretch/pitch-shift, M5 ii). shim.cpp is the only C++
        // TU in the package; vendored headers + licenses live in vendor/
        // (pins in VENDORED.md). Accelerate backs the FFT. Offline only —
        // never on the render thread.
        .target(
            name: "CSignalsmithStretch",
            exclude: [
                "VENDORED.md",
                "vendor/signalsmith-stretch/LICENSE.txt",
                "vendor/signalsmith-linear/LICENSE.txt",
            ],
            cxxSettings: [
                .define("SIGNALSMITH_USE_ACCELERATE"),
                .headerSearchPath("vendor/signalsmith-stretch/include"),
                .headerSearchPath("vendor/signalsmith-linear/include"),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate")
            ]
        ),
        .target(name: "DAWEngine", dependencies: ["DAWCore", "CAtomics", "CSignalsmithStretch", "ObjCExceptionGuard"]),
        // AIServices dependency added M6 (i): the `ai.sidecarStatus|Start|Stop`
        // control commands route to AIServices' SidecarManager/SidecarStatus
        // (the local ACE-Step sidecar's lifecycle manager) — no cycle, since
        // AIServices itself only depends on DAWCore.
        .target(name: "DAWControl", dependencies: ["DAWCore", "AIServices"]),
        .target(name: "AIServices", dependencies: ["DAWCore"]),
        // Pure, testable view-model / UI-geometry logic (piano roll etc.). No
        // SwiftUI, so it can live in a library the executable DAWApp target
        // can't be tested through. Views stay in DAWApp and read this.
        .target(name: "DAWAppKit", dependencies: ["DAWCore", "AIServices"]),
        .executableTarget(
            name: "DAWApp",
            dependencies: ["DAWCore", "DAWEngine", "DAWControl", "AIServices", "DAWAppKit"],
            // App-icon artifacts (glass-b): consumed by scripts/bundle.sh, not by
            // the SwiftPM build — excluded so the build stays zero-warning.
            exclude: ["Resources/AppIcon-master-1024.png", "Resources/AppIcon.icns"]
        ),
        .testTarget(name: "DAWCoreTests", dependencies: ["DAWCore"]),
        // DAWEngine is a TEST-ONLY dependency here (the DAWControl module
        // itself stays engine-free): the AU control-surface tests forward
        // availableAudioUnits to the real component enumeration.
        .testTarget(name: "DAWControlTests", dependencies: ["DAWControl", "DAWCore", "DAWEngine", "AIServices"]),
        .testTarget(name: "DAWEngineTests", dependencies: ["DAWEngine", "DAWCore"]),
        .testTarget(name: "DAWAppKitTests", dependencies: ["DAWAppKit", "DAWCore", "AIServices"]),
        .testTarget(name: "AIServicesTests", dependencies: ["AIServices"]),
    ],
    // For the CSignalsmithStretch C++ TU; package-wide, but inert for the C
    // and Swift targets (they have no C++ sources).
    cxxLanguageStandard: .cxx17
)
