import Foundation
import DAWControl
import DAWAppKit

// The `debug.defaultsDomain` handler (m23-gf-f) — the app's own statement of
// which `UserDefaults` domain it persists under.
//
// ⚠️ IT LIVES IN AN `extension AppModel` IN ITS OWN FILE — the m23-cq-1
// deviation, for its reason: `DAWProApp.swift` is 10 000+ lines and a standing
// merge magnet, so the footprint there is one dispatch line.
//
// ⛔ **READ-ONLY, AND THAT IS THE POINT OF THE VERB.** This surface exists to
// prove staging does not pollute the user's preferences domain. A handler that
// wrote so much as one key while answering would be evidence-destroying: it
// would be creating the very pollution it is asked to rule out, and worse, it
// would do so in whichever domain turned out to be wrong. Every read below goes
// through `DefaultsDomainReport`, whose whole surface takes read closures only.
//
// ⚠️ ZERO WIRE GROWTH — `allCommands` and the MCP tool list are untouched.
// `debug.*` is the app-tier staging surface `Commands.swift:173-183` defines as
// deliberately off both (`appCommandHandler`'s doc: "developer/verification
// surface, not an agent-facing capability"). MEASURED before adding this one,
// with a positive control: 64 distinct `debug.*` verbs existed on the control
// side and ZERO were registered as MCP tools — the single `"debug.` occurrence
// in `mcp-server/src/server.ts` is a MENTION INSIDE A DESCRIPTION STRING
// (`server.ts:1946`), not a registration, while the same grep finds 18 `"track.`
// registrations, so the instrument works. A harness introspection verb is not
// the "user-facing capability" CLAUDE.md's every-capability rule is about; the
// roadmap item's "needs an MCP tool" clause was corrected in place rather than
// obeyed.
//
// ⚠️ NO `rejectUnknownKeys` — matching the neighbours, not an oversight: that
// helper is used by the `DAWControl` product commands and by none of the 64
// app-tier debug verbs (measured: 0 occurrences in `DAWProApp.swift`). A typed
// `probeKey` is still parsed before it is believed, per the m23-du(a) law.
extension AppModel {

    /// `debug.defaultsDomain` — reports the preferences domain THIS process
    /// persists under.
    ///
    /// Params (all optional):
    ///   * `probeKey` — a `UserDefaults` key to run the agreement measurement
    ///     against. Must be a non-empty string when present; a present-but-wrong
    ///     type errors rather than silently degrading the call into the bare
    ///     read (the m23-du(a) law: `{probeKey: 5}` is a mistake, not a read).
    ///
    /// Response:
    /// ```
    /// { processName, bundleIdentifier|null, derivedDomain,
    ///   derivedDomainExists, derivedDomainKeyCount|null,
    ///   probe: null | { key, standardValue|null, derivedDomainValue|null,
    ///                   presentInStandard, presentInDerivedDomain,
    ///                   valuesMatch, vacuous, agrees } }
    /// ```
    ///
    /// ⛔ `derivedDomain` IS A DERIVATION AND ITS NAME SAYS SO. It applies
    /// CFPreferences' documented rule (bundle identifier, else process name); it
    /// does not observe where `cfprefsd` put bytes. There is deliberately no
    /// second, shorter `domain` alias for it — two spellings of one value is the
    /// divergence the one-home rule exists to prevent, and the shorter name is
    /// exactly the one that would read as a measurement.
    ///
    /// `probe` is the measured half, and the ONLY field here that can contradict
    /// the derivation. Assert `probe.agrees` — never `valuesMatch`, which is
    /// trivially true for a key nobody ever wrote.
    func defaultsDomainDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        var probeKey: String?
        if let requested = params["probeKey"] {
            guard let key = requested.stringValue, !key.isEmpty else {
                throw DebugError("debug.defaultsDomain probeKey must be a non-empty string")
            }
            probeKey = key
        }
        return Self.defaultsDomainJSON(DefaultsDomainReport.live(probeKey: probeKey))
    }

    /// The `Snapshot` → wire mapping, `static` and free of `self` so it is a
    /// pure rendering step: the handler above decides nothing this does not
    /// show.
    static func defaultsDomainJSON(_ snapshot: DefaultsDomainReport.Snapshot) -> JSONValue {
        var object: [String: JSONValue] = [
            "processName": .string(snapshot.processName),
            // Nullable BY CONTRACT, both ways: `null` for the bare binary the
            // gates launch, a string for the bundled app. Never a placeholder —
            // a caller must be able to tell the two launch shapes apart.
            "bundleIdentifier": snapshot.bundleIdentifier.map(JSONValue.string) ?? .null,
            "derivedDomain": .string(snapshot.derivedDomain),
            // Distinct from `derivedDomainKeyCount == 0`: a domain that does not
            // exist and a domain that exists and is empty are different facts,
            // and collapsing them would hide a wrong-domain answer behind a
            // plausible zero.
            "derivedDomainExists": .bool(snapshot.derivedDomainKeyCount != nil),
            "derivedDomainKeyCount": snapshot.derivedDomainKeyCount
                .map { JSONValue.number(Double($0)) } ?? .null,
            "probe": .null,
        ]
        if let probe = snapshot.probe {
            object["probe"] = .object([
                "key": .string(probe.key),
                // The DISPLAY rendering, for a human reading a gate log.
                // Equality was decided on the type-aware fingerprint inside
                // `ProbeValue`, never on these strings.
                "standardValue": probe.standardValue.map { JSONValue.string($0.display) } ?? .null,
                "derivedDomainValue": probe.derivedDomainValue
                    .map { JSONValue.string($0.display) } ?? .null,
                "presentInStandard": .bool(probe.presentInStandard),
                "presentInDerivedDomain": .bool(probe.presentInDerivedDomain),
                "valuesMatch": .bool(probe.valuesMatch),
                "vacuous": .bool(probe.vacuous),
                "agrees": .bool(probe.agrees),
            ])
        }
        return .object(object)
    }
}
