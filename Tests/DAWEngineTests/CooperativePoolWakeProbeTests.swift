import Foundation
import Testing

// I1-F2 follow-up: WHERE A RENDER JOB'S DEBOUNCE WAKE-UP CAN GO.
//
// The repoint test (`EngineNoticeEngineTests.saveRepointStretchedClipPlaysAgain`)
// missed its 5 s window with its render job still inside the job's 250 ms
// debounce. Two mechanisms can hold a main-actor task's wake-up, and these
// probes measure each in isolation:
//
// - THE COOPERATIVE POOL, held by synchronous CPU-bound work (the way
//   synchronous test bodies hold it: a sync `@Test` body runs on a pool
//   thread and never gives it back until it returns). A `Task.sleep` wake
//   needs a pool thread at the sleeping task's priority before it can hop
//   to the main actor.
// - THE MAIN THREAD, held by synchronous work in a NEIGHBOURING main-actor
//   test (here: the YIN pitch readings two `AuditionEngineTests` tests
//   computed on the main actor at their ends).
//
// The job is made exactly as the product makes it: a `Task { @MainActor }`
// (the engine's kick) spawned from main-actor code, which spawns another
// `Task { @MainActor }` (the render job) that sleeps 250 ms. The loop is the
// test's OWN task on the main actor sleeping 10 ms, as the repoint test's
// poll loop is.
//
// ENV-GATED, and it measures, asserts only that each arm ran. The load runs
// on detached tasks (the pool) or GCD threads; the only main-actor work is
// the "YIN ON the main actor" neighbour arms, which reproduce on purpose the
// hold being diagnosed (a few seconds, once each, and only when enabled).
//
//     COOP_WAKE_PROBE=1 ./scripts/test.sh --filter CooperativePoolWakeProbe

@Suite("I1-F2 cooperative-pool wake probe (env-gated)", .serialized)
struct CooperativePoolWakeProbeTests {

