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
static NSString *const kAstraBootstrapLabel = @"ASTRA secure keychain password";
static NSString *const kAstraBootstrapComment = @"Unlocks ASTRA's dedicated secret keychain. Do not delete.";
static NSString *const kAstraSecretAccessLabel = @"ASTRA secure credential";

@implementation AstraSecureKeychain

#pragma mark - User interaction guard

+ (void)disableKeychainUserInteractionSavingPrevious:(Boolean *)previous {
    [self setKeychainUserInteractionAllowed:false savingPrevious:previous];
}

+ (void)allowKeychainUserInteractionSavingPrevious:(Boolean *)previous {
    [self setKeychainUserInteractionAllowed:true savingPrevious:previous];
}

+ (void)setKeychainUserInteractionAllowed:(Boolean)allowed savingPrevious:(Boolean *)previous {
    Boolean previousAllowed = true;
    if (SecKeychainGetUserInteractionAllowed(&previousAllowed) != errSecSuccess) {
        previousAllowed = true;
    }
    if (previous != NULL) { *previous = previousAllowed; }
    SecKeychainSetUserInteractionAllowed(allowed);
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

+ (BOOL)deleteBootstrapPasswordForService:(NSString *)service {
    SecKeychainRef login = NULL;
    if (SecKeychainCopyDefault(&login) != errSecSuccess || login == NULL) {
        return NO;
    }

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: kAstraBootstrapAccount,
        (__bridge id)kSecMatchSearchList: @[(__bridge id)login],
    };
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    CFRelease(login);
    return status == errSecSuccess || status == errSecItemNotFound;
}

+ (BOOL)moveUnreadableKeychainAsideAtPath:(NSString *)path {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return YES;
    }

    NSString *directory = [path stringByDeletingLastPathComponent];
    NSString *fileName = [path lastPathComponent];
    NSString *backupName = [NSString stringWithFormat:@"%@.unreadable-%@",
                            fileName,
                            NSUUID.UUID.UUIDString];
    NSString *backupPath = [directory stringByAppendingPathComponent:backupName];
    NSError *error = nil;
    BOOL moved = [[NSFileManager defaultManager] moveItemAtPath:path
                                                         toPath:backupPath
                                                          error:&error];
    return moved;
}

+ (BOOL)recoverUnreadableDedicatedKeychainAtPath:(NSString *)path
                                bootstrapService:(NSString *)bootstrapService {
    @synchronized (self) {
        [[self keychainCache] removeObjectForKey:path];
    }
    if (![self deleteBootstrapPasswordForService:bootstrapService]) {
        return NO;
    }
    return [self moveUnreadableKeychainAsideAtPath:path];
}

#pragma mark - Bootstrap password (stored in the login keychain)

+ (SecAccessRef)nonPromptingAccessWithLabel:(NSString *)label {
    SecAccessRef access = NULL;
    OSStatus status = SecAccessCreate((__bridge CFStringRef)label, NULL, &access);
    if (status != errSecSuccess || access == NULL) {
        if (access != NULL) { CFRelease(access); }
        return NULL;
    }
    // Keep the default access control from SecAccessCreate: only the creating
    // ASTRA binary is trusted. Rebuilt ad-hoc binaries that can no longer read
    // older items are handled by the unreadable-keychain recovery path instead
    // of widening the decrypt ACL to every local process.
    return access;
}

+ (SecAccessRef)nonPromptingBootstrapAccess {
    return [self nonPromptingAccessWithLabel:kAstraBootstrapLabel];
}

+ (SecAccessRef)nonPromptingSecretAccess {
    return [self nonPromptingAccessWithLabel:kAstraSecretAccessLabel];
}

