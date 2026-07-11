# Packaging

How the SwiftPM release build becomes a distributable macOS app bundle.

## M9 pkg-a — App bundle (ad-hoc signed)

`scripts/bundle.sh` turns the release build into a real, LaunchServices-registered
`dist/DAWPro.app`. This ends the bare-SPM-executable era: after running it the app
is a proper `.app` that Finder can launch and that answers the quit Apple event
**by name** (`quit app "DAW Pro"`), which is what makes the crash-b clean-exit /
`session.lock`-removal path externally drivable.

### Usage

```bash
bash scripts/bundle.sh
```

Runnable from the repo root; idempotent (a re-run replaces `dist/DAWPro.app`
cleanly). Steps:

1. `swift build -c release`
2. Copy the release binary to `dist/DAWPro.app/Contents/MacOS/DAWApp` — the
   executable name stays **DAWApp** (identical to the SPM product) so every
   `pgrep`/process-name gate script keeps working unchanged.
3. Render `Contents/Info.plist` from the `scripts/Info.plist` template with the
   version constants substituted (`CFBundleShortVersionString` `0.1.0`,
   `CFBundleVersion` `1` — both live as constants at the top of `bundle.sh`).
4. Ad-hoc code-sign: `codesign --force --sign - dist/DAWPro.app`.
5. Register with LaunchServices via `lsregister -f` so the quit-by-name Apple
   event resolves the bundle.

`dist/` is git-ignored (build output).

### Info.plist

The template `scripts/Info.plist` carries: `CFBundleExecutable` `DAWApp`,
`CFBundleName`/`CFBundleDisplayName` `DAW Pro`, `CFBundleIdentifier`
`dev.dawpro.app`, `CFBundlePackageType` `APPL`, `LSMinimumSystemVersion` `14.0`,
`NSHighResolutionCapable`, `LSApplicationCategoryType` `public.app-category.music`,
and `NSMicrophoneUsageDescription`. Version fields are placeholders
(`__SHORT_VERSION__`, `__BUNDLE_VERSION__`) substituted at bundle time — do not
hand-edit the copy that lands in the bundle; re-run `bundle.sh`.

**No icon** is shipped: the UI-asset pipeline (glass-b) is credential-blocked, so
there is no `CFBundleIconFile`. This is a deliberate, labeled gap, not something to
fill by hand-drawing.

### Bundle identifier and the UserDefaults domain

`CFBundleIdentifier` is `dev.dawpro.app`. A Finder-launched bundle uses that as its
`UserDefaults` suite/domain. The bare-binary era used the domain `DAWApp`, so
density / onboarding preferences written by the old bare binary **do not carry
over** to the bundled app. This is accepted for pkg-a — there is no migration.
A bundled first launch may therefore show onboarding / recovery sheets that a
seasoned bare-binary user would not.

### Microphone permission

`NSMicrophoneUsageDescription` is required because a bundled app carries its own
TCC identity. The bare binary inherited the launching terminal's microphone grant;
the first time the app runs as a `.app` it must declare its own usage string or
input recording hard-fails. This is the first time the app carries that key.

### ACE-Step sidecar directory (dev-launch works, installed copy needs an env var)

`SidecarManager` resolves the ACE-Step sidecar directory (`scripts/ace-step`) via
the `DAWPRO_ACESTEP_DIR` environment variable, or by walking up from the executable
looking for `Package.swift` and using `<repo>/scripts/ace-step`. A bundle that
lives in `dist/` inside the repo still walks up to the repo root, so
**dev launches of `dist/DAWPro.app` keep finding the sidecar**. A bundle that is
**copied or installed elsewhere** has no `Package.swift` above it and will report
`notInstalled` unless `DAWPRO_ACESTEP_DIR` is set. No new fallback was added this
cycle; this is a documented gap that a later install step (or an env-var launch)
must cover.

Nuance found in the pkg-d gate: the walk-up also resolves from the process's
**working directory**, so a copied bundle exec'd from a shell whose cwd is inside
the repo still reads `installedNotRunning`. Only a Finder launch (cwd `/`) shows
the pure installed-copy behavior described above.

## M9 pkg-d — DMG packaging

`scripts/dmg.sh` runs `bundle.sh` (idempotent), stages the app with an
`/Applications` symlink (the standard drag-to-install layout), and builds a
compressed UDZO image at `dist/DAWPro-<version>.dmg` (version read from the
built bundle's Info.plist), printing its SHA-256. Verified flow: mount → copy
out (simulated install) → the copy's signature still verifies → launches, honors
`DAW_CONTROL_PORT`, full wire round-trip → clean quit by Apple event removes the
session lock. Distribution to other machines carries the ad-hoc/Gatekeeper
caveat above until pkg-b/c land; locally-built images have no quarantine
attribute, so the copy runs friction-free on this machine.

### Ad-hoc signing / Gatekeeper caveat

The bundle is **ad-hoc** signed (identity `-`, `TeamIdentifier=not set`). It runs
without friction on the machine that built it. On another machine Gatekeeper will
block a double-click; the user must right-click > **Open** once to run it.
Developer ID signing and notarization (which lift that prompt) are
credential-blocked and land in pkg-b/pkg-c; a DMG installer is pkg-d.

## AU plugin windows (M3 vi-b) — bundle identity and the view ladder

Plugin-view hosting resolves through a never-failing ladder (design
`docs/research/design-vi-b-au-windows.md` §3.2): (1) `requestViewController` →
the plugin's own custom **v3** view; (2) for v2 units, `kAudioUnitProperty_CocoaUI`
→ load the vendor's view bundle in-process and build the `AUCocoaUIBase` view;
(3) `AUGenericViewController` → the system parameter body. A step-1 timeout or a
step-2 load failure degrades to the generic body with a `warning` field — the
ladder never errors.

**In-process bodies (steps 2–3) work identically bare and bundled.** They are
ordinary `NSBundle` + `NSView` — no bundle identity is involved — so the bare
`swift run DAWApp` dev flow hosts stock Apple v2 custom views (AUDelay,
DLSMusicDevice, …) and the generic fallback (AUMatrixReverb) with full pixels
through `debug.captureUI {target:"plugin"}`.

**Out-of-process AUv3 custom views (step 1, remote view service) need the real
`.app` bundle identity** that `bundle.sh` produces — the bare SPM executable
can't reliably host plugin view extensions (the recorded vi-a finding). That leg
is **untested on this machine: no AUv3 is installed** (`AVAudioUnitComponentManager`
lists only v2 Apple units; `pluginkit -m -p com.apple.AudioUnit-UI` is empty), so
the vi-b-2 gate's AUv3 custom-view assertion is **SKIPPED and recorded, never
faked**. A later machine with an AUv3 installed inherits the documented
degradation: if the remote view fails to attach, the ladder falls to the generic
body + warning rather than failing. A remote view that DOES attach rasterizes
blank through `cacheDisplay` (a documented capture limit — `plugin.listOpenUIs`
is the functional assertion there).
