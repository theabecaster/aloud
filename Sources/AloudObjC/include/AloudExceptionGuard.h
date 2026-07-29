#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block, catching any Objective-C exception it raises.
/// Returns the exception, or nil when the block completed normally.
///
/// Exists because AVFAudio raises NSExceptions from Swift-visible methods
/// (installTapOnBus: with a format the device just abandoned, most
/// notably), and an uncaught ObjC exception is an uncatchable SIGABRT in
/// Swift. The one caller treats a caught exception as "capture rebuild
/// failed, try again shortly" — never as something to ignore silently.
NSException * _Nullable AloudCatchException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