    /// Keeps the calling thread busy for `seconds`: synchronous, CPU-bound,
    /// never suspends (a synchronous test body's shape).
    nonisolated static func spin(seconds: Double) -> UInt64 {
        let clock = ContinuousClock()
        let started = clock.now
        var x: UInt64 = 0x9E37_79B9_7F4A_7C15
        while started.duration(to: clock.now) < .seconds(seconds) {
            for _ in 0..<20_000 { x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
        }
        return x
    }

    enum Load: Sendable {
        case none
        /// `count` detached tasks at `priority`: each holds a pool thread.
        case pool(count: Int, priority: TaskPriority)
        /// `count` GCD threads at the default QoS: CPU busy, pool untouched.
        case gcd(count: Int)
    }

    /// Where the kick (the engine's `Task { @MainActor }`) is created.
    enum KickOrigin: Sendable {
        /// From the test's main-actor task, inheriting its priority: the
        /// product's shape inside a test.
        case inherit
        /// `Task(priority:)`.
        case priority(TaskPriority)
        /// From a plain thread at QoS user-interactive with no current task:
        /// the app's main thread, where a UI action's edit reaches
        /// `tracksDidChange` synchronously.
        case userInteractiveThread
    }

    /// A NEIGHBOURING main-actor test's tail, started once the job is inside
    /// its debounce sleep.
    enum Neighbour: Sendable {
        case none
        /// `I1Signals.medianYinHz` over `buffers` 220 Hz interiors of
        /// `samples` each, synchronously ON the main actor: the YIN tails of
        /// `clipSpanPhysicsHearsTheEdit` (3 × 19 200) and
        /// `clipSpanRenderPlaysStoredAndDraftSpans` (2 × 18 240) as written.
        case yinOnMain(buffers: Int, samples: Int)
        /// The same YIN on the same samples, awaited from a `.utility`
        /// detached task: the main actor is free while it runs.
        case yinDetached(buffers: Int, samples: Int)
    }

    struct Arm: Sendable {
        let name: String
        let load: Load
        let kick: KickOrigin
        var neighbour: Neighbour = .none
    }

    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    /// `buffers` interiors of a 48 kHz 220 Hz sine, `samples` long each. The
    /// YIN's cost is its difference function (lags × window per frame), the
    /// same for any content, so a sine stands in for the tests' buffers.
    nonisolated static func yinInteriors(buffers: Int, samples: Int) -> [[Float]] {
        let tone = (0..<samples).map { Float(0.5 * sin(2 * Double.pi * 220 * Double($0) / 48_000)) }
        return Array(repeating: tone, count: buffers)
    }

    nonisolated static func yin(_ interiors: [[Float]]) -> [Double?] {
        interiors.map { I1Signals.medianYinHz($0[...], sampleRate: 48_000, minHz: 120, maxHz: 500) }
    }

    /// One arm: start the load, then the kick → job (250 ms sleep), then (for
    /// a neighbour arm, once the job is in its sleep) the neighbour's tail;
    /// the test's own 10 ms loop runs until the job has woken and the
    /// neighbour has finished (or 15 s).
    @MainActor
    static func measure(_ arm: Arm, spinSeconds: Double) async throws -> String {
        let loadPriority = Box<TaskPriority?>(nil)
        var poolLoad: [Task<UInt64, Never>] = []
        let gcdGroup = DispatchGroup()
        switch arm.load {
        case .none:
            break
        case .pool(let count, let priority):
            for index in 0..<count {
                poolLoad.append(Task.detached(priority: priority) {
                    if index == 0 { loadPriority.value = Task.currentPriority }
                    return Self.spin(seconds: spinSeconds)
                })
            }
        case .gcd(let count):
            for _ in 0..<count {
                DispatchQueue.global(qos: .default).async(group: gcdGroup) {
                    _ = Self.spin(seconds: spinSeconds)
                }
            }
        }
        var interiors: [[Float]] = []
        switch arm.neighbour {
        case .none: break
        case .yinOnMain(let buffers, let samples), .yinDetached(let buffers, let samples):
            interiors = Self.yinInteriors(buffers: buffers, samples: samples)
        }

        // The product's shape: kick from main-actor code, job from the kick.
        let created = ContinuousClock.now
        let kickPriority = Box<TaskPriority?>(nil)
        let jobPriority = Box<TaskPriority?>(nil)
        let jobStart = Box<ContinuousClock.Instant?>(nil)
        let jobWoke = Box<ContinuousClock.Instant?>(nil)
        let jobWokePriority = Box<TaskPriority?>(nil)
        let body: @MainActor @Sendable () async -> Void = {
            kickPriority.value = Task.currentPriority
            let job = Task { @MainActor () throws -> Void in
                jobPriority.value = Task.currentPriority
                jobStart.value = ContinuousClock.now
                try await Task.sleep(for: .milliseconds(250))
                jobWoke.value = ContinuousClock.now
                jobWokePriority.value = Task.currentPriority
            }
            _ = try? await job.value
        }
        let kick: Task<Void, Never>
        switch arm.kick {
        case .inherit:
            kick = Task { @MainActor in await body() }
        case .priority(let priority):
            kick = Task(priority: priority) { @MainActor in await body() }
        case .userInteractiveThread:
            let made = Box<Task<Void, Never>?>(nil)
            let thread = Thread { made.value = Task { @MainActor in await body() } }
            thread.qualityOfService = .userInteractive
            thread.start()
            while made.value == nil, created.duration(to: .now) < .seconds(5) {
                try await Task.sleep(for: .milliseconds(1))
            }
            guard let task = made.value else { return "coop-wake| \(arm.name): the thread never made its kick" }
            kick = task
        }

        // The neighbour's tail, once the job is inside its debounce sleep.
        let yinSpan = Box<(start: ContinuousClock.Instant, end: ContinuousClock.Instant)?>(nil)
        var neighbourTask: Task<Void, Never>?
        if case .none = arm.neighbour {} else {
            while jobStart.value == nil, created.duration(to: .now) < .seconds(15) {
                try await Task.sleep(for: .milliseconds(1))
            }
            let neighbour = arm.neighbour
            let work = interiors
            neighbourTask = Task { @MainActor in
                let began = ContinuousClock.now
                switch neighbour {
                case .none:
                    break
                case .yinOnMain:
                    _ = Self.yin(work)
                case .yinDetached:
                    _ = await Task.detached(priority: .utility) { Self.yin(work) }.value
                }
                yinSpan.value = (began, ContinuousClock.now)
            }
        }
        let hasNeighbour = neighbourTask != nil

        // The test's own loop, as the repoint test polls.
        let loopPriority = Task.currentPriority
        var last = ContinuousClock.now
        var wakes = 0
        var maxGap = Duration.zero
        while jobWoke.value == nil || (hasNeighbour && yinSpan.value == nil),
              created.duration(to: .now) < .seconds(15) {
            try await Task.sleep(for: .milliseconds(10))
            let now = ContinuousClock.now
            wakes += 1
            maxGap = max(maxGap, now - last)
            last = now
        }
        let loopSpan = created.duration(to: .now)
        await kick.value
        await neighbourTask?.value
        for task in poolLoad { _ = await task.value }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            gcdGroup.notify(queue: .main) { done.resume() }
        }

        let startLatency = jobStart.value.map { ms(created.duration(to: $0)) } ?? .nan
        var late = Double.nan
        if let started = jobStart.value, let woke = jobWoke.value {
            late = ms(started.duration(to: woke)) - 250
        }
        var neighbourPart = ""
        if let span = yinSpan.value {
            let whereRan = if case .yinOnMain = arm.neighbour { "ON the main actor" } else { "on a .utility detached task" }
            neighbourPart = String(format: "; neighbour's YIN %.1f ms %@, from +%.1f to +%.1f ms",
                                   ms(span.start.duration(to: span.end)), whereRan,
                                   ms(created.duration(to: span.start)), ms(created.duration(to: span.end)))
            if let woke = jobWoke.value {
                neighbourPart += String(format: ", the job woke %.1f ms after it ended", ms(span.end.duration(to: woke)))
            }
        }
        let priorities = "priorities: test/loop \(loopPriority.rawValue), kick \(kickPriority.value?.rawValue ?? 0), "
            + "job \(jobPriority.value?.rawValue ?? 0) (after the wake \(jobWokePriority.value?.rawValue ?? 0)), "
            + "load \(loadPriority.value.map { String($0.rawValue) } ?? "-")"
        return String(format: "coop-wake| %@: job started +%.1f ms, woke %.1f ms LATE; loop %d wakes over %.0f ms, largest gap %.1f ms%@; %@",
                      arm.name, startLatency, late, wakes, ms(loopSpan), ms(maxGap), neighbourPart, priorities)
    }

