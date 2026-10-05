import Foundation

// p2-ren Stage B″ (design `docs/design/2026-09-25-incremental-note-render.md`
// §17, erratum E9) — THE LAUNCH SWEEP.
//
// `ProvisionalRenderStore` removes the session folders of processes that are
// gone, but only at its own session's FIRST provisional build
// (`ensureSessionDirectory`). So after a relaunch, a crashed session's files
// stayed on disk until the user next edited a note. E9 names the fix: an
// app-side hook at launch. This is its one public seam; the app calls it once,
// where it builds the engine (`AppModel.init`), never from a view.
//
// ⚠️ A NEW FILE ON PURPOSE: `AudioEngine.swift` and
// `ProvisionalRenderStore.swift` belong to the p2-ren lane. The sweep's RULE
// stays there (`ProvisionalRenderStore.wipeDeadSessions`); nothing here
// restates it.

extension AudioEngine {

    /// Removes the provisional-render session folders (`<pid>-<uuid>`) under
    /// THIS engine's render cache whose process has exited, and leaves every
    /// live one alone: the user's app and a staging instance share the cache,
    /// and each keeps its own.
    ///
    /// ⛔ **NOT CALLED FROM `init`, AND THAT IS DELIBERATE.** Every engine test
    /// builds an `AudioEngine()` on the user's real cache directory before it
    /// points `stretchCache` at a temp one; a sweep in `init` would reach into
    /// `~/Library/Caches/DAWPro` from every test process. The app calls this
    /// once at launch, after building the engine.
    ///
    /// Synchronous and cheap: one directory listing of a folder that holds one
    /// entry per session, beside `pruneUntitledRecoveryBundles`' own launch
    /// sweep.
    public func wipeDeadProvisionalSessions() {
        Self.wipeDeadProvisionalSessions(provisionalRoot: Self.provisionalRoot(of: stretchCache))
    }

    /// The sweep on an explicit provisional root — the test seam, so a test
    /// hands it a TEMP root and never the user's cache.
    ///
    /// `except: ""` is safe: this session's own folder is named for THIS
    /// process's pid, which is running, so the sweep could never remove it
    /// (it usually does not exist yet at launch anyway).
    public nonisolated static func wipeDeadProvisionalSessions(provisionalRoot root: URL) {
        ProvisionalRenderStore.wipeDeadSessions(in: root, except: "")
    }
}
