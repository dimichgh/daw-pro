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
    // THE PACKAGE'S FIRST AND ONLY REMOTE DEPENDENCY (m23-n1). WhisperKit is
    // Argmax's on-device CoreML Whisper runtime; it is what makes local vocal
    // transcription possible without anything leaving the machine. It arrives
    // with a transitive graph of 7 more packages (swift-transformers,
    // swift-crypto, swift-asn1, swift-collections, swift-argument-parser,
    // swift-jinja, yyjson), so every build from here on can need a network
    // fetch on a cold `.build`.
    //
    // VERSION RULE — `exact:` on this edge, `Package.resolved` for the rest:
    //   * `exact:` (not `from:`) because the weights this runtime loads are a
    //     FROZEN local copy under `Models/`. A WhisperKit minor bump may change
    //     the expected on-disk model layout, and a floating dependency against
    //     fixed weights fails at RUN time, not build time — exactly the failure
    //     a version rule is supposed to prevent.
    //   * `exact:` pins only THIS edge; the transitive graph still floats (a
    //     fresh resolve gave swift-crypto 4.5.1 / swift-jinja 2.4.2 where the
    //     reference app had 4.5.0 / 2.3.6). `Package.resolved` is the only
    //     thing that pins those, so it is deliberately TRACKED, not ignored.
    //     That is sound because daw-pro is the ROOT package — SwiftPM honours a
    //     root package's lockfile and ignores a dependency's, so this file is
    //     authoritative here in a way it would not be if we were consumed.
    // Bump procedure: change the version here, run `swift package resolve`,
    // review the `Package.resolved` diff, re-run the full suite.
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.18.0"),
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
        // WhisperKit lands HERE and nowhere else (m23-n1). AIServices is the
        // external-services module, it depends only on DAWCore, and DAWControl
        // already depends on it — the exact shape the ACE-Step sidecar used at
        // M6 (i). DAWCore must NOT reach it: the domain stays dependency-free
        // (see the same law stated at :18-19 and :25-26 above).
        .target(name: "AIServices",
                dependencies: ["DAWCore", .product(name: "WhisperKit", package: "WhisperKit")]),
        // Pure, testable view-model / UI-geometry logic (piano roll etc.). No
        // SwiftUI, so it can live in a library the executable DAWApp target
        // can't be tested through. Views stay in DAWApp and read this.
        .target(name: "DAWAppKit", dependencies: ["DAWCore", "AIServices"]),
        .executableTarget(
            name: "DAWApp",
            dependencies: ["DAWCore", "DAWEngine", "DAWControl", "AIServices", "DAWAppKit"],
            // App-icon artifacts (glass-b): consumed by scripts/bundle.sh, not by
            // the SwiftPM build — excluded so the build stays zero-warning.
            exclude: ["Resources/AppIcon-master-1024.png", "Resources/AppIcon.icns"],
            // Onboarding hero art (glass-d): runtime-loaded images, so unlike the
            // icon these ARE SwiftPM resources — the build emits
            // `daw-pro_DAWApp.bundle` next to the executable, which serves
            // `swift run` dev builds directly; scripts/bundle.sh copies that
            // bundle into the .app's Contents/Resources for the packaged product.
            // (Loading goes through `OnboardingHeroArt.load`, NOT `Bundle.module`
            // — see OnboardingTourView.swift for why.)
            resources: [
                .process("Resources/OnboardingWelcomeHero.png"),
                .process("Resources/OnboardingWelcomeHero@2x.png"),
                .process("Resources/OnboardingDoneHero.png"),
                .process("Resources/OnboardingDoneHero@2x.png"),
            ]
        ),
        // Byte fixtures for the SMF decoder (m23-k1). `.copy` rather than
        // `.process`: these are BINARY EVIDENCE — `apple-type1.mid` came out of
        // Apple's own encoder and the `hazard-*`/`malformed-*` files are
        // hand-authored spec bytes validated against Apple's loader. `.process`
        // reserves the right to transform resources, and a transformed fixture
        // is no longer evidence of anything. `.copy` preserves the directory
        // verbatim, so they load at `Fixtures/SMF/…` inside `Bundle.module`.
        .testTarget(name: "DAWCoreTests", dependencies: ["DAWCore"],
                    resources: [.copy("Fixtures")]),
        // DAWEngine is a TEST-ONLY dependency here (the DAWControl module
        // itself stays engine-free): the AU control-surface tests forward
        // availableAudioUnits to the real component enumeration.
        .testTarget(name: "DAWControlTests", dependencies: ["DAWControl", "DAWCore", "DAWEngine", "AIServices"]),
        // DAWAppKit is a TEST-ONLY dependency here (the DAWEngine module itself
        // stays UI-free), for the same reason DAWControlTests takes DAWEngine:
        // m23-m3's export dialog must be proven by the FILE ON DISK it produces
        // through the real store and the real engine, and both the on-disk
        // harness (`TestSignals`) and that engine live in this target.
        .testTarget(name: "DAWEngineTests", dependencies: ["DAWEngine", "DAWCore", "DAWAppKit"]),
        .testTarget(name: "DAWAppKitTests", dependencies: ["DAWAppKit", "DAWCore", "AIServices"]),
        .testTarget(name: "AIServicesTests", dependencies: ["AIServices"]),
    ],
    // For the CSignalsmithStretch C++ TU; package-wide, but inert for the C
    // and Swift targets (they have no C++ sources).
    cxxLanguageStandard: .cxx17
)
