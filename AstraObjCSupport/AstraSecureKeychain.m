#import "AstraObjCSupport.h"
#import <Security/Security.h>
#import <string.h>

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

#pragma mark - User interaction guard

+ (void)disableKeychainUserInteractionSavingPrevious:(Boolean *)previous {
    Boolean allowed = true;
    if (SecKeychainGetUserInteractionAllowed(&allowed) != errSecSuccess) {
        allowed = true;
    }
    if (previous != NULL) { *previous = allowed; }
    SecKeychainSetUserInteractionAllowed(false);
}

+ (void)restoreKeychainUserInteraction:(Boolean)previous {
    SecKeychainSetUserInteractionAllowed(previous);
}

+ (void)performWithKeychainUserInteractionDisabled:(NS_NOESCAPE void (^)(void))block {
    if (block == nil) { return; }
    Boolean previousInteraction = true;
    [self disableKeychainUserInteractionSavingPrevious:&previousInteraction];
    @try {
        block();
    } @finally {
        [self restoreKeychainUserInteraction:previousInteraction];
    }
}

+ (NSMutableDictionary<NSString *, NSData *> *)testBootstrapPasswordOverrides {
    static NSMutableDictionary *overrides;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ overrides = [NSMutableDictionary dictionary]; });
    return overrides;
}

+ (BOOL)hasTestBootstrapPasswordOverrideForService:(NSString *)bootstrapService {
    @synchronized (self) {
        return [self testBootstrapPasswordOverrides][bootstrapService] != nil;
    }
}

+ (void)setTestBootstrapPassword:(NSString *)password
             forBootstrapService:(NSString *)bootstrapService {
    NSData *data = [password dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) { return; }
    @synchronized (self) {
        [self testBootstrapPasswordOverrides][bootstrapService] = data;
    }
}

