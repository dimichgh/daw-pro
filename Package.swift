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
    // TWO REMOTE DEPENDENCIES, both pinned `exact:`, both ML runtimes, and they
    // are deliberately shaped nothing alike — see the ONNX Runtime block below.
    //
    // (1) WHISPERKIT (m23-n1) — Argmax's on-device CoreML Whisper runtime; it is
    // what makes local vocal transcription possible without anything leaving the
    // machine. It arrives with a transitive graph of 7 more packages
    // (swift-transformers, swift-crypto, swift-asn1, swift-collections,
    // swift-argument-parser, swift-jinja, yyjson), so every build from here on
    // can need a network fetch on a cold `.build`.
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
    //
    // (2) ONNX RUNTIME (m23-ap-2a) — Microsoft's cross-platform inference
    // runtime, MIT. It exists here for exactly one reason: SwiftF0, the pitch
    // detector the user ratified 2026-08-04, publishes ONLY an ONNX graph — no
    // PyTorch checkpoint, no training code — and coremltools dropped its ONNX
    // frontend at v6, so there is no conversion route to Core ML that we would
    // not have to author and then own forever. The route spike
    // (docs/research/2026-08-05-m23ap1-swiftf0-route-spike.md) costed all three
    // options; the user was asked "do we take ONNX Runtime as a dependency?"
    // and answered YES on 2026-08-13.
    //
    // VERSION RULE — `exact:`, for a DIFFERENT reason than WhisperKit's:
    //   * WhisperKit is pinned exactly because a minor bump could change the
    //     on-disk layout of frozen weights and fail at RUN time. This edge is
    //     pinned exactly because it is a `binaryTarget` over a CHECKSUMMED
    //     CocoaPods archive (`pod-archive-onnxruntime-c-1.24.2.zip`, 52 MB, its
    //     SHA256 baked into ORT's own manifest). A floating version silently
    //     changes both a 52 MB fetch on a cold `.build` AND the size of every
    //     binary we ship — the link delta this dependency costs is measured in
    //     tens of MB, which is not something a `from:` range should be allowed
    //     to move without anyone looking.
    //   * UNLIKE WhisperKit, this edge has NO transitive graph at all — ORT's
    //     own manifest declares `dependencies: []`. So `exact:` here pins the
    //     WHOLE subtree, not just the first hop, and `Package.resolved` gains
    //     exactly one entry.
    //   * The product is declared `type: .static` upstream, so the linker folds
    //     `libonnxruntime.a` into the executable: no `Contents/Frameworks`, no
    //     dylib, no `@rpath`, and therefore no library-validation entitlement
    //     question and no new Xcode-specific bundling step.
    // ⚠️ Landing HERE (DAWEngine) does NOT put inference near the render
    // thread — see the §7.6 note at the top of Analysis/PitchTracker.swift.
    // Bump procedure: same as WhisperKit's, plus RE-MEASURE the stripped binary
    // size; that number is the whole cost of this dependency.
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.18.0"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
                 exact: "1.24.2"),
    ],
    targets: [
        // m30-a: the repo ships ONE tiny generated one-shot sample so the
        // built-in Sampler can be smoke-tested — by a human or an agent —
        // without sourcing audio from anywhere else. A fresh project otherwise
        // has no sample content at all, and a sampler feature exercised with no
        // content is indistinguishable from a broken one.
        //
        // `.copy` rather than `.process`, the swiftf0.onnx / SMF-fixtures
        // precedent: these bytes are EVIDENCE. `scripts/make-bundled-samples.py`
        // is the closed-form recipe that produced them, tests assert on the
        // pitch that comes back out of a render, and `.process` reserves the
        // right to transform a resource — a transcoded fixture would quietly
        // change what those tests measure. `.copy` also preserves the
        // directory, so the file loads at `BundledSamples/…` inside
        // `daw-pro_DAWCore.bundle` (see `BundledSamples.url(for:)`, which
        // resolves it WITHOUT `Bundle.module` and documents why).
        .target(name: "DAWCore",
                resources: [.copy("Resources/BundledSamples")]),
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
        // Flat-C shim over the vendored stb_vorbis Ogg Vorbis decoder (m31-h),
        // the CSignalsmithStretch precedent: one shim TU, the vendored source
        // + license in vendor/, pins in VENDORED.md. It exists so `.sf3`
        // SoundFonts — the format MuseScore ships EXCLUSIVELY, and therefore
        // the one a consumer most likely already has — can be converted to a
        // real `.sf2` at IMPORT time. Offline only, never the render thread.
        //
        // WHY VENDORED RATHER THAN THE OS, all three measured before choosing:
        // macOS 26.4 does decode Vorbis, but (1) via NO public API — there is
        // no `Ogg`/`Vorbis` constant in any AudioToolbox or AVFAudio header,
        // positive-controlled against `kAudioFileFLACType`, which is there;
        // (2) our floor is macOS 14, untestable here, and m26-d makes bank
        // install an UNATTENDED FIRST-RUN path; (3) it is incomplete — on the
        // real FluidR3Mono_GM.sf3, AVAudioFile decoded 1169 of 1186 samples
        // and failed 17 short wavetables that stb_vorbis reads fine.
        // `vendor/stb_vorbis.c` is EXCLUDED: shim.c #includes it, so its
        // symbols exist exactly once and are not exported past that TU.
        .target(
            name: "CStbVorbis",
            exclude: [
                "VENDORED.md",
                "vendor/LICENSE.txt",
                "vendor/stb_vorbis.c",
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
        // ONNX Runtime lands HERE and nowhere else (m23-ap-2a). Pitch detection
        // is audio analysis, so it belongs to the engine, not to AIServices
        // (which is the EXTERNAL-services module — sidecars and network clients
        // — and is where WhisperKit lives for exactly that reason). DAWCore must
        // NOT reach it: the domain stays dependency-free, same law as CAtomics
        // and ObjCExceptionGuard above.
        //
        // The weights are a COMMITTED RESOURCE, not a download: 397,987 B is a
        // rounding error against the shipped binary, so `ai.installSpeechModel`
        // (which exists for models three orders of magnitude larger) is
        // deliberately not involved. `.copy` rather than `.process` for the same
        // reason as DAWCoreTests' SMF fixtures below — these bytes are pinned by
        // SHA256 in a test, and `.process` reserves the right to transform a
        // resource, which would break that pin. VENDORED.md and the upstream
        // LICENSE sit beside the model (the CSignalsmithStretch/vendor
        // precedent) and are excluded so they are neither compiled nor shipped
        // as resources — an unhandled file in a target directory is a build
        // warning, and this package builds clean.
        .target(name: "DAWEngine",
                dependencies: ["DAWCore", "CAtomics", "CSignalsmithStretch", "CStbVorbis",
                               "ObjCExceptionGuard",
                               .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")],
                exclude: [
                    "Analysis/Resources/VENDORED.md",
                    "Analysis/Resources/SwiftF0-LICENSE",
                ],
                resources: [.copy("Analysis/Resources/swiftf0.onnx")]),
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
        // `.copy`, the DAWCoreTests-fixtures precedent below: the m31-h SF3
        // fixture's sample data is REAL MuseScore-produced Ogg Vorbis and the
        // tests assert on frame counts that come out of decoding it, so
        // `.process` — which reserves the right to transform a resource —
        // would quietly change what those tests measure.
        .testTarget(name: "DAWEngineTests", dependencies: ["DAWEngine", "DAWCore", "DAWAppKit"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "DAWAppKitTests", dependencies: ["DAWAppKit", "DAWCore", "AIServices"]),
        .testTarget(name: "AIServicesTests", dependencies: ["AIServices"]),
    ],
    // For the CSignalsmithStretch C++ TU; package-wide, but inert for the C
    // and Swift targets (they have no C++ sources).
    cxxLanguageStandard: .cxx17
)
