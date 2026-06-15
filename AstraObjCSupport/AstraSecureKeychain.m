#import "AstraObjCSupport.h"
#import <Security/Security.h>

// The whole point of this file is the legacy *file-based* keychain API
// (SecKeychainCreate/Open/Unlock/Settings + kSecUseKeychain/kSecMatchSearchList),
// which Apple deprecated in macOS 10.10 in favor of the data-protection keychain.
// The data-protection keychain requires a Team-ID-prefixed access-group
// entitlement this ad-hoc/self-signed app does not have, so the file keychain is
// the only mechanism that isolates ASTRA's secrets out of login.keychain-db
// today. Suppress the deprecation warnings for the translation unit; the usage
// is intentional and reviewed.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/// Fixed account under which the dedicated keychain's unlock password is stored
/// in the login keychain (namespaced per channel via `bootstrapService`).
static NSString *const kAstraBootstrapAccount = @"keychain-bootstrap-password";

@implementation AstraSecureKeychain

#pragma mark - Dedicated keychain handle (cached per path)

/// Process-lifetime cache of opened+unlocked SecKeychainRefs, keyed by path. The
/// CF +1 from Create/Open is intentionally never released — the cache owns it.
+ (NSMutableDictionary<NSString *, NSValue *> *)keychainCache {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

/// Returns an unlocked keychain handle for `path`, creating the file on first
/// use, or NULL on any failure (callers then fail closed).
+ (SecKeychainRef)dedicatedKeychainForPath:(NSString *)path
                          bootstrapService:(NSString *)bootstrapService {
    @synchronized (self) {
        NSValue *cached = [self keychainCache][path];
        if (cached != nil) {
            return (SecKeychainRef)[cached pointerValue];
        }

        NSData *password = [self bootstrapPasswordForService:bootstrapService create:YES];
        if (password.length == 0) {
            return NULL;
        }

        const char *cPath = path.fileSystemRepresentation;
        SecKeychainRef keychain = NULL;
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];

        if (exists) {
            OSStatus openStatus = SecKeychainOpen(cPath, &keychain);
            if (openStatus != errSecSuccess || keychain == NULL) {
                if (keychain != NULL) { CFRelease(keychain); }
                return NULL;
            }
            OSStatus unlockStatus = SecKeychainUnlock(keychain,
                                                      (UInt32)password.length,
                                                      password.bytes,
                                                      true);
            if (unlockStatus != errSecSuccess) {
                CFRelease(keychain);
                return NULL;
            }
        } else {
            // Capture the user's keychain search list so we can keep the new
            // keychain OUT of it: it must only ever be reached via explicit
            // references, never an implicit default search, so a sibling
            // process can't enumerate it through securityd.
            CFArrayRef priorSearchList = NULL;
            SecKeychainCopySearchList(&priorSearchList);

            OSStatus createStatus = SecKeychainCreate(cPath,
                                                      (UInt32)password.length,
                                                      password.bytes,
                                                      false,   // promptUser
                                                      NULL,    // default access (trust creating app)
                                                      &keychain);
            if (createStatus != errSecSuccess || keychain == NULL) {
                if (priorSearchList != NULL) { CFRelease(priorSearchList); }
                if (keychain != NULL) { CFRelease(keychain); }
                return NULL;
            }
            if (priorSearchList != NULL) {
                SecKeychainSetSearchList(priorSearchList);
                CFRelease(priorSearchList);
            }
        }

        // Keep it usable for the whole app session (no auto-lock on sleep or
        // interval). The file on disk remains encrypted at rest regardless.
        SecKeychainSettings settings = {
            .version = SEC_KEYCHAIN_SETTINGS_VERS1,
            .lockOnSleep = false,
            .useLockInterval = false,
            .lockInterval = INT_MAX
        };
        SecKeychainSetSettings(keychain, &settings);

        [self keychainCache][path] = [NSValue valueWithPointer:keychain];
        return keychain;
    }
}

#pragma mark - Bootstrap password (stored in the login keychain)