    @MainActor
    static func run(_ arms: [Arm], spinSeconds: Double) async throws -> Int {
        print("coop-wake| cores \(ProcessInfo.processInfo.activeProcessorCount), test priority "
              + "\(Task.currentPriority.rawValue), spin \(spinSeconds) s per load task")
        var rows = 0
        for arm in arms {
            print(try await Self.measure(arm, spinSeconds: spinSeconds))
            rows += 1
            // Let the pool drain before the next arm.
            try await Task.sleep(for: .milliseconds(200))
        }
        return rows
    }

    @MainActor
    @Test("I1-F2 probe: a main-actor job's 250 ms debounce wake vs a main-actor 10 ms loop, with the cooperative pool held by synchronous CPU-bound work (K = cores, 2 × cores) or not (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["COOP_WAKE_PROBE"] != nil))
    func wakeLatencyUnderPoolSaturation() async throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let test = Task.currentPriority
        let arms: [Arm] = [
            Arm(name: "control: no load", load: .none, kick: .inherit),
            Arm(name: "pool K=\(cores) at the test's priority", load: .pool(count: cores, priority: test), kick: .inherit),
            Arm(name: "pool K=\(2 * cores) at the test's priority", load: .pool(count: 2 * cores, priority: test), kick: .inherit),
            Arm(name: "pool K=\(cores) at .userInitiated (a render's)", load: .pool(count: cores, priority: .userInitiated), kick: .inherit),
            Arm(name: "pool K=\(2 * cores) at .userInitiated (a render's)", load: .pool(count: 2 * cores, priority: .userInitiated), kick: .inherit),
            Arm(name: "pool K=\(cores - 1) at the test's priority (one thread free)", load: .pool(count: cores - 1, priority: test), kick: .inherit),
            Arm(name: "pool K=\(2 * cores) at the test's priority, kick at .utility", load: .pool(count: 2 * cores, priority: test), kick: .priority(.utility)),
            Arm(name: "GCD K=\(2 * cores) threads (CPU busy, pool free)", load: .gcd(count: 2 * cores), kick: .inherit),
            Arm(name: "control again: no load", load: .none, kick: .inherit),
        ]
        let rows = try await Self.run(arms, spinSeconds: 3.0)
        #expect(rows == arms.count)
    }

    @MainActor
    @Test("I1-F2 probe: a neighbouring main-actor test's YIN tail ON vs OFF the main actor, and the product's shape (renders at .userInitiated, a job kicked from a user-interactive thread) (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["COOP_WAKE_PROBE"] != nil))
    func yinTailAndProductShape() async throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let arms: [Arm] = [
            Arm(name: "control: no load, no neighbour", load: .none, kick: .inherit),
            Arm(name: "neighbour: clipSpanPhysicsHearsTheEdit's YIN tail (3 × 19200) ON the main actor",
                load: .none, kick: .inherit, neighbour: .yinOnMain(buffers: 3, samples: 19_200)),
            Arm(name: "neighbour: the same YIN from a .utility detached task",
                load: .none, kick: .inherit, neighbour: .yinDetached(buffers: 3, samples: 19_200)),
            Arm(name: "neighbour: clipSpanRenderPlaysStoredAndDraftSpans' YIN tail (2 × 18240) ON the main actor",
                load: .none, kick: .inherit, neighbour: .yinOnMain(buffers: 2, samples: 18_240)),
            Arm(name: "neighbour: the same YIN from a .utility detached task",
                load: .none, kick: .inherit, neighbour: .yinDetached(buffers: 2, samples: 18_240)),
            Arm(name: "kick from a user-interactive thread, no load", load: .none, kick: .userInteractiveThread),
            Arm(name: "pool K=\(cores) at .userInitiated (renders), kick from a user-interactive thread",
                load: .pool(count: cores, priority: .userInitiated), kick: .userInteractiveThread),
            Arm(name: "pool K=\(cores - 1) at .userInitiated (renders), kick from a user-interactive thread",
                load: .pool(count: cores - 1, priority: .userInitiated), kick: .userInteractiveThread),
            Arm(name: "pool K=\(cores) at .userInitiated (renders), kick at .userInitiated",
                load: .pool(count: cores, priority: .userInitiated), kick: .priority(.userInitiated)),
            Arm(name: "control again: no load, no neighbour", load: .none, kick: .inherit),
        ]
        let rows = try await Self.run(arms, spinSeconds: 3.0)
        #expect(rows == arms.count)
    }
}
