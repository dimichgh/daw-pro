# Audio device recovery

What DAW Pro and its test gates touch on your Mac's audio system, and how to put
anything back. Written 2026-08-02; every claim here is from something we actually
observed on this machine, and the places where the obvious fix does **not** work
are called out rather than left for you to discover.

## What the app changes, and what it never changes

**Never changed, by design:**

- **Your system default output device.** The app pins its own output internally
  (`output.setDevice`). Choosing an output inside DAW Pro does not move your
  Mac's default — notification sounds, browser audio and everything else stay
  wherever you put them in System Settings.
- **Your real devices' settings.** Built-in speakers, the built-in microphone,
  `ZoomAudioDevice`, `ParrotAudioPlugin` and any interface you own are read but
  never written.

**Changed, and only during test gates:**

- **The loopback device's nominal sample rate.** Gates that need to prove the
  app behaves at 44.1 kHz stage a *loopback* device (BlackHole 2ch) at that rate
  and restore it afterwards. This is the one test surface, and it is never a
  device you listen through.

So under normal use there is nothing to restore. The rest of this page is for
when a gate is interrupted, or when the loopback driver misbehaves.

## Symptom → fix

### The loopback device is at the wrong sample rate

Harmless — nothing routes through it unless you ask. To set it back:

1. Open **Audio MIDI Setup** (`/Applications/Utilities`).
2. Select **BlackHole 2ch** in the left sidebar.
3. Set **Format** back to **48,000 Hz**.

Or from a terminal, check what it currently reads:

```bash
system_profiler SPAudioDataType | grep -A 4 BlackHole
```

⚠️ That command is fine for a quick look but is **not authoritative for virtual
devices** — it has shown stale or missing entries for BlackHole while the device
was genuinely present. Audio MIDI Setup is the reliable view.

### A device accepts playback but you hear nothing ("wedged")

This is a real failure mode we hit and confirmed: the driver reports success when
you start audio, then never delivers a single buffer. Nothing errors. It simply
goes quiet.

**Fix — restart the audio daemon:**

```bash
sudo killall coreaudiod
```

Audio drops out for a second or two and comes back. Nothing is lost; every app
reconnects on its own. This is safe to run whenever audio is behaving strangely,
and it is the first thing to try.

### A device is missing from the list entirely

Not the same as wedged — here the device does not appear at all.

**⚠️ Restarting the Mac does not reliably fix this, and we have measured that.**
On this machine BlackHole was installed on 3 July, the Mac was restarted on
6 July, and the device was *still* unpublished weeks later. If an installer told
you to reboot and the device is still absent afterwards, a second reboot will
probably not help either.

**What actually worked:**

```bash
brew reinstall blackhole-2ch
sudo killall coreaudiod
```

The reinstall rewrites the driver binary; the `killall` makes CoreAudio pick it
up. Together they published the device immediately.

### You want to be sure nothing is left running

Test gates launch a staging copy of the app on port **17695** — never the app you
have open, which uses 17600. If a gate is interrupted, check for leftovers:

```bash
ps ax | grep -i dawpro | grep -v grep
```

## Does restarting fix it?

Sometimes, but it is rarely the right first move:

| Situation | Restart helps? | Do this instead |
|---|---|---|
| Device wedged (silent, no error) | Yes, but slow | `sudo killall coreaudiod` |
| Wrong sample rate | No | Audio MIDI Setup |
| Device missing entirely | **Often not** — measured | Reinstall the driver, then `killall coreaudiod` |
| Leftover staging app | No | Quit it by PID |

`sudo killall coreaudiod` does, in seconds, what a restart does to the audio
system — so if you are reaching for a reboot to fix sound, try that first.

## Removing the loopback device

It is only needed for development gates. To remove it:

```bash
brew uninstall blackhole-2ch
sudo killall coreaudiod
```

Your normal audio is unaffected — it was never in the path unless something
explicitly selected it.
