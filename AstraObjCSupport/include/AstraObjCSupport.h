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

NS_ASSUME_NONNULL_END