/// Fetches the dedicated keychain's unlock password from the login keychain,
/// generating and persisting a fresh random one on first use when `create` is
/// YES. The password is useless to the sandboxed agent on its own: the agent
/// cannot read the dedicated keychain *file* it unlocks.
+ (NSData *)bootstrapPasswordForService:(NSString *)service create:(BOOL)create {
    SecKeychainRef login = NULL;
    SecKeychainCopyDefault(&login); // login keychain; may be NULL in odd sessions

    NSMutableDictionary *readQuery = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: kAstraBootstrapAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    } mutableCopy];
    if (login != NULL) {
        readQuery[(__bridge id)kSecMatchSearchList] = @[(__bridge id)login];
    }

    CFTypeRef result = NULL;
    OSStatus readStatus = SecItemCopyMatching((__bridge CFDictionaryRef)readQuery, &result);
    if (readStatus == errSecSuccess && result != NULL) {
        NSData *data = (__bridge_transfer NSData *)result;
        if (login != NULL) { CFRelease(login); }
        return data;
    }

    if (!create) {
        if (login != NULL) { CFRelease(login); }
        return nil;
    }

    NSMutableData *randomBytes = [NSMutableData dataWithLength:32];
    if (SecRandomCopyBytes(kSecRandomDefault, randomBytes.length, randomBytes.mutableBytes) != errSecSuccess) {
        if (login != NULL) { CFRelease(login); }
        return nil;
    }
    NSData *passwordData = [[randomBytes base64EncodedStringWithOptions:0]
                           dataUsingEncoding:NSUTF8StringEncoding];

    NSMutableDictionary *addQuery = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: kAstraBootstrapAccount,
        (__bridge id)kSecValueData: passwordData,
        (__bridge id)kSecAttrLabel: @"ASTRA secure keychain password",
        (__bridge id)kSecAttrComment: @"Unlocks ASTRA's dedicated secret keychain. Do not delete.",
    } mutableCopy];
    if (login != NULL) {
        addQuery[(__bridge id)kSecUseKeychain] = (__bridge id)login;
    }
    OSStatus addStatus = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    if (login != NULL) { CFRelease(login); }

    if (addStatus == errSecSuccess) {
        return passwordData;
    }
    if (addStatus == errSecDuplicateItem) {
        // Lost a race with another writer — re-read the persisted value.
        return [self bootstrapPasswordForService:service create:NO];
    }
    return nil;
}

#pragma mark - CRUD

+ (BOOL)saveSecret:(NSString *)value
        forAccount:(NSString *)account
           service:(NSString *)service
             label:(NSString *)label
      keychainPath:(NSString *)keychainPath
  bootstrapService:(NSString *)bootstrapService {
    SecKeychainRef keychain = [self dedicatedKeychainForPath:keychainPath bootstrapService:bootstrapService];
    if (keychain == NULL) { return NO; }

    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) { return NO; }

    NSDictionary *matchQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecMatchSearchList: @[(__bridge id)keychain],
    };
    NSDictionary *updateAttributes = @{
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrComment: label ?: @"Astra credential",
    };
    OSStatus updateStatus = SecItemUpdate((__bridge CFDictionaryRef)matchQuery,
                                          (__bridge CFDictionaryRef)updateAttributes);
    if (updateStatus == errSecSuccess) { return YES; }
    if (updateStatus != errSecItemNotFound) { return NO; }

    NSMutableDictionary *addQuery = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrComment: label ?: @"Astra credential",
        (__bridge id)kSecUseKeychain: (__bridge id)keychain,
    } mutableCopy];
    if (label != nil) {
        addQuery[(__bridge id)kSecAttrLabel] = label;
    }
    return SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL) == errSecSuccess;
}

+ (NSString *)secretForAccount:(NSString *)account
                       service:(NSString *)service
                  keychainPath:(NSString *)keychainPath
              bootstrapService:(NSString *)bootstrapService {
    SecKeychainRef keychain = [self dedicatedKeychainForPath:keychainPath bootstrapService:bootstrapService];
    if (keychain == NULL) { return nil; }

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecMatchSearchList: @[(__bridge id)keychain],
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || result == NULL) { return nil; }

    NSData *data = (__bridge_transfer NSData *)result;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (BOOL)deleteSecretForAccount:(NSString *)account
                       service:(NSString *)service
                  keychainPath:(NSString *)keychainPath
              bootstrapService:(NSString *)bootstrapService {
    SecKeychainRef keychain = [self dedicatedKeychainForPath:keychainPath bootstrapService:bootstrapService];
    if (keychain == NULL) { return NO; }

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecMatchSearchList: @[(__bridge id)keychain],
    };
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    return status == errSecSuccess || status == errSecItemNotFound;
}

