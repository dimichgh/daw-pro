import Darwin
import Foundation

/// One home (house "ONE home" rule) for the question *"what should `stop()`
/// actually do, and is it safe to signal that process?"* — m23-bb (ACE-Step)
/// and m23-bb-1 (RVC voice conversion).
///
/// ## Why this is shared rather than copied
///
/// m23-bb's defect was two answers to one question: `status()` resolved "the
/// sidecar" from the health probe while `stop()` resolved it from the pidfile,
/// so with a stale pidfile and a live sidecar the two disagreed — `stop()`
/// deleted the pidfile, reported *"was not running"*, and left the sidecar
/// running. m23-bb-1 is the SAME defect in `VoiceConversionManager`.
///
/// Fixing the twin by copying the ACE planner would have recreated the defect
/// class one level up: two implementations of *"what should stop do"*, drifting
/// until one of them lies. So the planner, the identity check, the termination
/// walk and every message live here ONCE, parameterised by the only two things
/// that genuinely differ between sidecars:
///
/// * `Identity` — how to recognise our own process on a command line.
/// * `Vocabulary` — the user-facing wording (which sidecar, which verb, which
///   env var).
///
/// `SidecarProcessDiscovery` (already port-parameterised) supplies the facts;
/// nothing in THAT file ever signals. This file is where signalling happens,
/// and only after a plan says it is safe.
///
/// ## The invariants every caller inherits
///
/// 1. **Never lie.** `.notRunning` is reachable only when the health probe
///    agrees the sidecar is not answering. When we cannot stop something that
///    is demonstrably up, that is a FAILURE (`SidecarError.stopFailed`), never
///    a success-shaped status.
/// 2. **A refusal mutates nothing** — no signal, no pidfile removal, no state
///    clearing.
/// 3. **Self/ancestor exclusion runs FIRST** on every candidate: the identity
///    predicate matches a path substring, so a checkout living under a
///    directory that happens to match would otherwise let the ancestor climb
///    walk into DAW Pro itself.
/// 4. **Fail OPEN on the pidfile path, CLOSED on the port path.** The pidfile
///    is our own record and a still-BOOTING sidecar has bound no port yet, so
///    only a POSITIVE identity mismatch diverts it; a pid discovered by port is
///    not necessarily ours, so anything unidentifiable is refused.
/// 5. **Two pid-reuse re-confirmations**, before the first signal and again
///    before any SIGKILL escalation.
/// 6. **Capture descendants BEFORE signalling** — a child whose parent exits is
///    reparented to pid 1 and the linkage is gone (measured at m23-az-1).
/// 7. **Never `pkill`/`pgrep`/`killall`, never kill a process we cannot
///    identify.** Pid-exact only.
enum SidecarStop {

    // MARK: - Identity: "is this process ours?"

    /// PURE identity predicate configuration — the ONLY genuinely
    /// sidecar-specific part of the planning logic.
    ///
    /// Two independent limbs, either of which is sufficient:
    ///
    /// * `argsPattern` — a regular expression over the command line, for the
    ///   case where the process names the engine rather than our directory.
    /// * `directoryPath` — containment of the configured sidecar directory,
    ///   for launchers/interpreters that spell nothing recognisable but do run
    ///   out of a path we configured.
    ///
    /// An empty/nil limb never matches (an empty `directoryPath` matching
    /// everything would make this predicate an unconditional "yes", which is
    /// the worst possible failure mode for something that decides what to
    /// kill).
    struct Identity: Sendable, Equatable {
        var argsPattern: String?
        var directoryPath: String?

        init(argsPattern: String? = nil, directoryPath: String? = nil) {
            self.argsPattern = argsPattern
            self.directoryPath = directoryPath
        }

