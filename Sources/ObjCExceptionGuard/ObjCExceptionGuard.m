#import "include/ObjCExceptionGuard.h"

NSException *_Nullable DAWCatchObjCException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        // Bare return only — no allocation, no logging, no Swift re-entry
        // inside the @catch (the barrier must be exception-safe itself).
        // NSExceptions from `raise`/`exceptionWithName:` are autoreleased at
        // throw, so returning at +0 is correct under both ARC and MRR.
        return exception;
    }
}
