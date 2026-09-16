#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges Obj-C exception handling to Swift, which cannot catch `NSException`.
///
/// A handful of AppKit calls can *raise* rather than return an error — e.g.
/// `-[NSSplitView setHoldingPriority:forSubviewAtIndex:]`, whose internal pane
/// bookkeeping can briefly disagree with `-subviews` during a SwiftUI column
/// show/hide transition. From Swift such a raise is unrecoverable (the runtime
/// calls `terminate`). Funnel the risky call through `catching:` so a transient
/// raise becomes a recoverable no-op instead of aborting the app.
@interface AstraExceptionTrap : NSObject

/// Runs `block` inside an Obj-C `@try`/`@catch`.
/// Returns the caught `NSException`, or `nil` if `block` returned normally.
+ (nullable NSException *)catching:(NS_NOESCAPE void (^)(void))block;

@end

/// Stores ASTRA's own secrets (connector + skill credentials) in a *dedicated*
/// macOS file keychain, kept out of the user's `login.keychain-db`.
///
/// ASTRA hands the sandboxed agent read access to `login.keychain-db` so the
/// bundled `gh`/Copilot CLI can fetch the GitHub OAuth token. If ASTRA's own
/// connector secrets also lived there, a compromised task could exfiltrate the
/// whole encrypted blob for offline brute-force. Storing them in a separate
/// keychain file the sandbox never grants closes that defense-in-depth gap.
///
/// This necessarily uses the legacy file-based keychain API (`SecKeychain*` +
/// `kSecUseKeychain`/`kSecMatchSearchList`), deprecated in 10.10 in favor of the
/// data-protection keychain — which is unavailable here because it requires a
/// Team-ID-prefixed access-group entitlement this app does not have. The
/// deprecation is suppressed for the implementation; the choice is deliberate.
///
/// Every method is path-parameterized so tests can drive throwaway keychains in
/// a temp directory. The opened+unlocked keychain handle is cached per path for
/// the process lifetime. All methods fail closed (return `NO`/`nil`) rather than
/// ever falling back to `login.keychain-db`.
@interface AstraSecureKeychain : NSObject

/// Save or update `value` under (`service`, `account`) in the dedicated keychain
/// at `keychainPath`, unlocked with a random password stored in the login
/// keychain under `bootstrapService`. Returns `NO` on failure.
+ (BOOL)saveSecret:(NSString *)value
        forAccount:(NSString *)account
           service:(NSString *)service
             label:(nullable NSString *)label
      keychainPath:(NSString *)keychainPath
  bootstrapService:(NSString *)bootstrapService;

/// Save or update `value` like `saveSecret`, but leaves Security.framework
/// user interaction enabled for an explicit user action. This lets macOS ask
/// the user to allow ASTRA to read the existing bootstrap item or unlock the
/// dedicated keychain. It does not perform unreadable-keychain recovery when
/// access is denied, so a canceled prompt cannot rotate the user's keychain.
+ (BOOL)saveSecretAllowingUserInteraction:(NSString *)value
                               forAccount:(NSString *)account
                                  service:(NSString *)service
                                    label:(nullable NSString *)label
                             keychainPath:(NSString *)keychainPath
                         bootstrapService:(NSString *)bootstrapService;

/// Load the value for (`service`, `account`) from the dedicated keychain, or
/// `nil` if absent / the keychain is unavailable.
+ (nullable NSString *)secretForAccount:(NSString *)account
                                service:(NSString *)service
                           keychainPath:(NSString *)keychainPath
                       bootstrapService:(NSString *)bootstrapService;

/// Delete the item for (`service`, `account`). Returns `YES` if it was removed
/// or did not exist.
+ (BOOL)deleteSecretForAccount:(NSString *)account
                       service:(NSString *)service
                  keychainPath:(NSString *)keychainPath
              bootstrapService:(NSString *)bootstrapService;

/// Delete every item with `service` from the dedicated keychain.
+ (BOOL)deleteAllSecretsForService:(NSString *)service
                      keychainPath:(NSString *)keychainPath
                  bootstrapService:(NSString *)bootstrapService;

/// Whether an item for (`service`, `account`) exists in the dedicated keychain.
+ (BOOL)hasSecretForAccount:(NSString *)account
                    service:(NSString *)service
               keychainPath:(NSString *)keychainPath
           bootstrapService:(NSString *)bootstrapService;