        func matches(args: String) -> Bool {
            if let argsPattern, !argsPattern.isEmpty,
               args.range(of: argsPattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
            if let directoryPath, !directoryPath.isEmpty, args.contains(directoryPath) {
                return true
            }
            return false
        }

        /// ⚠️ THE SEPARATOR TRAP, measured at m23-az and paid for with a leaked
        /// 75 GB sidecar: the real command lines are `uv run --no-sync
        /// acestep-api` and `.../python3 .../acestep-api` — NO separator
        /// between "ace" and "step". A pattern requiring one (`ace[-_]step`)
        /// matches nothing and fails CLOSED, refusing to signal a process it
        /// correctly found. The `?` is load-bearing.
        ///
        /// The directory limb matches our own launcher (`/bin/bash
        /// <dir>/run.sh`), whose command line names the configured sidecar
        /// directory but need not contain "acestep" anywhere else.
        static func aceStep(directoryPath: String?) -> Identity {
            Identity(argsPattern: "ace[-_]?step", directoryPath: directoryPath)
        }

        /// ⚠️ RVC HAS NO DISTINCTIVE TOKEN, and that is the whole difficulty of
        /// m23-bb-1's identity check. "ace-step" is a rare string; "rvc" is
        /// three letters that appear in unrelated paths, package names and
        /// flags all over a developer's machine. A bare `/rvc/i` here would be
        /// a licence to kill strangers.
        ///
        /// So the PRIMARY limb is the configured directory (`directoryPath`),
        /// which is exact. `scripts/rvc/run.sh` ends in
        /// `exec "$VENV_PY" "$SCRIPT_DIR/server.py"` where `SCRIPT_DIR` IS the
        /// configured rvc dir — so the running server's command line always
        /// contains that directory verbatim, even when `RVC_RUNTIME_DIR` moves
        /// the interpreter elsewhere.
        ///
        /// The pattern limb is a deliberately NARROW backstop for the case
        /// where the two spellings of the same directory diverge (a symlinked
        /// or non-standardised `DAWPRO_RVC_DIR` vs. the path `ps` reports): it
        /// requires `rvc` as a WHOLE PATH COMPONENT immediately followed by one
        /// of the two files this sidecar actually executes, and then a word
        /// boundary. `/opt/myrvc/server.py`, `/usr/bin/rvcplayer`,
        /// `python -m rvc.server` and `--engine=rvc` all fail it.
        static func rvc(directoryPath: String?) -> Identity {
            Identity(
                argsPattern: #"(^|/)rvc/(server\.py|run\.sh)(\s|$)"#,
                directoryPath: directoryPath)
        }
    }

    // MARK: - Vocabulary: the user-facing wording

    /// Everything the shared messages need in order to speak about a SPECIFIC
    /// sidecar. Wording is the other genuinely per-sidecar input; keeping it in
    /// a value (rather than branching on an enum inside the message builders)
    /// is what makes it impossible for one sidecar's messages to silently pick
    /// up another's routing.
    struct Vocabulary: Sendable, Equatable {
        /// "ACE-Step sidecar" — used as the grammatical subject of a sentence.
        var subject: String
        /// "ACE-Step" — used after "looks like" / "does not identify it as".
        var identityName: String
        /// "DAWPRO_ACESTEP_DIR" — named when the wrong thing is on the port.
        var directoryEnvVar: String
        /// "ai.sidecarStop" — named when the user should retry the stop.
        var stopVerb: String

        static let aceStep = Vocabulary(
            subject: "ACE-Step sidecar",
            identityName: "ACE-Step",
            directoryEnvVar: "DAWPRO_ACESTEP_DIR",
            stopVerb: "ai.sidecarStop")

        static let rvc = Vocabulary(
            subject: "RVC voice-conversion sidecar",
            identityName: "the RVC voice-conversion sidecar",
            directoryEnvVar: "DAWPRO_RVC_DIR",
            stopVerb: "vc.sidecarStop")
    }

    // MARK: - Planning vocabulary

    /// What the health probe said, reduced to the distinction `stop()` turns
    /// on: did ANYTHING answer on the sidecar's port?
    ///
    /// `respondingButUnparsable` counts as answering. Something is bound to the
    /// port and talking HTTP, which is more than enough to make "was not
    /// running" a lie — and the identity check downstream is what keeps that
    /// from turning into an unsafe kill.
    enum Probe: Sendable, Equatable {
        case healthy
        case respondingButUnparsable
        case unreachable