+ (NSData *)readBootstrapPasswordForService:(NSString *)service
                              loginKeychain:(SecKeychainRef)login
                                      status:(OSStatus *)outStatus {
    const char *serviceName = service.UTF8String;
    const char *accountName = kAstraBootstrapAccount.UTF8String;
    if (serviceName == NULL || accountName == NULL) {
        if (outStatus != NULL) { *outStatus = errSecParam; }
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
    if (outStatus != NULL) { *outStatus = readStatus; }
    if (readStatus != errSecSuccess || passwordBytes == NULL) {
        if (passwordBytes != NULL) { SecKeychainItemFreeContent(NULL, passwordBytes); }
        return nil;
    }

    NSData *data = [NSData dataWithBytes:passwordBytes length:passwordLength];
    SecKeychainItemFreeContent(NULL, passwordBytes);
    return data;
}

+ (NSData *)readSecretDataForAccount:(NSString *)account
                              service:(NSString *)service
                             keychain:(SecKeychainRef)keychain
                               status:(OSStatus *)outStatus {
    const char *serviceName = service.UTF8String;
    const char *accountName = account.UTF8String;
    if (serviceName == NULL || accountName == NULL) {
        if (outStatus != NULL) { *outStatus = errSecParam; }
        return nil;
    }

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
    if (outStatus != NULL) { *outStatus = status; }
    if (status != errSecSuccess || passwordData == NULL) {
        if (passwordData != NULL) { SecKeychainItemFreeContent(NULL, passwordData); }
        return nil;
    }

    NSData *data = [NSData dataWithBytes:passwordData length:passwordLength];
    SecKeychainItemFreeContent(NULL, passwordData);
    return data;
}

+ (OSStatus)addBootstrapPassword:(NSData *)passwordData
                       forService:(NSString *)service
                     loginKeychain:(SecKeychainRef)login {
    const char *serviceName = service.UTF8String;
    const char *accountName = kAstraBootstrapAccount.UTF8String;
    if (serviceName == NULL || accountName == NULL || passwordData.length == 0) {
        return errSecParam;
    }

    NSData *labelData = [kAstraBootstrapLabel dataUsingEncoding:NSUTF8StringEncoding];
    NSData *commentData = [kAstraBootstrapComment dataUsingEncoding:NSUTF8StringEncoding];
    SecKeychainAttribute attributes[] = {
        { kSecServiceItemAttr, (UInt32)strlen(serviceName), (void *)serviceName },
        { kSecAccountItemAttr, (UInt32)strlen(accountName), (void *)accountName },
        { kSecLabelItemAttr, (UInt32)labelData.length, (void *)labelData.bytes },
        { kSecCommentItemAttr, (UInt32)commentData.length, (void *)commentData.bytes },
    };
    SecKeychainAttributeList attributeList = { 4, attributes };

    SecAccessRef access = [self nonPromptingBootstrapAccess];
    if (access == NULL) { return errSecParam; }
    SecKeychainItemRef item = NULL;
    OSStatus addStatus = SecKeychainItemCreateFromContent(
        kSecGenericPasswordItemClass,
        &attributeList,
        (UInt32)passwordData.length,
        passwordData.bytes,
        login,
        access,
        &item
    );
    if (access != NULL) { CFRelease(access); }
    if (item != NULL) { CFRelease(item); }
    return addStatus;
}

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

    OSStatus readStatus = errSecSuccess;
    NSData *data = [self readBootstrapPasswordForService:service
                                           loginKeychain:login
                                                  status:&readStatus];
    if (data.length > 0) {
        CFRelease(login);
        return data;
    }

    if (!create) {
        CFRelease(login);
        return nil;
    }

    NSMutableData *randomBytes = [NSMutableData dataWithLength:32];
    if (SecRandomCopyBytes(kSecRandomDefault, randomBytes.length, randomBytes.mutableBytes) != errSecSuccess) {
        CFRelease(login);
        return nil;
    }
    NSData *passwordData = [[randomBytes base64EncodedStringWithOptions:0]
                           dataUsingEncoding:NSUTF8StringEncoding];

    OSStatus addStatus = [self addBootstrapPassword:passwordData
                                        forService:service
                                      loginKeychain:login];
    if (addStatus == errSecSuccess) {
        CFRelease(login);
        return passwordData;
    }

    CFRelease(login);
    if (addStatus == errSecDuplicateItem) {
        // Lost a race with another writer — re-read the persisted value.
        return [self bootstrapPasswordForService:service create:NO];
    }
    return nil;
}