+ (void)clearTestBootstrapPasswordForBootstrapService:(NSString *)bootstrapService {
    @synchronized (self) {
        [[self testBootstrapPasswordOverrides] removeObjectForKey:bootstrapService];
    }
}

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

        const char *cPath = path.fileSystemRepresentation;
        SecKeychainRef keychain = NULL;
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];

        // Only mint a fresh bootstrap password when creating a brand-new keychain
        // file. If the file already exists but its bootstrap item is gone (e.g.
        // the user deleted it from the login keychain), generating a new password
        // here would both fail to unlock the existing keychain AND leave an
        // orphaned wrong password behind — so for an existing file we require the
        // stored password and otherwise fail closed.
        NSData *password = [self bootstrapPasswordForService:bootstrapService create:!exists];
        if (password.length == 0) {
            return NULL;
        }

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
            BOOL usesTestBootstrapOverride =
                [self hasTestBootstrapPasswordOverrideForService:bootstrapService];
            CFArrayRef priorSearchList = NULL;
            OSStatus copyStatus = usesTestBootstrapOverride
                ? errSecSuccess
                : SecKeychainCopySearchList(&priorSearchList);

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

            // Restore the prior search list so the new keychain stays out of it.
            // If we cannot (couldn't snapshot it, or the restore failed), the
            // keychain may remain globally searchable, defeating the isolation —
            // so delete it and fail closed rather than ship a weaker boundary.
            OSStatus restoreStatus = errSecSuccess;
            if (!usesTestBootstrapOverride) {
                restoreStatus =
                    (copyStatus == errSecSuccess && priorSearchList != NULL)
                        ? SecKeychainSetSearchList(priorSearchList)
                        : errSecParam;
            }
            if (priorSearchList != NULL) { CFRelease(priorSearchList); }
            if (restoreStatus != errSecSuccess) {
                SecKeychainDelete(keychain);
                CFRelease(keychain);
                return NULL;
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
    @synchronized (self) {
        NSData *override = [self testBootstrapPasswordOverrides][service];
        if (override != nil) { return override; }
    }

    SecKeychainRef login = NULL;
    if (SecKeychainCopyDefault(&login) != errSecSuccess || login == NULL) {
        return nil;
    }

    const char *serviceName = service.UTF8String;
    const char *accountName = kAstraBootstrapAccount.UTF8String;
    if (serviceName == NULL || accountName == NULL) {
        CFRelease(login);
        return nil;
    }

    UInt32 passwordLength = 0;
    void *passwordBytes = NULL;
    OSStatus readStatus = SecKeychainFindGenericPassword(
        login,
        (UInt32)strlen(serviceName), serviceName,
        (UInt32)strlen(accountName), accountName,
        &passwordLength,
        &passwordBytes,
        NULL
    );
    if (readStatus == errSecSuccess && passwordBytes != NULL) {
        NSData *data = [NSData dataWithBytes:passwordBytes length:passwordLength];
        SecKeychainItemFreeContent(NULL, passwordBytes);
        CFRelease(login);
        return data;
    }

    if (!create) {
        if (passwordBytes != NULL) { SecKeychainItemFreeContent(NULL, passwordBytes); }
        CFRelease(login);
        return nil;
    }
    if (passwordBytes != NULL) {
        SecKeychainItemFreeContent(NULL, passwordBytes);
        passwordBytes = NULL;
    }

    NSMutableData *randomBytes = [NSMutableData dataWithLength:32];
    if (SecRandomCopyBytes(kSecRandomDefault, randomBytes.length, randomBytes.mutableBytes) != errSecSuccess) {
        if (passwordBytes != NULL) { SecKeychainItemFreeContent(NULL, passwordBytes); }
        CFRelease(login);
        return nil;
    }
    NSData *passwordData = [[randomBytes base64EncodedStringWithOptions:0]
                           dataUsingEncoding:NSUTF8StringEncoding];

    SecKeychainItemRef item = NULL;
    OSStatus addStatus = SecKeychainAddGenericPassword(
        login,
        (UInt32)strlen(serviceName), serviceName,
        (UInt32)strlen(accountName), accountName,
        (UInt32)passwordData.length,
        passwordData.bytes,
        &item
    );
    if (addStatus == errSecSuccess && item != NULL) {
        NSString *label = @"ASTRA secure keychain password";
        NSString *comment = @"Unlocks ASTRA's dedicated secret keychain. Do not delete.";
        NSData *labelData = [label dataUsingEncoding:NSUTF8StringEncoding];
        NSData *commentData = [comment dataUsingEncoding:NSUTF8StringEncoding];
        SecKeychainAttribute attributes[] = {
            { kSecLabelItemAttr, (UInt32)labelData.length, (void *)labelData.bytes },
            { kSecCommentItemAttr, (UInt32)commentData.length, (void *)commentData.bytes },
        };
        SecKeychainAttributeList attributeList = { 2, attributes };
        OSStatus attributeStatus = SecKeychainItemModifyAttributesAndData(
            item,
            &attributeList,
            (UInt32)passwordData.length,
            passwordData.bytes
        );
        CFRelease(item);
        CFRelease(login);
        return attributeStatus == errSecSuccess ? passwordData : nil;
    }

    if (item != NULL) { CFRelease(item); }
    CFRelease(login);
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
             label:(nullable NSString *)label
      keychainPath:(NSString *)keychainPath
  bootstrapService:(NSString *)bootstrapService {
    SecKeychainRef keychain = [self dedicatedKeychainForPath:keychainPath bootstrapService:bootstrapService];
    if (keychain == NULL) { return NO; }

    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) { return NO; }

    const char *serviceName = service.UTF8String;
    const char *accountName = account.UTF8String;
    if (serviceName == NULL || accountName == NULL) { return NO; }

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

    NSString *comment = label ?: @"Astra credential";
    NSData *labelData = [comment dataUsingEncoding:NSUTF8StringEncoding];
    SecKeychainAttribute attributes[] = {
        { kSecLabelItemAttr, (UInt32)labelData.length, (void *)labelData.bytes },
        { kSecCommentItemAttr, (UInt32)labelData.length, (void *)labelData.bytes },
    };
    SecKeychainAttributeList attributeList = { 2, attributes };

    SecKeychainItemRef addedItem = NULL;
    OSStatus addStatus = SecKeychainAddGenericPassword(
        keychain,
        (UInt32)strlen(serviceName), serviceName,
        (UInt32)strlen(accountName), accountName,
        (UInt32)data.length,
        data.bytes,
        &addedItem
    );
    if (addStatus != errSecSuccess || addedItem == NULL) {
        if (addedItem != NULL) { CFRelease(addedItem); }
        return NO;
    }
    OSStatus attributeStatus = SecKeychainItemModifyAttributesAndData(
        addedItem,
        &attributeList,
        (UInt32)data.length,
        data.bytes
    );
    CFRelease(addedItem);
    return attributeStatus == errSecSuccess;
}

