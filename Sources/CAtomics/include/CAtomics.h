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
