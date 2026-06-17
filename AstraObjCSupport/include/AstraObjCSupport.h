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

@end

NS_ASSUME_NONNULL_END
