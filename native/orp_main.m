// Entry point: runs when dyld loads OfflineRating.dylib (before main()).
#import <Foundation/Foundation.h>
#include "orp_core.h"

__attribute__((constructor)) static void orp_load(void) {
    @autoreleasepool { orp_core_start(); }
}