+ (OSStatus)addSecretValue:(NSData *)valueData
                forAccount:(NSString *)account
                   service:(NSString *)service
                     label:(NSString *)label
                  keychain:(SecKeychainRef)keychain {
    const char *serviceName = service.UTF8String;
    const char *accountName = account.UTF8String;
    if (serviceName == NULL || accountName == NULL || valueData.length == 0) {
        return errSecParam;
    }

    NSString *itemLabel = label ?: @"Astra credential";
    NSData *labelData = [itemLabel dataUsingEncoding:NSUTF8StringEncoding];
    SecKeychainAttribute attributes[] = {
        { kSecServiceItemAttr, (UInt32)strlen(serviceName), (void *)serviceName },
        { kSecAccountItemAttr, (UInt32)strlen(accountName), (void *)accountName },
        { kSecLabelItemAttr, (UInt32)labelData.length, (void *)labelData.bytes },
        { kSecCommentItemAttr, (UInt32)labelData.length, (void *)labelData.bytes },
    };
    SecKeychainAttributeList attributeList = { 4, attributes };

    SecAccessRef access = [self nonPromptingSecretAccess];
    if (access == NULL) { return errSecParam; }
    SecKeychainItemRef item = NULL;
    OSStatus addStatus = SecKeychainItemCreateFromContent(
        kSecGenericPasswordItemClass,
        &attributeList,
        (UInt32)valueData.length,
        valueData.bytes,
        keychain,
        access,
        &item
    );
    if (access != NULL) { CFRelease(access); }
    if (item != NULL) { CFRelease(item); }
    return addStatus;
}

#pragma mark - CRUD

+ (BOOL)saveSecret:(NSString *)value
        forAccount:(NSString *)account
           service:(NSString *)service
             label:(nullable NSString *)label
      keychainPath:(NSString *)keychainPath
  bootstrapService:(NSString *)bootstrapService {
    return [self writeSecret:value
                  forAccount:account
                     service:service
                       label:label
                keychainPath:keychainPath
            bootstrapService:bootstrapService
        allowUserInteraction:false
      recoverUnreadableKeychain:true];
}

+ (BOOL)saveSecretAllowingUserInteraction:(NSString *)value
                               forAccount:(NSString *)account
                                  service:(NSString *)service
                                    label:(nullable NSString *)label
                             keychainPath:(NSString *)keychainPath
                         bootstrapService:(NSString *)bootstrapService {
    return [self writeSecret:value
                  forAccount:account
                     service:service
                       label:label
                keychainPath:keychainPath
            bootstrapService:bootstrapService
        allowUserInteraction:true
      recoverUnreadableKeychain:false];
}

+ (BOOL)writeSecret:(NSString *)value
         forAccount:(NSString *)account
            service:(NSString *)service
              label:(nullable NSString *)label
       keychainPath:(NSString *)keychainPath
   bootstrapService:(NSString *)bootstrapService
allowUserInteraction:(BOOL)allowUserInteraction
recoverUnreadableKeychain:(BOOL)recoverUnreadableKeychain {
    Boolean previousInteraction = true;
    if (allowUserInteraction) {
        [self allowKeychainUserInteractionSavingPrevious:&previousInteraction];
    } else {
        [self disableKeychainUserInteractionSavingPrevious:&previousInteraction];
    }
    @try {
    SecKeychainRef keychain = [self dedicatedKeychainForPath:keychainPath bootstrapService:bootstrapService];
    if (keychain == NULL) {
        if (!recoverUnreadableKeychain) {
            return NO;
        }
        if (![self recoverUnreadableDedicatedKeychainAtPath:keychainPath
                                           bootstrapService:bootstrapService]) {
            return NO;
        }
        keychain = [self dedicatedKeychainForPath:keychainPath bootstrapService:bootstrapService];
        if (keychain == NULL) { return NO; }
    }

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
    // Always replace instead of updating in place. Existing items may have ACLs
    // tied to an older ad-hoc ASTRA binary; mutating those ACLs with
    // SecKeychainItemSetAccess can block in securityd. Deleting by metadata and
    // recreating the item gives the new value the current rebuild-tolerant ACL.
    OSStatus deleteStatus = SecItemDelete((__bridge CFDictionaryRef)matchQuery);
    if (deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound) {
        return NO;
    }

    OSStatus addStatus = [self addSecretValue:data
                                   forAccount:account
                                      service:service
                                        label:label
                                     keychain:keychain];
    return addStatus == errSecSuccess;
    } @finally {
        [self restoreKeychainUserInteraction:previousInteraction];
    }
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

    OSStatus status = errSecSuccess;
    NSData *data = [self readSecretDataForAccount:account
                                          service:service
                                         keychain:keychain
                                           status:&status];
    if (data.length == 0) { return nil; }
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
    OSStatus status = errSecSuccess;
    NSData *data = [self readSecretDataForAccount:account
                                          service:service
                                         keychain:keychain
                                           status:&status];
    return data.length > 0;
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
