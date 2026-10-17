#import "AstraObjCSupport.h"
#import <membership.h>
#import <unistd.h>

@implementation AstraMembership

+ (BOOL)currentUserMatchesPrincipal:(const unsigned char *)principalUUID {
    uuid_t user;
    if (mbr_uid_to_uuid(geteuid(), user) != 0) {
        return NO;
    }
    if (uuid_compare(user, principalUUID) == 0) {
        return YES;
    }
    int isMember = 0;
    return mbr_check_membership(user, principalUUID, &isMember) == 0 && isMember == 1;
}

@end
