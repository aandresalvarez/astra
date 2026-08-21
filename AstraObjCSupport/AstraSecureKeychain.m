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
        [self clearRetryFloorsForBootstrapService:bootstrapService];
    }
}

+ (void)clearTestBootstrapPasswordForBootstrapService:(NSString *)bootstrapService {
    @synchronized (self) {
        [[self testBootstrapPasswordOverrides] removeObjectForKey:bootstrapService];
        [self clearRetryFloorsForBootstrapService:bootstrapService];
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

/// How long a failed open suppresses further attempts on the same path.
///
/// Only *success* was ever cached: all five failure returns below leave
/// `keychainCache` empty, so the next caller redid `SecKeychainCopyDefault` +
/// `SecKeychainFindGenericPassword` + open + unlock from scratch — a securityd
/// round trip each, with a C++ throw inside Security.framework on the way out.
/// Callers are not sparse enough for that to be survivable: one
/// `CapabilitySetupCopier.copySetup` issues over a hundred loads, and
/// `WorkspaceSetupForm.capabilitiesSection` ran three of those per body pass,
/// from `body`, on the main thread. On a 16-workspace store that measured as
/// thousands of consecutive failing round trips and a multi-second hang opening
/// the New Workspace sheet.
///
/// Deliberately short. The usual causes are ones the user can still clear
/// without relaunching — a rebuilt ad-hoc binary missing from the bootstrap
/// item's partition list, a locked keychain, a declined prompt — so the app has
/// to keep noticing. Two seconds collapses a burst to one attempt while still
/// recovering inside a single gesture.
static const NSTimeInterval kAstraKeychainUnavailableBackoff = 2.0;

/// The last failure recorded per (path, bootstrap service): `kAstraFailureUntil`
/// (NSDate — the retry floor), `kAstraFailureStage`, `kAstraFailureStatus`.
///
/// Both halves of the key are inputs to the open: the bootstrap password is what
/// unlocks the file, so "path P could not be opened" is only ever true relative
/// to the service the password was looked up under. Keying on path alone would
/// let a failure under one service suppress a working one.
///
/// In the app this holds at most one entry (there is a single dedicated
/// keychain), and that entry is removed the moment the open succeeds.
+ (NSMutableDictionary<NSString *, NSDictionary *> *)keychainFailures {
    static NSMutableDictionary *failures;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ failures = [NSMutableDictionary dictionary]; });
    return failures;
}

static NSString *const kAstraFailureUntil = @"until";
static NSString *const kAstraFailureStage = @"stage";
static NSString *const kAstraFailureStatus = @"status";
/// Whether the attempt that recorded this floor ran with Keychain UI enabled.
/// A floor set by a background read must not suppress a user's click, but a
/// floor set by a user's click must suppress the next one — see the floor check
/// in `dedicatedKeychainForPath:bootstrapService:userInteractionAllowed:`.
static NSString *const kAstraFailureInteractive = @"interactive";

/// A newline cannot appear in a bootstrap service (they are compile-time
/// constants in the app, UUID-namespaced in tests), so it is an unambiguous
/// separator and the composite key stays reversible by suffix match.
+ (NSString *)retryFloorKeyForPath:(NSString *)path
                  bootstrapService:(NSString *)bootstrapService {
    return [NSString stringWithFormat:@"%@\n%@", path, bootstrapService];
}

/// Drops every floor recorded against `bootstrapService`, whatever the path.
///
/// Installing or removing a bootstrap password invalidates exactly the failures
/// that password caused, and nothing else. Clearing all floors instead would
/// make the backoff untestable — parallel tests in this binary each set their
/// own override, and every set would reset every other test's window.
+ (void)clearRetryFloorsForBootstrapService:(NSString *)bootstrapService {
    NSMutableDictionary<NSString *, NSDictionary *> *failures = [self keychainFailures];
    NSString *suffix = [@"\n" stringByAppendingString:bootstrapService];
    for (NSString *key in failures.allKeys) {
        if ([key hasSuffix:suffix]) { [failures removeObjectForKey:key]; }
    }
}