        var isAnswering: Bool { self != .unreachable }
    }

    /// How `stop()` found the process it is about to signal — carried purely so
    /// the resulting message can be honest about provenance.
    enum Discovery: Sendable, Equatable {
        case pidfile
        case port(UInt16)
    }

    /// Why the sidecar is genuinely down. Distinguished because they need
    /// different messages and different pidfile handling.
    enum NotRunningReason: Sendable, Equatable {
        case noPidfile
        case stalePidfile(pid: Int32)
        case foreignPidfile(pid: Int32, args: String)

        var pid: Int32? {
            switch self {
            case .noPidfile: return nil
            case .stalePidfile(let pid), .foreignPidfile(let pid, _): return pid
            }
        }

        /// A pidfile that exists but describes nothing usable is removed, as it
        /// always has been. `.noPidfile` has nothing to remove.
        var removesPidfile: Bool {
            if case .noPidfile = self { return false }
            return true
        }
    }

    /// Why `stop()` refuses to signal anything even though the sidecar is
    /// demonstrably answering. Every one of these is a FAILURE (thrown as
    /// `SidecarError.stopFailed`), never a success-shaped status, and none of
    /// their messages may claim the sidecar is not running.
    enum Refusal: Sendable, Equatable {
        case portUnknown
        case discoveryUnavailable(port: UInt16, detail: String)
        case noListenerFound(port: UInt16)
        case listenerIsThisProcess(port: UInt16, pid: Int32)
        case listenerNotIdentified(port: UInt16, pid: Int32, args: String)
        case multipleCandidates(port: UInt16, pids: [Int32])
    }

    /// The three things `stop()` can do.
    enum Plan: Sendable, Equatable {
        case terminate(pid: Int32, discovery: Discovery)
        case refuse(Refusal)
        case notRunning(NotRunningReason)
    }

    /// Everything `resolvePlan` reasons over, gathered by the impure half of a
    /// manager's `stop()`. A value type so the decision itself is a pure
    /// function of observable facts and can be exercised headless — including
    /// the combination that defines m23-bb/m23-bb-1 (probe healthy + stale
    /// pidfile), which is otherwise only reproducible against a live sidecar.
    struct Facts: Sendable {
        var probe: Probe
        var pidfilePid: Int32?
        var pidfilePidAlive: Bool
        /// The TCP port `config.baseURL` names — NEVER hardcoded (not to 8001,
        /// not to 8002).
        var port: UInt16?
        var portLookup: SidecarProcessDiscovery.PortLookup
        var snapshot: SidecarProcessDiscovery.Snapshot
        var selfPid: Int32
        /// Deliberately has NO default: which sidecar we are identifying is the
        /// one thing a caller must never inherit by accident.
        var identity: Identity

        init(
            probe: Probe,
            pidfilePid: Int32? = nil,
            pidfilePidAlive: Bool = false,
            port: UInt16?,
            portLookup: SidecarProcessDiscovery.PortLookup = .nothingListening,
            snapshot: SidecarProcessDiscovery.Snapshot = .init(),
            selfPid: Int32 = 1_000_000,
            identity: Identity
        ) {
            self.probe = probe
            self.pidfilePid = pidfilePid
            self.pidfilePidAlive = pidfilePidAlive
            self.port = port
            self.portLookup = portLookup
            self.snapshot = snapshot
            self.selfPid = selfPid
            self.identity = identity
        }
    }

    // MARK: - Fact gathering (impure, but still ONE home)

