#import <Foundation/Foundation.h>
#include <stddef.h>
#include <stdint.h>

/// Initializes the command bridge sandbox filesystem layout.
void macrodex_command_bridge_init(void);

/// Runs a command through the embedded iOS command bridge and captures stdout/stderr.
int macrodex_command_bridge_run(const char * _Nonnull cmd, const char * _Nullable cwd, char * _Nullable * _Nonnull output, size_t * _Nonnull output_len);

/// Returns the default working directory for local codex sessions (/home/codex inside sandbox).
/// Must be called after macrodex_command_bridge_init().
NSString * _Nullable codex_ios_default_cwd(void);

/// Requests the app's default HealthKit read/write access once per install.
void codex_healthkit_request_authorization_if_needed(void);

/// Requests the app's default HealthKit read/write access from an explicit user action.
void codex_healthkit_request_authorization_from_settings(void);

/// Returns a short user-facing HealthKit authorization summary.
NSString * _Nullable codex_healthkit_status_summary(void);

/// Best-effort sync of one Macrodex nutrition day into HealthKit dietary samples.
/// HealthKit unavailable/denied states are treated as soft skips.
void codex_healthkit_sync_nutrition_day_async(NSString * _Nullable dateKey);