+ (nullable NSString *)lastFailureStageForKeychainPath:(NSString *)path
                                      bootstrapService:(NSString *)bootstrapService {
    @synchronized (self) {
        NSString *key = [self retryFloorKeyForPath:path bootstrapService:bootstrapService];
        return [self keychainFailures][key][kAstraFailureStage];
    }
}

+ (OSStatus)lastFailureStatusForKeychainPath:(NSString *)path
                            bootstrapService:(NSString *)bootstrapService {
    @synchronized (self) {
        NSString *key = [self retryFloorKeyForPath:path bootstrapService:bootstrapService];
        NSNumber *status = [self keychainFailures][key][kAstraFailureStatus];
        return status != nil ? (OSStatus)status.intValue : errSecSuccess;
    }
}

/// Per-path count of real open attempts, for tests. Keyed by path so a suite
/// running in parallel with others still measures only its own temp keychain —
/// a process-global counter would be unassertable in this test binary.
+ (NSMutableDictionary<NSString *, NSNumber *> *)keychainOpenAttempts {
    static NSMutableDictionary *attempts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ attempts = [NSMutableDictionary dictionary]; });
    return attempts;
}

+ (NSUInteger)openAttemptCountForKeychainPath:(NSString *)path {
    @synchronized (self) {
        return [self keychainOpenAttempts][path].unsignedIntegerValue;
    }
}

/// Last failure seen, for `AstraSecureKeychainStore` to log. Nothing in this
/// file logged anything at all: every OSStatus was captured into a variable that
/// was never read, so thousands of failing lookups produced not one line in the
/// app log and the stall was invisible to everything except a process sample.
static NSString *sAstraLastFailureStage = nil;
static OSStatus sAstraLastFailureStatus = errSecSuccess;
static NSUInteger sAstraFailuresSinceLastReport = 0;

/// Records why `path` could not be opened, opens the backoff window, and returns
/// NULL so each failure site can `return [self noteKeychainUnavailable...]`.
+ (SecKeychainRef)noteKeychainUnavailableAtPath:(NSString *)path
                               bootstrapService:(NSString *)bootstrapService
                                          stage:(NSString *)stage
                                         status:(OSStatus)status
                          userInteractionAllowed:(BOOL)userInteractionAllowed {
    [self keychainFailures][[self retryFloorKeyForPath:path
                                      bootstrapService:bootstrapService]] = @{
        kAstraFailureUntil: [NSDate dateWithTimeIntervalSinceNow:kAstraKeychainUnavailableBackoff],
        kAstraFailureStage: stage,
        kAstraFailureStatus: @(status),
        kAstraFailureInteractive: @(userInteractionAllowed),
    };
    sAstraLastFailureStage = stage;
    sAstraLastFailureStatus = status;
    if (sAstraFailuresSinceLastReport < NSUIntegerMax) { sAstraFailuresSinceLastReport += 1; }
    return NULL;
}

/// Records a failure that happened *after* the keychain opened, so a drained
/// report can name it.
///
/// Deliberately does not arm a retry floor. The open succeeded and its handle is
/// cached, so suppressing the next open would punish every unrelated caller for
/// one item's ACL.
+ (void)noteKeychainWriteFailureWithStage:(NSString *)stage status:(OSStatus)status {
    @synchronized (self) {
        sAstraLastFailureStage = stage;
        sAstraLastFailureStatus = status;
        if (sAstraFailuresSinceLastReport < NSUIntegerMax) { sAstraFailuresSinceLastReport += 1; }
    }
}