/// Runs `block` with Security.framework keychain UI disabled, restoring the
/// previous setting afterwards. Intended for deterministic regression tests and
/// critical non-interactive keychain sections.
+ (void)performWithKeychainUserInteractionDisabled:(NS_NOESCAPE void (^)(void))block;

/// Test-only bootstrap override used when the SwiftPM test host cannot create
/// or read items in the user's login keychain without opening macOS UI.
+ (void)setTestBootstrapPassword:(NSString *)password
             forBootstrapService:(NSString *)bootstrapService;

/// Clears a test-only bootstrap password override.
+ (void)clearTestBootstrapPasswordForBootstrapService:(NSString *)bootstrapService;

/// Move every generic-password item whose service is `service` from the login
/// (default) keychain into the dedicated keychain, deleting each from login once
/// it is safely copied. Enumerates by service so it catches every account
/// (credential keys, OAuth tokens, …) without knowing the key names. Returns the
/// number of items moved, or `-1` on a hard failure. Idempotent.
+ (NSInteger)migrateServiceFromLoginKeychain:(NSString *)service
                                keychainPath:(NSString *)keychainPath
                            bootstrapService:(NSString *)bootstrapService;

/// Read-only probe of the login (default) keychain. With `account` nil, reports
/// whether ANY item with `service` exists. Used by tests asserting that ASTRA
/// secrets are not left behind in `login.keychain-db`.
+ (BOOL)loginKeychainContainsService:(NSString *)service
                             account:(nullable NSString *)account;

/// Consumes the pending description of why the dedicated keychain could not be
/// opened — `stage=<what failed> status=<OSStatus> suppressed=<attempts>` — or
/// `nil` if nothing has failed since the last call.
///
/// This class deliberately does no logging of its own (it handles secrets, and
/// an `os_log` here is one careless `%@` away from printing one). It instead
/// hands the failure to `AstraSecureKeychainStore`, which logs through the
/// app's redacting logger. Without this, a keychain the app cannot read is
/// completely invisible: every lookup returns `nil`, callers treat that as
/// "not configured", and the app log stays silent while thousands of reads
/// fail. `suppressed` counts attempts collapsed by the retry backoff, so a
/// single line still conveys how hard the app was hammering.
///
/// Consuming rather than peeking keeps the caller from re-logging one failure
/// on every poll.
+ (nullable NSString *)takeLastKeychainFailureReport;

/// Test-only: how many times the keychain at `path` has actually been opened,
/// as opposed to answered from the handle cache or skipped by the failure
/// backoff. Lets a test assert that a burst of failing lookups costs one
/// securityd round trip rather than one per lookup, without timing anything.
+ (NSUInteger)openAttemptCountForKeychainPath:(NSString *)path;

/// Test-only: the stage at which the last open of (`path`, `bootstrapService`)
/// failed, or `nil` if it is not currently in a backoff window.
///
/// Scoped to one keychain, unlike `takeLastKeychainFailureReport`, which is
/// deliberately process-global because the app wants a single log line. Several
/// suites in this binary drive keychains in parallel, so only a keyed lookup can
/// assert *which* stage failed without pinning the scheduler.
+ (nullable NSString *)lastFailureStageForKeychainPath:(NSString *)path
                                      bootstrapService:(NSString *)bootstrapService;

/// Test-only: the `OSStatus` behind that stage, or `errSecSuccess` if the
/// keychain is not currently in a backoff window.
///
/// This must be a *measured* status, never a placeholder. The distinction it
/// carries is the whole diagnosis: `errSecItemNotFound` (-25300) means the
/// bootstrap item is absent and the keychain needs re-provisioning, while
/// `errSecAuthFailed` (-25293) / `errSecInteractionNotAllowed` (-25308) mean the
/// item is present and *this binary* is not in its ACL partition list — which is
/// what an ad-hoc rebuild does every time its cdhash changes.
+ (OSStatus)lastFailureStatusForKeychainPath:(NSString *)path
                            bootstrapService:(NSString *)bootstrapService;

/// Test-only: whether the keychain file at `path` is missing or structurally
/// unusable, which is the sole condition under which the save path may rebuild
/// it from scratch.
///
/// Exposed because the negative answer is the load-bearing one. Recovery drops
/// the bootstrap password and moves the keychain aside, leaving a file no key
/// can open; gating it on a probe of the file itself is what keeps a
/// partition-list denial — a permission the user grants in one dialog — from
/// erasing every stored credential instead. Note the polarity: `YES` permits
/// destruction.
+ (BOOL)dedicatedKeychainIsBeyondRecoveryAtPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