    /// Gathers the facts `resolvePlan` reasons over, doing the read-only I/O
    /// (`lsof`, `ps`) that the pure planner must not.
    ///
    /// ⭐ WHY THIS IS SHARED RATHER THAN WRITTEN OUT PER MANAGER. Two of the
    /// lines below are RULES, not plumbing — "when do we look up the port" and
    /// "when do we snapshot the process table" — and m23-bb paid for getting
    /// the first one wrong. A per-manager copy of a rule is exactly the defect
    /// class m23-bb-1 exists to remove: it puts two answers in the tree to one
    /// question, and the second copy drifts silently because nothing compares
    /// them. Callers supply only what is genuinely theirs — their own probe
    /// result, their own pidfile, their own base URL, their own identity.
    ///
    /// `selfPid` is read here rather than passed in: this is inherently the
    /// live path (it shells out to `ps`), and a caller cannot then hand the
    /// planner a self-pid that isn't actually self, which would defeat the
    /// self/ancestor exclusion. Planner tests build `Facts` directly and keep
    /// full control of it.
    static func gatherFacts(
        probe: Probe,
        pidfilePid: Int32?,
        pidfilePidAlive: Bool,
        baseURL: URL,
        identity: Identity
    ) -> Facts {
        let port = SidecarProcessDiscovery.port(of: baseURL)

        // Port discovery runs whenever the sidecar is ANSWERING — deliberately
        // not "…and the pidfile gave us nothing".
        //
        // ⚠️ It was written that way first and it was wrong: a pidfile holding
        // a live but FOREIGN pid (recycled) makes `pidfilePidAlive` true, so
        // the lookup would never run, and the planner's fall-through to port
        // discovery could not fire — it would see `.nothingListening` and
        // refuse with "nothing is listening" while the sidecar sat there
        // answering. Gathering a fact conditionally on a rule the pure planner
        // owns is how the two silently disagree; the planner decides, this
        // just supplies. One `lsof` on a stop is not worth that risk.
        let lookup: SidecarProcessDiscovery.PortLookup
        if probe.isAnswering, let port {
            lookup = SidecarProcessDiscovery.listeners(onPort: port)
        } else {
            lookup = .nothingListening
        }

        // The snapshot is needed for identity/ancestry whenever we have any
        // candidate pid at all.
        let snapshot = (pidfilePidAlive || probe.isAnswering)
            ? SidecarProcessDiscovery.captureSnapshot()
            : SidecarProcessDiscovery.Snapshot()

        return Facts(
            probe: probe,
            pidfilePid: pidfilePid,
            pidfilePidAlive: pidfilePidAlive,
            port: port,
            portLookup: lookup,
            snapshot: snapshot,
            selfPid: ProcessInfo.processInfo.processIdentifier,
            identity: identity
        )
    }

    // MARK: - The pure decision

