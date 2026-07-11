#pragma once
#include <stdatomic.h>
#include <stdint.h>

// C11 atomics with explicit memory orders for state shared between the main
// actor and the audio render thread. Swift callers allocate these structs on
// the heap (UnsafeMutablePointer.allocate) so the address is stable — never
// pass `&property` of a Swift stored property (inout-to-pointer may hand the
// callee a shadow copy).

typedef struct { _Atomic(void *) ptr; } daw_atomic_ptr;
typedef struct { _Atomic(uint32_t) value; } daw_atomic_u32;
typedef struct { _Atomic(uint64_t) value; } daw_atomic_u64;

static inline void  daw_atomic_ptr_init(daw_atomic_ptr *a) { atomic_init(&a->ptr, NULL); }
static inline void *daw_atomic_ptr_load(daw_atomic_ptr *a) {
    return atomic_load_explicit(&a->ptr, memory_order_acquire);
}
static inline void *daw_atomic_ptr_exchange(daw_atomic_ptr *a, void *desired) {
    return atomic_exchange_explicit(&a->ptr, desired, memory_order_acq_rel);
}
static inline void daw_atomic_u32_store(daw_atomic_u32 *a, uint32_t v) {
    atomic_store_explicit(&a->value, v, memory_order_release);
}
static inline uint32_t daw_atomic_u32_exchange(daw_atomic_u32 *a, uint32_t v) {
    return atomic_exchange_explicit(&a->value, v, memory_order_acq_rel);
}
static inline uint32_t daw_atomic_u32_load(daw_atomic_u32 *a) {
    return atomic_load_explicit(&a->value, memory_order_acquire);
}
static inline void daw_atomic_u64_store(daw_atomic_u64 *a, uint64_t v) {
    atomic_store_explicit(&a->value, v, memory_order_release);
}
static inline uint64_t daw_atomic_u64_load(daw_atomic_u64 *a) {
    return atomic_load_explicit(&a->value, memory_order_acquire);
}
// Multi-producer accumulator increment: exact under any number of concurrent
// writers (AVAudioEngine's parallel render pool included). acq_rel, not
// relaxed — house rule: every cross-thread op carries an explicit
// acquire/release pairing; on arm64 this is a single LDADD, so the marginal
// cost over relaxed is negligible at telemetry rates. Returns the PRIOR value.
static inline uint64_t daw_atomic_u64_add(daw_atomic_u64 *a, uint64_t v) {
    return atomic_fetch_add_explicit(&a->value, v, memory_order_acq_rel);
}
// Multi-producer monotone max: the textbook CAS-max loop. BOUNDED and
// RT-acceptable: each compare_exchange_weak failure means another writer
// LANDED a higher-or-equal value (or a spurious LL/SC failure retries the
// same exchange), so iterations are bounded by the number of concurrently
// racing writers — the render pool width — and progress is GLOBAL even when
// a local retry occurs. No writer can spin unboundedly: once `current >= v`
// the loop exits without storing.
static inline void daw_atomic_u64_max(daw_atomic_u64 *a, uint64_t v) {
    uint64_t current = atomic_load_explicit(&a->value, memory_order_acquire);
    while (v > current) {
        if (atomic_compare_exchange_weak_explicit(&a->value, &current, v,
                                                  memory_order_acq_rel,
                                                  memory_order_acquire)) {
            return;
        }
        // `current` was reloaded by the failed CAS; loop re-tests v > current.
    }
}
