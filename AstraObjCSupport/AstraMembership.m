#import "AstraObjCSupport.h"
#import <membership.h>
#import <unistd.h>
#import <pwd.h>
#import <grp.h>

@implementation AstraMembership

+ (nullable NSString *)posixPrincipalForUUID:(const unsigned char *)principalUUID {
    id_t identifier;
    int type;
    if (mbr_uuid_to_id(principalUUID, &identifier, &type) != 0) { return nil; }
    char buffer[16 * 1024];
    if (type == ID_TYPE_UID) {
        struct passwd entry, *result = NULL;
        if (getpwuid_r(identifier, &entry, buffer, sizeof(buffer), &result) == 0 && result) {
            return [@"user:" stringByAppendingString:[NSString stringWithUTF8String:result->pw_name]];
        }
    } else if (type == ID_TYPE_GID) {
        struct group entry, *result = NULL;
        if (getgrgid_r(identifier, &entry, buffer, sizeof(buffer), &result) == 0 && result) {
            return [@"group:" stringByAppendingString:[NSString stringWithUTF8String:result->gr_name]];
        }
    }
    return nil;
}

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
