#import "AstraObjCSupport.h"

@implementation AstraExceptionTrap

+ (nullable NSException *)catching:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}

@end