    /// PURE decision — no I/O, no actor state — so the floor rule ("never route
    /// to a not-running answer while the probe says the sidecar is answering")
    /// is unit-testable without a live sidecar, and without depending on the
    /// wording of any message.
    static func resolvePlan(_ facts: Facts) -> Plan {
        // Never, under any circumstance, target this process or one of its own
        // ancestors. This runs FIRST on every candidate because the identity
        // predicate matches on a path substring, and a checkout living under a
        // matching directory would otherwise let the ancestor climb walk
        // straight into DAW Pro itself.
        var blocked: Set<Int32> = [facts.selfPid]
        blocked.formUnion(facts.snapshot.ancestors(of: facts.selfPid))

        let identifies: (String) -> Bool = { facts.identity.matches(args: $0) }

        // 1. The pidfile is OUR OWN record and wins when it points at a live
        //    process. This path must keep working for a sidecar that is still
        //    BOOTING — nothing is bound to the port yet, so port discovery
        //    cannot see it — which is why it FAILS OPEN: only a POSITIVE
        //    identity mismatch (args readable AND clearly not ours) diverts.
        //    Unreadable args mean "unknown", never "not ours".
        //
        //    ⚠️ The asymmetry with step 2 below is deliberate, not an
        //    oversight: a pid discovered BY PORT is not necessarily ours, so
        //    that path fails CLOSED and refuses anything it cannot identify.
        if let pid = facts.pidfilePid, facts.pidfilePidAlive {
            let recordedArgs = facts.snapshot.args(of: pid)
            let positivelyForeign = blocked.contains(pid)
                || pid <= 1
                || (recordedArgs.map { !identifies($0) } ?? false)
            if !positivelyForeign {
                return .terminate(pid: pid, discovery: .pidfile)
            }
            if !facts.probe.isAnswering {
                return .notRunning(.foreignPidfile(pid: pid, args: recordedArgs ?? "unknown command"))
            }
            // Foreign pidfile but the sidecar IS answering: fall through to
            // port discovery rather than signalling a stranger.
        }

        // 2. Nothing usable from the pidfile.
        guard facts.probe.isAnswering else {
            guard let pid = facts.pidfilePid else { return .notRunning(.noPidfile) }
            return .notRunning(.stalePidfile(pid: pid))
        }

        guard let port = facts.port else {
            return .refuse(.portUnknown)
        }
        switch facts.portLookup {
        case .unavailable(let detail):
            return .refuse(.discoveryUnavailable(port: port, detail: detail))
        case .nothingListening:
            return .refuse(.noListenerFound(port: port))
        case .listeners(let pids):
            var targets: [Int32] = []
            var unidentified: [(pid: Int32, args: String)] = []
            for pid in pids {
                guard pid > 1 else { continue }
                if blocked.contains(pid) {
                    return .refuse(.listenerIsThisProcess(port: port, pid: pid))
                }
                guard let args = facts.snapshot.args(of: pid) else {
                    unidentified.append((pid, "command line unavailable"))
                    continue
                }
                guard identifies(args) else {
                    unidentified.append((pid, args))
                    continue
                }
                // The listener may be a CHILD (m23-bb's own report: `pid 49156
                // -> python 49160 listening on 8001`); climb to the topmost
                // process that still identifies as the sidecar so the
                // descendant capture at kill time covers the whole tree.
                //
                // For RVC there is no split — `run.sh` `exec`s into the server,
                // so the pidfile pid IS uvicorn — and the climb simply finds no
                // matching parent and returns the pid unchanged. Keeping it
                // costs nothing and defends if that launcher ever stops
                // `exec`ing.
                let top = facts.snapshot.climb(from: pid, blocked: blocked) { identifies($0.args) }
                if !targets.contains(top) { targets.append(top) }
            }
            if targets.count == 1 { return .terminate(pid: targets[0], discovery: .port(port)) }
            if targets.count > 1 { return .refuse(.multipleCandidates(port: port, pids: targets)) }
            if let first = unidentified.first {
                return .refuse(.listenerNotIdentified(port: port, pid: first.pid, args: first.args))
            }
            return .refuse(.noListenerFound(port: port))
        }
    }

    // MARK: - Termination (parent + captured descendants)

    struct TerminationOutcome: Sendable, Equatable {
        var targetPid: Int32
        var forcedTarget = false
        var targetSurvived = false
        /// The target's pid was recycled during the grace window, so we refused
        /// to escalate to SIGKILL.
        var targetRecycled = false
        var descendantsStopped: [Int32] = []
        var descendantsSurvived: [Int32] = []
        /// Captured descendants whose command line had CHANGED by the time we
        /// went to signal them — the pid was reused, so they were left alone.
        var descendantsRecycled: [Int32] = []
    }

    enum TerminationResult: Sendable {
        case done(TerminationOutcome)
        case refused(Refusal)
    }

    /// ⚠️ PID REUSE, first of two guards, and PURE so the branch is testable:
    /// identity was confirmed when the plan was made and time has passed since,
    /// so a pid discovered BY PORT — which is not necessarily ours — is
    /// re-confirmed against a snapshot taken immediately before the signal.
    /// Returns the refusal to raise, or nil to proceed.
    ///
    /// The asymmetry with the pidfile path is deliberate and is the same one
    /// `resolvePlan` documents: the pidfile is our own record and fails OPEN on
    /// unknown identity (a booting sidecar must stay stoppable); a
    /// port-discovered stranger fails CLOSED.
    ///
    /// A target that is no longer alive needs no re-confirmation: there is
    /// nothing left to signal, and the post-stop health probe is what decides
    /// whether the sidecar actually went away.
    static func reconfirmationRefusal(
        discovery: Discovery, targetPid: Int32, targetAliveNow: Bool,
        argsNow: String?, identity: Identity
    ) -> Refusal? {
        guard case .port(let port) = discovery, targetAliveNow else { return nil }
        guard let argsNow, identity.matches(args: argsNow) else {
            return .listenerNotIdentified(
                port: port, pid: targetPid, args: argsNow ?? "command line unavailable")
        }
        return nil
    }