+ (nullable NSString *)takeLastKeychainFailureReport {
    @synchronized (self) {
        if (sAstraLastFailureStage == nil || sAstraFailuresSinceLastReport == 0) { return nil; }
        NSString *report = [NSString stringWithFormat:@"stage=%@ status=%d suppressed=%lu",
                            sAstraLastFailureStage,
                            (int)sAstraLastFailureStatus,
                            (unsigned long)sAstraFailuresSinceLastReport];
        sAstraFailuresSinceLastReport = 0;
        return report;
    }
}

/// Returns an unlocked keychain handle for `path`, creating the file on first
/// use, or NULL on any failure (callers then fail closed).
///
/// A failure is remembered for `kAstraKeychainUnavailableBackoff` and repeated
/// immediately from memory. Note what this does *not* do: it does not invoke
/// `recoverUnreadableDedicatedKeychainAtPath:`. Recovery moves the keychain
/// aside and drops its bootstrap password, which is fine on the save path
/// (line 514) because the caller immediately repopulates what it was writing —
/// but a read has nothing to put back, so recovering here would silently
/// destroy every stored credential to satisfy a lookup. Reads fail closed and
/// stay cheap; only a write earns the right to rebuild.
+ (SecKeychainRef)dedicatedKeychainForPath:(NSString *)path
                          bootstrapService:(NSString *)bootstrapService {
    return [self dedicatedKeychainForPath:path
                         bootstrapService:bootstrapService
                   userInteractionAllowed:NO];
}