+ (BOOL)deleteAllSecretsForService:(NSString *)service
                      keychainPath:(NSString *)keychainPath
                  bootstrapService:(NSString *)bootstrapService {
    SecKeychainRef keychain = [self dedicatedKeychainForPath:keychainPath bootstrapService:bootstrapService];
    if (keychain == NULL) { return NO; }

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecMatchSearchList: @[(__bridge id)keychain],
    };
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    return status == errSecSuccess || status == errSecItemNotFound;
}

+ (BOOL)hasSecretForAccount:(NSString *)account
                    service:(NSString *)service
               keychainPath:(NSString *)keychainPath
           bootstrapService:(NSString *)bootstrapService {
    SecKeychainRef keychain = [self dedicatedKeychainForPath:keychainPath bootstrapService:bootstrapService];
    if (keychain == NULL) { return NO; }

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecMatchSearchList: @[(__bridge id)keychain],
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (result != NULL) { CFRelease(result); }
    return status == errSecSuccess;
}

#pragma mark - Migration & login-keychain probe

+ (NSInteger)migrateServiceFromLoginKeychain:(NSString *)service
                                keychainPath:(NSString *)keychainPath
                            bootstrapService:(NSString *)bootstrapService {
    SecKeychainRef login = NULL;
    if (SecKeychainCopyDefault(&login) != errSecSuccess || login == NULL) {
        return 0; // no login keychain → nothing to migrate
    }

    // Enumerate the accounts for this service. Note: kSecReturnData cannot be
    // combined with kSecMatchLimitAll in one query, so we fetch attributes here
    // and pull each item's data individually below.
    NSDictionary *listQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecMatchSearchList: @[(__bridge id)login],
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
    };
    CFTypeRef listResult = NULL;
    OSStatus listStatus = SecItemCopyMatching((__bridge CFDictionaryRef)listQuery, &listResult);
    if (listStatus == errSecItemNotFound) {
        CFRelease(login);
        return 0;
    }
    if (listStatus != errSecSuccess || listResult == NULL) {
        CFRelease(login);
        return -1;
    }

    NSArray<NSDictionary *> *items = (__bridge_transfer NSArray *)listResult;
    NSInteger moved = 0;
    for (NSDictionary *item in items) {
        NSString *account = item[(__bridge id)kSecAttrAccount];
        if (account == nil) { continue; }

        NSDictionary *valueQuery = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: service,
            (__bridge id)kSecAttrAccount: account,
            (__bridge id)kSecMatchSearchList: @[(__bridge id)login],
            (__bridge id)kSecReturnData: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
        };
        CFTypeRef valueResult = NULL;
        OSStatus valueStatus = SecItemCopyMatching((__bridge CFDictionaryRef)valueQuery, &valueResult);
        if (valueStatus != errSecSuccess || valueResult == NULL) { continue; }
        NSData *data = (__bridge_transfer NSData *)valueResult;
        NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (value == nil) { continue; }
        NSString *label = item[(__bridge id)kSecAttrLabel];

        // Copy first; only delete from login once the dedicated write succeeds,
        // so an interrupted migration never loses a secret.
        BOOL saved = [self saveSecret:value
                           forAccount:account
                              service:service
                                label:label
                         keychainPath:keychainPath
                     bootstrapService:bootstrapService];
        if (!saved) { continue; }

        NSDictionary *deleteQuery = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: service,
            (__bridge id)kSecAttrAccount: account,
            (__bridge id)kSecMatchSearchList: @[(__bridge id)login],
        };
        OSStatus deleteStatus = SecItemDelete((__bridge CFDictionaryRef)deleteQuery);
        if (deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound) {
            moved += 1;
        }
    }
    CFRelease(login);
    return moved;
}

+ (BOOL)loginKeychainContainsService:(NSString *)service
                             account:(NSString *)account {
    SecKeychainRef login = NULL;
    if (SecKeychainCopyDefault(&login) != errSecSuccess || login == NULL) {
        return NO;
    }
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecMatchSearchList: @[(__bridge id)login],
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    } mutableCopy];
    if (account != nil) {
        query[(__bridge id)kSecAttrAccount] = account;
    }
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (result != NULL) { CFRelease(result); }
    CFRelease(login);
    return status == errSecSuccess;
}

@end

#pragma clang diagnostic pop
