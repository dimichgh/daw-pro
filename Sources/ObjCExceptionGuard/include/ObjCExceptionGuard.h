#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Objective-C exception barrier for the engine seam (m16-a Leg 1,
// docs/research/design-m16a-canvas-crash.md §4).
//
// Swift cannot unwind ObjC exceptions: an AVFAudio raise (proven live:
// -[AVAudioPlayerNode playAtTime:] "player started when in a disconnected
// state") tears through the Swift concurrency job frames, leaks the runtime's
// executor-tracking TLS record, and either crashes the next SE-0423 dynamic
// actor-isolation check on garbage or wedges the MainActor silently. This
// @try/@catch runs the block and hands a caught NSException BACK AS A VALUE
// so the Swift side (DAWEngine's `withObjCExceptionBarrier`) can convert it
// into an ordinary thrown error.
//
// Control-plane only by contract: the barrier is never installed on the
// render thread (C8 — zero new real-time surface). Zero-cost on the happy
// path (arm64 zero-cost EH). The @catch body is a bare return — no
// allocation, no Swift re-entry — so the barrier itself is exception-safe.
FOUNDATION_EXPORT NSException *_Nullable
DAWCatchObjCException(void (NS_NOESCAPE ^_Nonnull block)(void));

NS_ASSUME_NONNULL_END