+ (nullable NSString *)secretForAccount:(NSString *)account
                                service:(NSString *)service
                           keychainPath:(NSString *)keychainPath
                       bootstrapService:(NSString *)bootstrapService {
    Boolean previousInteraction = true;
    [self disableKeychainUserInteractionSavingPrevious:&previousInteraction];
    @try {
    SecKeychainRef keychain = [self dedicatedKeychainForPath:keychainPath bootstrapService:bootstrapService];
    if (keychain == NULL) { return nil; }

    const char *serviceName = service.UTF8String;
    const char *accountName = account.UTF8String;
    if (serviceName == NULL || accountName == NULL) { return nil; }

    UInt32 passwordLength = 0;
    void *passwordData = NULL;
    OSStatus status = SecKeychainFindGenericPassword(
        keychain,
        (UInt32)strlen(serviceName), serviceName,
        (UInt32)strlen(accountName), accountName,
        &passwordLength,
        &passwordData,
        NULL
    );
    if (status != errSecSuccess || passwordData == NULL) { return nil; }

    NSData *data = [NSData dataWithBytes:passwordData length:passwordLength];
    SecKeychainItemFreeContent(NULL, passwordData);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    } @finally {
        [self restoreKeychainUserInteraction:previousInteraction];
    }
}

+ (BOOL)deleteSecretForAccount:(NSString *)account
                       service:(NSString *)service
                  keychainPath:(NSString *)keychainPath
              bootstrapService:(NSString *)bootstrapService {
    Boolean previousInteraction = true;
    [self disableKeychainUserInteractionSavingPrevious:&previousInteraction];
    @try {
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
    } @finally {
        [self restoreKeychainUserInteraction:previousInteraction];
    }
}

+ (BOOL)deleteAllSecretsForService:(NSString *)service
                      keychainPath:(NSString *)keychainPath
                  bootstrapService:(NSString *)bootstrapService {
    Boolean previousInteraction = true;
    [self disableKeychainUserInteractionSavingPrevious:&previousInteraction];
    @try {
    SecKeychainRef keychain = [self dedicatedKeychainForPath:keychainPath bootstrapService:bootstrapService];
    if (keychain == NULL) { return NO; }

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecMatchSearchList: @[(__bridge id)keychain],
    };
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    return status == errSecSuccess || status == errSecItemNotFound;
    } @finally {
        [self restoreKeychainUserInteraction:previousInteraction];
    }
}

+ (BOOL)hasSecretForAccount:(NSString *)account
                    service:(NSString *)service
               keychainPath:(NSString *)keychainPath
           bootstrapService:(NSString *)bootstrapService {
    Boolean previousInteraction = true;
    [self disableKeychainUserInteractionSavingPrevious:&previousInteraction];
    @try {
    SecKeychainRef keychain = [self dedicatedKeychainForPath:keychainPath bootstrapService:bootstrapService];
    if (keychain == NULL) { return NO; }

    const char *serviceName = service.UTF8String;
    const char *accountName = account.UTF8String;
    if (serviceName == NULL || accountName == NULL) { return NO; }
    SecKeychainItemRef item = NULL;
    OSStatus status = SecKeychainFindGenericPassword(
        keychain,
        (UInt32)strlen(serviceName), serviceName,
        (UInt32)strlen(accountName), accountName,
        NULL, NULL,
        &item
    );
    if (item != NULL) { CFRelease(item); }
    return status == errSecSuccess;
    } @finally {
        [self restoreKeychainUserInteraction:previousInteraction];
    }
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
                             account:(nullable NSString *)account {
    Boolean previousInteraction = true;
    [self disableKeychainUserInteractionSavingPrevious:&previousInteraction];
    @try {
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
    } @finally {
        [self restoreKeychainUserInteraction:previousInteraction];
    }
}

@end

#pragma clang diagnostic pop