+ (SecKeychainRef)dedicatedKeychainForPath:(NSString *)path
                          bootstrapService:(NSString *)bootstrapService
                    userInteractionAllowed:(BOOL)userInteractionAllowed {
    @synchronized (self) {
        NSValue *cached = [self keychainCache][path];
        if (cached != nil) {
            return (SecKeychainRef)[cached pointerValue];
        }

        NSString *floorKey = [self retryFloorKeyForPath:path
                                       bootstrapService:bootstrapService];
        NSDictionary *floor = [self keychainFailures][floorKey];
        // The backoff answers *incidental* lookups from memory, so an unbounded
        // SwiftUI body sweep cannot redo the securityd handshake thousands of
        // times. But an interactive attempt is the only kind that runs with
        // Keychain UI enabled, so serving one from the negative cache means
        // securityd is never asked, and the "allow access?" dialog that is the
        // entire remedy for a partition-list denial can never appear. The
        // Connectors sheet re-reads every credential row on every keystroke, so
        // its floor is always fresh by the time the button is clicked. Measured
        // on 2026-08-17: 12 consecutive "Allow & Save" attempts, five of them
        // under 300 ms apart, produced no prompt, no securityd call, and not
        // one log line.
        //
        // Hence the asymmetry: a floor blocks an interactive attempt only if an
        // interactive attempt is what set it. Without that second half a click
        // would bypass the floor and *re-arm* it non-interactively, so the next
        // click bypasses it too — and a single save that writes several keys
        // (`KeychainService.save(key:value:facts:)` writes each into two
        // namespaces) would stack one modal dialog per key.
        NSDate *retryFloor = floor[kAstraFailureUntil];
        if (userInteractionAllowed && ![floor[kAstraFailureInteractive] boolValue]) {
            retryFloor = nil;
        }
        if (retryFloor != nil && [retryFloor timeIntervalSinceNow] > 0) {
            if (sAstraFailuresSinceLastReport < NSUIntegerMax) { sAstraFailuresSinceLastReport += 1; }
            return NULL;
        }
        // Clearing here rather than only on an expired floor keeps one rule:
        // past this point an open is genuinely being attempted, so the previous
        // verdict is stale either way. A failing attempt re-records it below.
        [[self keychainFailures] removeObjectForKey:floorKey];

        NSMutableDictionary<NSString *, NSNumber *> *attempts = [self keychainOpenAttempts];
        attempts[path] = @(attempts[path].unsignedIntegerValue + 1);

        const char *cPath = path.fileSystemRepresentation;
        SecKeychainRef keychain = NULL;
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];

        // Only mint a fresh bootstrap password when creating a brand-new keychain
        // file. If the file already exists but its bootstrap item is gone (e.g.
        // the user deleted it from the login keychain), generating a new password
        // here would both fail to unlock the existing keychain AND leave an
        // orphaned wrong password behind — so for an existing file we require the
        // stored password and otherwise fail closed.
        OSStatus bootstrapStatus = errSecSuccess;
        NSData *password = [self bootstrapPasswordForService:bootstrapService
                                                      create:!exists
                                                      status:&bootstrapStatus];
        if (password.length == 0) {
            // Report the real status. -25300 (item absent) and -25293/-25308
            // (item present, this binary denied by the ACL partition list) are
            // completely different problems with completely different fixes,
            // and this line is the only place the difference is visible.
            return [self noteKeychainUnavailableAtPath:path
                                      bootstrapService:bootstrapService
                                                 stage:@"bootstrap-password"
                                                status:bootstrapStatus != errSecSuccess
                                                           ? bootstrapStatus
                                                           : errSecItemNotFound
                                userInteractionAllowed:userInteractionAllowed];
        }

        if (exists) {
            OSStatus openStatus = SecKeychainOpen(cPath, &keychain);
            if (openStatus != errSecSuccess || keychain == NULL) {
                if (keychain != NULL) { CFRelease(keychain); }
                return [self noteKeychainUnavailableAtPath:path
                                          bootstrapService:bootstrapService
                                                     stage:@"open"
                                                    status:openStatus
                                    userInteractionAllowed:userInteractionAllowed];
            }
            OSStatus unlockStatus = SecKeychainUnlock(keychain,
                                                      (UInt32)password.length,
                                                      password.bytes,
                                                      true);
            if (unlockStatus != errSecSuccess) {
                CFRelease(keychain);
                return [self noteKeychainUnavailableAtPath:path
                                          bootstrapService:bootstrapService
                                                     stage:@"unlock"
                                                    status:unlockStatus
                                    userInteractionAllowed:userInteractionAllowed];
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
                return [self noteKeychainUnavailableAtPath:path
                                          bootstrapService:bootstrapService
                                                     stage:@"create"
                                                    status:createStatus
                                    userInteractionAllowed:userInteractionAllowed];
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
                return [self noteKeychainUnavailableAtPath:path
                                          bootstrapService:bootstrapService
                                                     stage:@"search-list-restore"
                                                    status:restoreStatus
                                    userInteractionAllowed:userInteractionAllowed];
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

        [[self keychainFailures] removeObjectForKey:floorKey];
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

/// Whether the keychain file at `path` is missing or structurally unusable, so
/// that moving it aside destroys nothing the user could otherwise get back.
///
/// This is the gate on `recoverUnreadableDedicatedKeychainAtPath:`, and it is a
/// gate rather than a bare call because recovery is irreversible. Recovery
/// deletes the bootstrap password and *then* renames the keychain, so what it
/// leaves behind is a file encrypted with a random password that no longer
/// exists anywhere on the machine — every secret in it is unrecoverable, not
/// quarantined. `~/Library/Keychains` holds 25 `astra.keychain-db.unreadable-*`
/// files dated 2026-06-17 to 2026-07-07, one per ad-hoc rebuild whose new cdhash
/// fell out of the bootstrap item's ACL. Nothing will ever open any of them.
///
/// Note what this asks and what it deliberately does not. The tempting version
/// gates on `lastFailureStatusForKeychainPath:bootstrapService:`, treating
/// `errSecItemNotFound` as "the keychain is gone". That is a category error
/// twice over. First, the recorded status describes the *bootstrap item in the
/// login keychain*, not this file: the password can be absent while the
/// keychain sits intact and full of credentials, which is precisely the case
/// recovery must not touch. Second, the status comes out of the backoff map,
/// written by whichever attempt last failed at whichever stage — it is a record
/// of an earlier event, not a measurement of the condition now.
///
/// So measure the file. `SecKeychainOpen` alone will not do it; it succeeds
/// lazily for a path that holds nothing, hence the existence check first and
/// `SecKeychainGetStatus` after, which is what forces securityd to actually
/// read the thing.
///
/// Fails closed: a keychain that opens and reports any status other than the
/// three "cannot make sense of this file" codes is left alone, including one
/// that is merely locked or that this binary is not authorized to unlock. A
/// denial is a permission the user grants in one dialog. It is not a reason to
/// erase their credentials.
+ (BOOL)dedicatedKeychainIsBeyondRecoveryAtPath:(NSString *)path {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return YES;
    }

    SecKeychainRef keychain = NULL;
    OSStatus openStatus = SecKeychainOpen(path.fileSystemRepresentation, &keychain);
    if (openStatus != errSecSuccess || keychain == NULL) {
        if (keychain != NULL) { CFRelease(keychain); }
        return YES;
    }

    SecKeychainStatus keychainStatus = 0;
    OSStatus status = SecKeychainGetStatus(keychain, &keychainStatus);
    CFRelease(keychain);
    return status == errSecInvalidKeychain
        || status == errSecNoSuchKeychain
        || status == errSecNotAvailable;
}

+ (BOOL)recoverUnreadableDedicatedKeychainAtPath:(NSString *)path
                                bootstrapService:(NSString *)bootstrapService {
    @synchronized (self) {
        [[self keychainCache] removeObjectForKey:path];
        // Drop the backoff too. Recovery exists precisely to clear the condition
        // that set it, and the caller reopens immediately afterwards — leaving
        // the floor in place would make recovery appear to fail for two seconds.
        [[self keychainFailures]
            removeObjectForKey:[self retryFloorKeyForPath:path
                                         bootstrapService:bootstrapService]];
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
    return [self bootstrapPasswordForService:service create:create status:NULL];
}

/// `outStatus` reports *why* a nil return happened, which the caller cannot
/// otherwise know.
///
/// Without it the failure is unattributable, and unattributable is precisely the
/// state this class was in: the read status was captured into a local and never
/// read, so `dedicatedKeychainForPath:` had to log a hardcoded
/// `errSecItemNotFound`. That constant is not merely uninformative, it is wrong
/// in the case that matters — an ACL/partition-list denial on an item that very
/// much exists returns `errSecAuthFailed` (-25293) or
/// `errSecInteractionNotAllowed` (-25308), never -25300. Reporting "no such
/// item" for a present-but-unreadable item points every diagnosis at the wrong
/// cause.
+ (NSData *)bootstrapPasswordForService:(NSString *)service
                                 create:(BOOL)create
                                 status:(OSStatus *)outStatus {
    if (outStatus != NULL) { *outStatus = errSecSuccess; }

    @synchronized (self) {
        NSData *override = [self testBootstrapPasswordOverrides][service];
        if (override != nil) { return override; }
    }

    SecKeychainRef login = NULL;
    OSStatus defaultStatus = SecKeychainCopyDefault(&login);
    if (defaultStatus != errSecSuccess || login == NULL) {
        if (login != NULL) { CFRelease(login); }
        if (outStatus != NULL) {
            *outStatus = defaultStatus != errSecSuccess ? defaultStatus : errSecNoDefaultKeychain;
        }
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
        // The read status is the whole answer here: -25300 means the item is
        // genuinely absent, while -25293/-25308 mean it is there and this
        // binary is not allowed to read it.
        if (outStatus != NULL) { *outStatus = readStatus; }
        return nil;
    }

    NSMutableData *randomBytes = [NSMutableData dataWithLength:32];
    if (SecRandomCopyBytes(kSecRandomDefault, randomBytes.length, randomBytes.mutableBytes) != errSecSuccess) {
        CFRelease(login);
        if (outStatus != NULL) { *outStatus = errSecAllocate; }
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
        return [self bootstrapPasswordForService:service create:NO status:outStatus];
    }
    if (outStatus != NULL) { *outStatus = addStatus; }
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
    // The whole toggle/write/restore span is serialized so an interleaved
    // background (disable) and user-prompted (allow) call on another thread
    // can never race on the process-wide SecKeychainSetUserInteractionAllowed
    // flag and restore the wrong value.
    @synchronized (self) {
    Boolean previousInteraction = true;
    if (allowUserInteraction) {
        [self allowKeychainUserInteractionSavingPrevious:&previousInteraction];
    } else {
        [self disableKeychainUserInteractionSavingPrevious:&previousInteraction];
    }
    @try {
    // `allowUserInteraction` is set only by `saveSecretAllowingUserInteraction:`,
    // which is reachable only from an explicit user gesture (the "Allow & Save"
    // button). That makes it the right signal for spending a securityd round
    // trip regardless of the backoff: a person clicking a button cannot produce
    // the unbounded burst the backoff was added to absorb.
    SecKeychainRef keychain = [self dedicatedKeychainForPath:keychainPath
                                           bootstrapService:bootstrapService
                                              userInteractionAllowed:allowUserInteraction];
    if (keychain == NULL) {
        if (!recoverUnreadableKeychain) {
            return NO;
        }
        // Recovery is for a keychain that is gone or broken, never for one this
        // binary is simply not on the ACL of. See
        // `dedicatedKeychainIsBeyondRecoveryAtPath:`: getting this wrong does
        // not fail a save, it destroys every credential the user has.
        if (![self dedicatedKeychainIsBeyondRecoveryAtPath:keychainPath]) {
            return NO;
        }
        if (![self recoverUnreadableDedicatedKeychainAtPath:keychainPath
                                           bootstrapService:bootstrapService]) {
            return NO;
        }
        keychain = [self dedicatedKeychainForPath:keychainPath
                                 bootstrapService:bootstrapService
                                    userInteractionAllowed:allowUserInteraction];
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
        // This is the *stored item's* ACL, not the keychain's, and it is the
        // failure a re-signed build hits once the bootstrap problem is fixed:
        // every item was written with an ACL trusting only the binary that
        // wrote it. Without a note it drains as nil and the app logs a bare
        // `keychain.save_failed`, indistinguishable from a keychain that never
        // opened at all — the two need opposite remedies.
        [self noteKeychainWriteFailureWithStage:@"item-delete" status:deleteStatus];
        return NO;
    }

    OSStatus addStatus = [self addSecretValue:data
                                   forAccount:account
                                      service:service
                                        label:label
                                     keychain:keychain];
    if (addStatus != errSecSuccess) {
        [self noteKeychainWriteFailureWithStage:@"item-add" status:addStatus];
        return NO;
    }
    return YES;
    } @finally {
        [self restoreKeychainUserInteraction:previousInteraction];
    }
    }
}

+ (nullable NSString *)secretForAccount:(NSString *)account
                                service:(NSString *)service
                           keychainPath:(NSString *)keychainPath
                       bootstrapService:(NSString *)bootstrapService {
    @synchronized (self) {
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
}

+ (BOOL)deleteSecretForAccount:(NSString *)account
                       service:(NSString *)service
                  keychainPath:(NSString *)keychainPath
              bootstrapService:(NSString *)bootstrapService {
    @synchronized (self) {
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
}

+ (BOOL)deleteAllSecretsForService:(NSString *)service
                      keychainPath:(NSString *)keychainPath
                  bootstrapService:(NSString *)bootstrapService {
    @synchronized (self) {
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
}

+ (BOOL)hasSecretForAccount:(NSString *)account
                    service:(NSString *)service
               keychainPath:(NSString *)keychainPath
           bootstrapService:(NSString *)bootstrapService {
    @synchronized (self) {
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
    @synchronized (self) {
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
}

@end

#pragma clang diagnostic pop