    static func processAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// Signals `target` and every descendant captured BEFORE the signal.
    ///
    /// The only impure function in this file that mutates anything on the
    /// system, and it is reached only from a `.terminate` plan.
    static func terminateTree(
        target: Int32, discovery: Discovery, identity: Identity, stopTimeoutSeconds: Double
    ) async -> TerminationResult {
        var outcome = TerminationOutcome(targetPid: target)

        // ⚠️ CAPTURE BEFORE SIGNALLING. Once the parent dies its children are
        // reparented to pid 1 and the tree is unreconstructible — measured at
        // m23-az-1. For ACE-Step the child is what holds the ~75 GB, so losing
        // the linkage means losing the memory.
        let snapshot = SidecarProcessDiscovery.captureSnapshot()
        let targetArgs = snapshot.args(of: target)
        let captured = snapshot.descendants(of: target)

        if let refusal = reconfirmationRefusal(
            discovery: discovery, targetPid: target, targetAliveNow: processAlive(target),
            argsNow: targetArgs, identity: identity
        ) {
            return .refused(refusal)
        }

        kill(target, SIGTERM)
        let deadline = Date().addingTimeInterval(stopTimeoutSeconds)
        while Date() < deadline, processAlive(target) {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if processAlive(target) {
            // ⚠️ PID REUSE: the pid may have been recycled during the grace
            // window, so identity is re-confirmed immediately before the
            // escalation, not just before the first signal.
            if let targetArgs, let now = SidecarProcessDiscovery.args(ofPid: target), now != targetArgs {
                outcome.targetRecycled = true
            } else {
                kill(target, SIGKILL)
                outcome.forcedTarget = true
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        outcome.targetSurvived = !outcome.targetRecycled && processAlive(target)

        // Reap the descendants captured above. Ownership is established by the
        // pre-kill tree capture; the only extra check needed is the pid-reuse
        // one — a captured pid whose command line has changed is a different
        // process now and must be left alone.
        var pending: [SidecarProcessDiscovery.Entry] = []
        for child in captured where processAlive(child.pid) {
            guard let now = SidecarProcessDiscovery.args(ofPid: child.pid), now == child.args else {
                outcome.descendantsRecycled.append(child.pid)
                continue
            }
            kill(child.pid, SIGTERM)
            pending.append(child)
        }
        if !pending.isEmpty {
            // A SHORT FIXED grace, deliberately not `stopTimeoutSeconds`: these
            // are children of an already-dead parent, and borrowing the full
            // stop timeout would add seconds to every test that stops a sidecar
            // (m23-aw is an open item about exactly this contention).
            try? await Task.sleep(nanoseconds: 300_000_000)
            for child in pending where processAlive(child.pid) {
                guard let now = SidecarProcessDiscovery.args(ofPid: child.pid), now == child.args else {
                    outcome.descendantsRecycled.append(child.pid)
                    continue
                }
                kill(child.pid, SIGKILL)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            for child in pending where !outcome.descendantsRecycled.contains(child.pid) {
                if processAlive(child.pid) {
                    outcome.descendantsSurvived.append(child.pid)
                } else {
                    outcome.descendantsStopped.append(child.pid)
                }
            }
        }
        return .done(outcome)
    }

    // MARK: - Messages (pure)

    static func notRunningState(_ reason: NotRunningReason, isInstalled: Bool) -> SidecarState {
        switch reason {
        case .noPidfile:
            return isInstalled ? .installedNotRunning : .notInstalled
        case .stalePidfile, .foreignPidfile:
            // A pidfile exists at all, so the sidecar has certainly been
            // installed and started at some point (pre-m23-bb behaviour,
            // preserved verbatim).
            return .installedNotRunning
        }
    }

    /// ⚠️ THE ONLY PLACE ALLOWED TO SAY "NOT RUNNING" — and it is reachable
    /// only from `.notRunning`, which `resolvePlan` only ever returns when the
    /// health probe agrees the sidecar is not answering. That routing, not this
    /// wording, is the actual fix.
    static func notRunningMessage(_ reason: NotRunningReason, vocabulary v: Vocabulary) -> String {
        switch reason {
        case .noPidfile:
            return "\(v.subject) is not running (no pidfile found)."
        case .stalePidfile:
            return "\(v.subject) was not running (stale pidfile removed)."
        case .foreignPidfile(let pid, let args):
            return "\(v.subject) was not running — its pidfile pointed at pid \(pid), which is "
                + "an unrelated process (\(args)); the stale pidfile has been removed and nothing "
                + "was signalled."
        }
    }

    static func refusalMessage(
        _ refusal: Refusal, vocabulary v: Vocabulary, baseURL: URL, pidfilePath: String?
    ) -> String {
        let origin = "\(baseURL.absoluteString)"
        let head = "\(v.subject) is STILL UP — it is answering on \(origin) — but it could not "
            + "be stopped: "
        let pidfileClause = pidfilePath.map { " Its pidfile (\($0)) does not point at a live process." } ?? ""
        switch refusal {
        case .portUnknown:
            return head + "its configured base URL (\(origin)) names no TCP port, so the process "
                + "serving it cannot be discovered.\(pidfileClause) Set a base URL with an explicit "
                + "port, or stop the sidecar yourself."
        case .discoveryUnavailable(let port, let detail):
            return head + "the process listening on port \(port) could not be looked up (\(detail))."
                + "\(pidfileClause) Find it with `lsof -nP -iTCP:\(port) -sTCP:LISTEN` and stop it "
                + "with `kill <pid>`."
        case .noListenerFound(let port):
            return head + "nothing could be found holding the listening socket on port \(port), so "
                + "there is no process I can attribute it to.\(pidfileClause) Find it with `lsof "
                + "-nP -iTCP:\(port) -sTCP:LISTEN` and stop it with `kill <pid>`."
        case .listenerIsThisProcess(let port, let pid):
            return head + "the process listening on port \(port) is DAW Pro itself, or one of its "
                + "own parent processes (pid \(pid)) — refusing to signal it.\(pidfileClause) "
                + "Something other than the \(v.subject) "
                + "is serving \(origin); point \(v.directoryEnvVar) / the sidecar base URL at the "
                + "right port."
        case .listenerNotIdentified(let port, let pid, let args):
            return head + "pid \(pid) holds the listening socket on port \(port), but its command "
                + "line does not identify it as \(v.identityName) (\(args)), so it will NOT be "
                + "signalled — killing a process we cannot identify is not something this command "
                + "will do.\(pidfileClause) If that process is yours, stop it with `kill \(pid)`."
        case .multipleCandidates(let port, let pids):
            let list = pids.map(String.init).joined(separator: ", ")
            return head + "several processes (pids \(list)) look like \(v.identityName) and hold "
                + "the listening socket on port \(port); refusing to signal any of them because "
                + "the sidecar cannot be told apart from the others.\(pidfileClause) Inspect them "
                + "with `ps -p \(pids.first.map(String.init) ?? "<pid>") -o args=` and stop the "
                + "right one with `kill <pid>`."
        }
    }

    static func stoppedMessage(
        outcome: TerminationOutcome, discovery: Discovery, vocabulary v: Vocabulary
    ) -> String {
        let via: String
        switch discovery {
        case .pidfile:
            via = "found via its pidfile"
        case .port(let port):
            via = "found holding the listening socket on port \(port) — its pidfile was stale or "
                + "missing"
        }
        var message = "\(v.subject) stopped: pid \(outcome.targetPid) (\(via))"
        message += outcome.forcedTarget ? " did not exit on SIGTERM and was force-killed." : "."
        if !outcome.descendantsStopped.isEmpty {
            let list = outcome.descendantsStopped.map(String.init).joined(separator: ", ")
            message += " Also stopped \(outcome.descendantsStopped.count) child process"
                + "\(outcome.descendantsStopped.count == 1 ? "" : "es") it had spawned (pid \(list))"
                + " — that is where the loaded models' memory lives."
        }
        if !outcome.descendantsSurvived.isEmpty {
            let list = outcome.descendantsSurvived.map(String.init).joined(separator: ", ")
            message += " ⚠️ \(outcome.descendantsSurvived.count) child process"
                + "\(outcome.descendantsSurvived.count == 1 ? "" : "es") could not be confirmed "
                + "stopped (pid \(list)) — check with `ps -p \(list) -o args=`."
        }
        if !outcome.descendantsRecycled.isEmpty {
            let list = outcome.descendantsRecycled.map(String.init).joined(separator: ", ")
            message += " (Left pid \(list) alone: its command line had changed since it was "
                + "captured, so that pid has been reused by an unrelated process.)"
        }
        return message
    }

    static func stillAnsweringMessage(
        outcome: TerminationOutcome, baseURL: URL, vocabulary v: Vocabulary
    ) -> String {
        let origin = baseURL.absoluteString
        if outcome.targetRecycled {
            return "\(v.subject) is STILL UP on \(origin): pid \(outcome.targetPid) was sent "
                + "SIGTERM but its command line changed before the forced kill, so that pid has "
                + "been reused and nothing further was signalled. Find the live sidecar with `lsof "
                + "-nP -iTCP -sTCP:LISTEN` and stop it with `kill <pid>`."
        }
        if outcome.targetSurvived {
            return "\(v.subject) is STILL UP on \(origin): pid \(outcome.targetPid) survived "
                + "both SIGTERM and SIGKILL. This should not happen — the process may be stuck in "
                + "an uninterruptible state; check `ps -p \(outcome.targetPid) -o state=`."
        }
        return "\(v.subject) pid \(outcome.targetPid) was stopped, but \(origin) is STILL "
            + "answering — a SECOND sidecar instance is almost certainly running. Find it with "
            + "`lsof -nP -iTCP -sTCP:LISTEN` and stop it with `kill <pid>`, then call "
            + "\(v.stopVerb) again."
    }

    // MARK: - Dry run

    /// The state/message/pid a dry-run should report. Deliberately NOT a
    /// `SidecarStatus` or a `VoiceConversionStatus`: those two are twins by
    /// design (different health payloads) and each manager assembles its own.
    /// The DECISION is shared, so a dry-run can never describe a different
    /// decision than the one the real path would take.
    struct DryRunReport: Sendable, Equatable {
        var state: SidecarState
        var message: String
        var pid: Int32?
    }

    static func dryRunReport(
        for plan: Plan, isInstalled: Bool, vocabulary v: Vocabulary, baseURL: URL,
        pidfilePath: String?
    ) -> DryRunReport {
        switch plan {
        case .terminate(let pid, let discovery):
            let via: String
            switch discovery {
            case .pidfile: via = ""
            case .port(let port): via = ", found holding the listening socket on port \(port)"
            }
            return DryRunReport(
                state: .installedNotRunning,
                message: "[dry-run] would stop pid \(pid)\(via).",
                pid: pid)
        case .notRunning(let reason):
            return DryRunReport(
                state: notRunningState(reason, isInstalled: isInstalled),
                message: "[dry-run] nothing to stop — \(notRunningMessage(reason, vocabulary: v))",
                pid: reason.pid)
        case .refuse(let refusal):
            return DryRunReport(
                state: .error,
                message: "[dry-run] " + refusalMessage(
                    refusal, vocabulary: v, baseURL: baseURL, pidfilePath: pidfilePath),
                pid: nil)
        }
    }
}
