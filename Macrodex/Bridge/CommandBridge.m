#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <spawn.h>
#include <sys/wait.h>
#include <TargetConditionals.h>
#include <Foundation/Foundation.h>
#include <HealthKit/HealthKit.h>
#include <JavaScriptCore/JavaScriptCore.h>
#include <sqlite3.h>

extern char **environ;

NSString *codex_ios_default_cwd(void);

/// Returns the sandbox root (~/Documents), creating a Unix-like directory layout inside it.
static NSString *codex_sandbox_root(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!docs) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *dirs = @[
        @"home/codex",
        @"tmp",
        @"var/log",
        @"etc",
    ];
    for (NSString *dir in dirs) {
        NSString *path = [docs stringByAppendingPathComponent:dir];
        if (![fm fileExistsAtPath:path]) {
            [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }

    return docs;
}

static NSString *codex_ios_decode_wrapped_shell_argument(NSString *value) {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length < 2) {
        return nil;
    }

    if ([trimmed hasPrefix:@"'"] && [trimmed hasSuffix:@"'"]) {
        NSString *placeholder = @"__CODEX_SQUOTE__";
        NSString *decoded = [trimmed stringByReplacingOccurrencesOfString:@"'\\''" withString:placeholder];
        decoded = [decoded stringByReplacingOccurrencesOfString:@"'" withString:@""];
        decoded = [decoded stringByReplacingOccurrencesOfString:placeholder withString:@"'"];
        return decoded;
    }

    if ([trimmed hasPrefix:@"\""] && [trimmed hasSuffix:@"\""]) {
        NSString *decoded = [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
        decoded = [decoded stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
        decoded = [decoded stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
        return decoded;
    }

    return nil;
}

static NSString *codex_ios_normalize_shell_command(const char *cmd) {
    NSString *command = cmd ? [NSString stringWithUTF8String:cmd] : @"";
    if (command.length == 0) {
        return command;
    }

    NSArray<NSString *> *prefixes = @[
        @"/bin/bash -lc ",
        @"/bin/bash -c ",
        @"/bin/zsh -lc ",
        @"/bin/zsh -c ",
        @"/bin/sh -lc ",
        @"bash -lc ",
        @"bash -c ",
        @"zsh -lc ",
        @"zsh -c ",
        @"sh -lc ",
    ];
    BOOL changed = YES;
    while (changed) {
        changed = NO;

        for (NSString *prefix in prefixes) {
            if ([command hasPrefix:prefix]) {
                NSString *body = [command substringFromIndex:prefix.length];
                NSString *decoded = codex_ios_decode_wrapped_shell_argument(body);
                if (decoded.length > 0) {
                    command = decoded;
                } else {
                    command = [@"sh -c " stringByAppendingString:body];
                }
                changed = YES;
                break;
            }
        }
        if (changed) {
            continue;
        }

        if ([command hasPrefix:@"sh -c "]) {
            NSString *body = [command substringFromIndex:6];
            NSString *decoded = codex_ios_decode_wrapped_shell_argument(body);
            if (decoded.length > 0) {
                command = decoded;
                changed = YES;
                continue;
            }
        }

        if ([command isEqualToString:@"/bin/bash"]
            || [command isEqualToString:@"/bin/zsh"]
            || [command isEqualToString:@"/bin/sh"]
            || [command isEqualToString:@"bash"]
            || [command isEqualToString:@"zsh"]) {
            command = @"sh";
            changed = YES;
        }
    }

    return [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *codex_ios_host_shell_script(NSString *command) {
    NSString *trimmed = [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@"sh -c "]) {
        NSString *body = [trimmed substringFromIndex:6];
        NSString *decoded = codex_ios_decode_wrapped_shell_argument(body);
        if (decoded.length > 0) {
            return decoded;
        }
    }
    return trimmed;
}

static NSString *codex_ios_date_format_string(const char *value) {
    if (value == NULL) {
        return nil;
    }
    NSString *string = [NSString stringWithUTF8String:value];
    if (![string hasPrefix:@"+"]) {
        return nil;
    }
    return [string substringFromIndex:1];
}

static NSString *codex_ios_render_date_format(NSString *format, BOOL utc) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    time_t now = ts.tv_sec;
    struct tm tmValue;
    if (utc) {
        gmtime_r(&now, &tmValue);
    } else {
        localtime_r(&now, &tmValue);
    }

    NSString *placeholderSeconds = @"__CODEX_SECONDS__";
    NSString *placeholderMillis = @"__CODEX_MILLIS__";
    NSString *placeholderNanos = @"__CODEX_NANOS__";

    NSString *prepared = [[format stringByReplacingOccurrencesOfString:@"%3N" withString:placeholderMillis]
        stringByReplacingOccurrencesOfString:@"%N" withString:placeholderNanos];
    prepared = [prepared stringByReplacingOccurrencesOfString:@"%s" withString:placeholderSeconds];

    char buffer[1024];
    size_t count = strftime(buffer, sizeof(buffer), prepared.UTF8String, &tmValue);
    NSString *result = count > 0 ? [NSString stringWithUTF8String:buffer] : prepared;
    result = [result stringByReplacingOccurrencesOfString:placeholderSeconds withString:[NSString stringWithFormat:@"%lld", (long long)now]];
    result = [result stringByReplacingOccurrencesOfString:placeholderMillis withString:[NSString stringWithFormat:@"%03ld", ts.tv_nsec / 1000000L]];
    result = [result stringByReplacingOccurrencesOfString:placeholderNanos withString:[NSString stringWithFormat:@"%09ld", ts.tv_nsec]];
    return result;
}

int true_main(int argc, char *argv[]) {
    return 0;
}

int false_main(int argc, char *argv[]) {
    return 1;
}

int uuidgen_main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *uuid = [[[NSUUID UUID] UUIDString] lowercaseString];
        fprintf(stdout, "%s\n", uuid.UTF8String);
    }
    return 0;
}

int date_main(int argc, char *argv[]) {
    @autoreleasepool {
        BOOL utc = NO;
        NSString *format = nil;

        for (int index = 1; index < argc; index++) {
            const char *arg = argv[index];
            if (strcmp(arg, "-u") == 0) {
                utc = YES;
                continue;
            }
            NSString *candidate = codex_ios_date_format_string(arg);
            if (candidate != nil) {
                format = candidate;
                continue;
            }
            fprintf(stderr, "date: unsupported argument: %s\n", arg);
            return 1;
        }

        if (format == nil) {
            format = @"%a %b %e %H:%M:%S %Z %Y";
        }

        NSString *rendered = codex_ios_render_date_format(format, utc);
        fprintf(stdout, "%s\n", rendered.UTF8String);
    }
    return 0;
}

static void codex_ios_set_output(NSString *text, char **output, size_t *output_len) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) {
        return;
    }

    char *buf = malloc(data.length + 1);
    if (buf == NULL) {
        return;
    }
    memcpy(buf, data.bytes, data.length);
    buf[data.length] = '\0';
    *output = buf;
    *output_len = data.length;
}

static NSString *codex_macrodex_database_path(void) {
    NSString *root = codex_sandbox_root();
    if (!root) return nil;
    return [[root stringByAppendingPathComponent:@"home/codex"] stringByAppendingPathComponent:@"db.sqlite"];
}

static NSString *codex_ios_virtual_path(NSString *path) {
    NSString *root = codex_sandbox_root();
    if (root.length > 0 && [path hasPrefix:root]) {
        NSString *relative = [path substringFromIndex:root.length];
        return relative.length > 0 ? relative : @"/";
    }
    return path;
}

static NSString *codex_ios_resolve_workspace_path(NSString *path, NSString *cwd) {
    if (path.length == 0) {
        return cwd.length > 0 ? cwd : codex_ios_default_cwd();
    }

    NSString *expanded = [path stringByExpandingTildeInPath];
    NSString *root = codex_sandbox_root();
    if (root.length > 0 && [expanded hasPrefix:root]) {
        return [expanded stringByStandardizingPath];
    }

    if ([expanded hasPrefix:@"/home/"]
        || [expanded isEqualToString:@"/tmp"]
        || [expanded hasPrefix:@"/tmp/"]
        || [expanded isEqualToString:@"/var"]
        || [expanded hasPrefix:@"/var/"]
        || [expanded isEqualToString:@"/etc"]
        || [expanded hasPrefix:@"/etc/"]) {
        NSString *relative = [expanded substringFromIndex:1];
        return [[root stringByAppendingPathComponent:relative] stringByStandardizingPath];
    }

    if ([expanded hasPrefix:@"/"]) {
        return [expanded stringByStandardizingPath];
    }

    NSString *base = cwd.length > 0 ? cwd : codex_ios_default_cwd();
    return [[base stringByAppendingPathComponent:expanded] stringByStandardizingPath];
}

static NSString *codex_macrodex_sql_from_command(NSString *command) {
    NSString *trimmed = [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL isSQLCommand = [trimmed isEqualToString:@"sql"] || [trimmed hasPrefix:@"sql "];
    BOOL isLegacySQLCommand = [trimmed isEqualToString:@"macrodex-sql"] || [trimmed hasPrefix:@"macrodex-sql "];
    if (!isSQLCommand && !isLegacySQLCommand) {
        return nil;
    }

    NSString *argument = @"";
    if (isSQLCommand && trimmed.length > @"sql".length) {
        argument = [[trimmed substringFromIndex:@"sql".length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } else if (isLegacySQLCommand && trimmed.length > @"macrodex-sql".length) {
        argument = [[trimmed substringFromIndex:@"macrodex-sql".length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    if ([argument hasPrefix:@"--json "]) {
        argument = [[argument substringFromIndex:@"--json".length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    NSString *decoded = codex_ios_decode_wrapped_shell_argument(argument);
    return decoded ?: argument;
}

static BOOL codex_macrodex_sql_is_query(NSString *sql) {
    NSString *lower = [[sql stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    return [lower hasPrefix:@"select"] || [lower hasPrefix:@"with"] || [lower hasPrefix:@"pragma"];
}

static NSError *codex_macrodex_error(NSString *message) {
    return [NSError errorWithDomain:@"com.dj.Macrodex.CodexRuntime" code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
}

static void codex_macrodex_configure_database(sqlite3 *db) {
    if (db == NULL) return;
    sqlite3_busy_timeout(db, 5000);
    sqlite3_exec(db, "PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000", NULL, NULL, NULL);
}

static id codex_macrodex_sql_column_value(sqlite3_stmt *statement, int column) {
    switch (sqlite3_column_type(statement, column)) {
        case SQLITE_INTEGER:
            return @(sqlite3_column_int64(statement, column));
        case SQLITE_FLOAT:
            return @(sqlite3_column_double(statement, column));
        case SQLITE_TEXT: {
            const unsigned char *text = sqlite3_column_text(statement, column);
            return text ? [NSString stringWithUTF8String:(const char *)text] : [NSNull null];
        }
        case SQLITE_NULL:
            return [NSNull null];
        case SQLITE_BLOB: {
            int bytes = sqlite3_column_bytes(statement, column);
            return [NSString stringWithFormat:@"<blob:%d bytes>", bytes];
        }
        default:
            return [NSNull null];
    }
}

static id codex_macrodex_sql_perform(NSString *sql, NSError **error) {
    NSString *trimmed = [sql stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        if (error) *error = codex_macrodex_error(@"SQL is empty");
        return nil;
    }

    sqlite3 *db = NULL;
    NSString *path = codex_macrodex_database_path();
    if (path.length == 0 || sqlite3_open(path.UTF8String, &db) != SQLITE_OK) {
        NSString *message = db ? [NSString stringWithUTF8String:sqlite3_errmsg(db)] : @"failed to resolve db path";
        if (db) sqlite3_close(db);
        if (error) *error = codex_macrodex_error([NSString stringWithFormat:@"SQLite open error: %@", message]);
        return nil;
    }

    codex_macrodex_configure_database(db);

    if (!codex_macrodex_sql_is_query(trimmed)) {
        char *sqliteError = NULL;
        int rc = sqlite3_exec(db, trimmed.UTF8String, NULL, NULL, &sqliteError);
        if (rc != SQLITE_OK) {
            NSString *message = sqliteError ? [NSString stringWithUTF8String:sqliteError] : [NSString stringWithUTF8String:sqlite3_errmsg(db)];
            if (sqliteError) sqlite3_free(sqliteError);
            sqlite3_close(db);
            if (error) *error = codex_macrodex_error([NSString stringWithFormat:@"SQLite exec error: %@", message]);
            return nil;
        }
        int changes = sqlite3_changes(db);
        sqlite3_close(db);
        return @{@"ok": @YES, @"changes": @(changes)};
    }

    sqlite3_stmt *statement = NULL;
    int rc = sqlite3_prepare_v2(db, trimmed.UTF8String, -1, &statement, NULL);
    if (rc != SQLITE_OK) {
        NSString *message = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
        sqlite3_close(db);
        if (error) *error = codex_macrodex_error([NSString stringWithFormat:@"SQLite prepare error: %@", message]);
        return nil;
    }

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    int columnCount = sqlite3_column_count(statement);
    while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
        NSMutableDictionary *row = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)columnCount];
        for (int column = 0; column < columnCount; column++) {
            const char *name = sqlite3_column_name(statement, column);
            NSString *key = name ? [NSString stringWithUTF8String:name] : [NSString stringWithFormat:@"column_%d", column];
            row[key] = codex_macrodex_sql_column_value(statement, column);
        }
        [rows addObject:row];
    }

    if (rc != SQLITE_DONE) {
        NSString *message = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
        sqlite3_finalize(statement);
        sqlite3_close(db);
        if (error) *error = codex_macrodex_error([NSString stringWithFormat:@"SQLite step error: %@", message]);
        return nil;
    }

    sqlite3_finalize(statement);
    sqlite3_close(db);
    return rows;
}

static int codex_macrodex_sql_run(NSString *sql, char **output, size_t *output_len) {
    NSString *trimmed = [sql stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0 || [trimmed isEqualToString:@"--help"] || [trimmed isEqualToString:@"help"]) {
        codex_ios_set_output(
            @"Usage: sql \"SQL\"\n"
             @"Runs SQL against /home/codex/db.sqlite and prints JSON rows for SELECT/WITH/PRAGMA.\n",
            output,
            output_len
        );
        return trimmed.length == 0 ? 2 : 0;
    }

    sqlite3 *db = NULL;
    NSString *path = codex_macrodex_database_path();
    if (path.length == 0 || sqlite3_open(path.UTF8String, &db) != SQLITE_OK) {
        NSString *message = db ? [NSString stringWithUTF8String:sqlite3_errmsg(db)] : @"failed to resolve db path";
        if (db) sqlite3_close(db);
        codex_ios_set_output([NSString stringWithFormat:@"SQLite open error: %@\n", message], output, output_len);
        return 1;
    }

    codex_macrodex_configure_database(db);

    if (!codex_macrodex_sql_is_query(trimmed)) {
        char *error = NULL;
        int rc = sqlite3_exec(db, trimmed.UTF8String, NULL, NULL, &error);
        if (rc != SQLITE_OK) {
            NSString *message = error ? [NSString stringWithUTF8String:error] : [NSString stringWithUTF8String:sqlite3_errmsg(db)];
            if (error) sqlite3_free(error);
            sqlite3_close(db);
            codex_ios_set_output([NSString stringWithFormat:@"SQLite exec error: %@\n", message], output, output_len);
            return 1;
        }
        int changes = sqlite3_changes(db);
        sqlite3_close(db);
        codex_ios_set_output([NSString stringWithFormat:@"{\"ok\":true,\"changes\":%d}\n", changes], output, output_len);
        return 0;
    }

    sqlite3_stmt *statement = NULL;
    int rc = sqlite3_prepare_v2(db, trimmed.UTF8String, -1, &statement, NULL);
    if (rc != SQLITE_OK) {
        NSString *message = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
        sqlite3_close(db);
        codex_ios_set_output([NSString stringWithFormat:@"SQLite prepare error: %@\n", message], output, output_len);
        return 1;
    }

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    int columnCount = sqlite3_column_count(statement);
    while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
        NSMutableDictionary *row = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)columnCount];
        for (int column = 0; column < columnCount; column++) {
            const char *name = sqlite3_column_name(statement, column);
            NSString *key = name ? [NSString stringWithUTF8String:name] : [NSString stringWithFormat:@"column_%d", column];
            row[key] = codex_macrodex_sql_column_value(statement, column);
        }
        [rows addObject:row];
    }

    if (rc != SQLITE_DONE) {
        NSString *message = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
        sqlite3_finalize(statement);
        sqlite3_close(db);
        codex_ios_set_output([NSString stringWithFormat:@"SQLite step error: %@\n", message], output, output_len);
        return 1;
    }

    sqlite3_finalize(statement);
    sqlite3_close(db);

    NSError *jsonError = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:&jsonError];
    if (jsonError != nil || json == nil) {
        codex_ios_set_output([NSString stringWithFormat:@"JSON error: %@\n", jsonError.localizedDescription ?: @"unknown"], output, output_len);
        return 1;
    }
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] ?: @"[]";
    codex_ios_set_output([text stringByAppendingString:@"\n"], output, output_len);
    return 0;
}

static NSString *codex_macrodex_jsc_stringify_value(id value) {
    if (value == nil || value == (id)kCFNull) {
        return @"null";
    }
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value description];
    }
    if ([NSJSONSerialization isValidJSONObject:value]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        if (data.length > 0) {
            return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: [value description];
        }
    }
    return [value description];
}

static void codex_macrodex_jsc_emit(NSMutableString *output, NSString *text) {
    if (output != nil) {
        [output appendString:text ?: @""];
        return;
    }
    fputs((text ?: @"").UTF8String, stdout);
}

static void codex_macrodex_jsc_throw(JSContext *context, NSString *message) {
    context.exception = [JSValue valueWithNewErrorFromMessage:message ?: @"JavaScriptCore runtime error" inContext:context];
}

static int codex_macrodex_jsc_run_args(NSArray<NSString *> *args, NSString *cwd, NSMutableString *output) {
    @autoreleasepool {
        NSString *script = nil;
        NSString *scriptPath = nil;
        NSMutableArray<NSString *> *scriptArgs = [NSMutableArray array];

        if (args.count > 0) {
            NSString *arg = args[0];
            if ([arg isEqualToString:@"--help"] || [arg isEqualToString:@"-h"]) {
                codex_macrodex_jsc_emit(output,
                    @"Usage: jsc -e \"JS\" | jsc script.js [args...]\n"
                     @"Globals: console, fs, sql, db, cwd, argv, scriptArgs, scriptPath.\n");
                return 0;
            }
            if ([arg isEqualToString:@"-e"]) {
                if (args.count < 2) {
                    codex_macrodex_jsc_emit(output, @"jsc: -e requires JavaScript source\n");
                    return 2;
                }
                script = args[1];
                if (args.count > 2) {
                    [scriptArgs addObjectsFromArray:[args subarrayWithRange:NSMakeRange(2, args.count - 2)]];
                }
            } else {
                scriptPath = codex_ios_resolve_workspace_path(arg, cwd);
                if (args.count > 1) {
                    [scriptArgs addObjectsFromArray:[args subarrayWithRange:NSMakeRange(1, args.count - 1)]];
                }
                NSError *readError = nil;
                script = [NSString stringWithContentsOfFile:scriptPath encoding:NSUTF8StringEncoding error:&readError];
                if (script == nil) {
                    codex_macrodex_jsc_emit(output, [NSString stringWithFormat:@"jsc: %@\n", readError.localizedDescription ?: @"failed to read script"]);
                    return 1;
                }
            }
        }

        if (script == nil) {
            codex_macrodex_jsc_emit(output,
                @"Usage: jsc -e \"JS\" | jsc script.js [args...]\n"
                 @"Try: jsc -e \"console.log(sql.query('select 1 as ok'))\"\n");
            return 2;
        }

        __block JSContext *context = [[JSContext alloc] init];
        context.exceptionHandler = ^(JSContext *ctx, JSValue *exception) {
            ctx.exception = exception;
        };

        context[@"cwd"] = codex_ios_virtual_path(cwd.length > 0 ? cwd : codex_ios_default_cwd());
        context[@"argv"] = args;
        context[@"scriptArgs"] = scriptArgs;
        context[@"scriptPath"] = scriptPath != nil ? codex_ios_virtual_path(scriptPath) : [NSNull null];

        context[@"__nativeLog"] = ^(NSString *level, JSValue *values) {
            NSArray *items = [[values toArray] copy] ?: @[];
            NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:items.count];
            for (id item in items) {
                [parts addObject:codex_macrodex_jsc_stringify_value(item)];
            }
            codex_macrodex_jsc_emit(output, [[parts componentsJoinedByString:@" "] stringByAppendingString:@"\n"]);
        };

        JSValue *fs = [JSValue valueWithNewObjectInContext:context];
        fs[@"readText"] = ^NSString *(NSString *path) {
            NSError *error = nil;
            NSString *resolved = codex_ios_resolve_workspace_path(path, cwd);
            NSString *text = [NSString stringWithContentsOfFile:resolved encoding:NSUTF8StringEncoding error:&error];
            if (text == nil) {
                codex_macrodex_jsc_throw(context, error.localizedDescription);
            }
            return text;
        };
        fs[@"writeText"] = ^NSNumber *(NSString *path, NSString *text) {
            NSError *error = nil;
            NSString *resolved = codex_ios_resolve_workspace_path(path, cwd);
            NSString *parent = [resolved stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
            BOOL ok = [text writeToFile:resolved atomically:YES encoding:NSUTF8StringEncoding error:&error];
            if (!ok) {
                codex_macrodex_jsc_throw(context, error.localizedDescription);
            }
            return @(ok);
        };
        fs[@"appendText"] = ^NSNumber *(NSString *path, NSString *text) {
            NSString *resolved = codex_ios_resolve_workspace_path(path, cwd);
            NSString *parent = [resolved stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:resolved];
            if (handle == nil) {
                [[NSFileManager defaultManager] createFileAtPath:resolved contents:nil attributes:nil];
                handle = [NSFileHandle fileHandleForWritingAtPath:resolved];
            }
            if (handle == nil) {
                codex_macrodex_jsc_throw(context, [NSString stringWithFormat:@"Unable to open %@ for append", path]);
                return @NO;
            }
            [handle seekToEndOfFile];
            [handle writeData:[(text ?: @"") dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
            return @YES;
        };
        fs[@"exists"] = ^NSNumber *(NSString *path) {
            NSString *resolved = codex_ios_resolve_workspace_path(path, cwd);
            return @([[NSFileManager defaultManager] fileExistsAtPath:resolved]);
        };
        fs[@"mkdir"] = ^NSNumber *(NSString *path) {
            NSError *error = nil;
            NSString *resolved = codex_ios_resolve_workspace_path(path, cwd);
            BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:resolved withIntermediateDirectories:YES attributes:nil error:&error];
            if (!ok) {
                codex_macrodex_jsc_throw(context, error.localizedDescription);
            }
            return @(ok);
        };
        fs[@"list"] = ^id(NSString *path) {
            NSError *error = nil;
            NSString *resolved = codex_ios_resolve_workspace_path(path ?: @".", cwd);
            NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:resolved error:&error];
            if (items == nil) {
                codex_macrodex_jsc_throw(context, error.localizedDescription);
                return nil;
            }
            return items;
        };
        fs[@"remove"] = ^NSNumber *(NSString *path) {
            NSError *error = nil;
            NSString *resolved = codex_ios_resolve_workspace_path(path, cwd);
            BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:resolved error:&error];
            if (!ok) {
                codex_macrodex_jsc_throw(context, error.localizedDescription);
            }
            return @(ok);
        };
        fs[@"move"] = ^NSNumber *(NSString *fromPath, NSString *toPath) {
            NSError *error = nil;
            NSString *from = codex_ios_resolve_workspace_path(fromPath, cwd);
            NSString *to = codex_ios_resolve_workspace_path(toPath, cwd);
            NSString *parent = [to stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
            BOOL ok = [[NSFileManager defaultManager] moveItemAtPath:from toPath:to error:&error];
            if (!ok) {
                codex_macrodex_jsc_throw(context, error.localizedDescription);
            }
            return @(ok);
        };
        fs[@"stat"] = ^id(NSString *path) {
            NSError *error = nil;
            NSString *resolved = codex_ios_resolve_workspace_path(path, cwd);
            NSDictionary<NSFileAttributeKey, id> *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:resolved error:&error];
            if (attrs == nil) {
                codex_macrodex_jsc_throw(context, error.localizedDescription);
                return nil;
            }
            return @{
                @"path": codex_ios_virtual_path(resolved),
                @"size": attrs[NSFileSize] ?: @0,
                @"type": attrs[NSFileType] ?: @"unknown",
                @"modifiedAtMs": @((long long)([(NSDate *)attrs[NSFileModificationDate] timeIntervalSince1970] * 1000.0)),
            };
        };
        context[@"fs"] = fs;

        JSValue *database = [JSValue valueWithNewObjectInContext:context];
        database[@"query"] = ^id(NSString *statement) {
            NSError *error = nil;
            id result = codex_macrodex_sql_perform(statement ?: @"", &error);
            if (result == nil) {
                codex_macrodex_jsc_throw(context, error.localizedDescription);
            }
            return result;
        };
        database[@"exec"] = ^id(NSString *statement) {
            NSError *error = nil;
            id result = codex_macrodex_sql_perform(statement ?: @"", &error);
            if (result == nil) {
                codex_macrodex_jsc_throw(context, error.localizedDescription);
            }
            return result;
        };
        database[@"path"] = codex_ios_virtual_path(codex_macrodex_database_path());
        context[@"sql"] = database;
        context[@"db"] = database;

        [context evaluateScript:
            @"var console = {"
             "log: function(){ __nativeLog('log', Array.prototype.slice.call(arguments)); },"
             "warn: function(){ __nativeLog('warn', Array.prototype.slice.call(arguments)); },"
             "error: function(){ __nativeLog('error', Array.prototype.slice.call(arguments)); }"
             "};"
        ];

        JSValue *result = [context evaluateScript:script withSourceURL:[NSURL fileURLWithPath:scriptPath ?: @"jsc-eval.js"]];
        if (context.exception != nil) {
            JSValue *exception = context.exception;
            NSString *message = [exception toString] ?: @"JavaScript exception";
            JSValue *stack = exception[@"stack"];
            if (![stack isUndefined] && ![stack isNull] && [stack toString].length > 0) {
                message = [message stringByAppendingFormat:@"\n%@", [stack toString]];
            }
            codex_macrodex_jsc_emit(output, [message stringByAppendingString:@"\n"]);
            return 1;
        }
        (void)result;
        return 0;
    }
}

static NSArray<NSString *> *codex_ios_split_shell_words(NSString *command, NSError **error) {
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    BOOL inSingleQuote = NO;
    BOOL inDoubleQuote = NO;
    BOOL escaping = NO;

    for (NSUInteger index = 0; index < command.length; index++) {
        unichar ch = [command characterAtIndex:index];
        if (escaping) {
            [current appendFormat:@"%C", ch];
            escaping = NO;
            continue;
        }
        if (ch == '\\' && !inSingleQuote) {
            escaping = YES;
            continue;
        }
        if (ch == '\'' && !inDoubleQuote) {
            inSingleQuote = !inSingleQuote;
            continue;
        }
        if (ch == '"' && !inSingleQuote) {
            inDoubleQuote = !inDoubleQuote;
            continue;
        }
        if (!inSingleQuote && !inDoubleQuote && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:ch]) {
            if (current.length > 0) {
                [words addObject:[current copy]];
                [current setString:@""];
            }
            continue;
        }
        [current appendFormat:@"%C", ch];
    }

    if (escaping) {
        [current appendString:@"\\"];
    }
    if (inSingleQuote || inDoubleQuote) {
        if (error) *error = codex_macrodex_error(@"unterminated quote");
        return nil;
    }
    if (current.length > 0) {
        [words addObject:[current copy]];
    }
    return words;
}

static BOOL codex_ios_command_starts_with_token(NSString *command, NSArray<NSString *> *tokens) {
    NSString *trimmed = [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return NO;
    }
    for (NSString *token in tokens) {
        if ([trimmed isEqualToString:token]) {
            return YES;
        }
        if ([trimmed hasPrefix:token] && trimmed.length > token.length) {
            unichar next = [trimmed characterAtIndex:token.length];
            if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:next]) {
                return YES;
            }
        }
    }
    return NO;
}

static NSString *codex_ios_unwrap_shell_command_for_builtin_lookup(NSString *command) {
    NSString *candidate = [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray<NSString *> *prefixes = @[
        @"/bin/bash -lc ",
        @"/bin/bash -c ",
        @"/bin/zsh -lc ",
        @"/bin/zsh -c ",
        @"/bin/sh -lc ",
        @"/bin/sh -c ",
        @"bash -lc ",
        @"bash -c ",
        @"zsh -lc ",
        @"zsh -c ",
        @"sh -lc ",
        @"sh -c ",
    ];

    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (NSString *prefix in prefixes) {
            if (![candidate hasPrefix:prefix]) {
                continue;
            }

            NSString *body = [[candidate substringFromIndex:prefix.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *decoded = codex_ios_decode_wrapped_shell_argument(body);
            candidate = [(decoded.length > 0 ? decoded : body) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            changed = YES;
            break;
        }
    }

    return candidate;
}

static int codex_ios_run_embedded_builtin_if_needed(NSString *command, char **output, size_t *output_len, BOOL *handled) {
    if (handled != NULL) {
        *handled = NO;
    }

    NSString *lookup = codex_ios_unwrap_shell_command_for_builtin_lookup(command);
    NSError *parseError = nil;
    NSArray<NSString *> *words = codex_ios_split_shell_words(lookup, &parseError);
    if (parseError != nil || words.count == 0) {
        return 0;
    }

    NSString *name = [[words.firstObject lastPathComponent] lowercaseString];
    if (![name isEqualToString:@"date"]
        && ![name isEqualToString:@"uuidgen"]
        && ![name isEqualToString:@"true"]
        && ![name isEqualToString:@"false"]) {
        return 0;
    }

    if (handled != NULL) {
        *handled = YES;
    }

    if ([name isEqualToString:@"true"]) {
        return 0;
    }
    if ([name isEqualToString:@"false"]) {
        return 1;
    }
    if ([name isEqualToString:@"uuidgen"]) {
        NSString *uuid = [[[NSUUID UUID] UUIDString] stringByAppendingString:@"\n"];
        codex_ios_set_output(uuid, output, output_len);
        return 0;
    }

    BOOL utc = NO;
    NSString *format = nil;
    for (NSUInteger index = 1; index < words.count; index++) {
        NSString *arg = words[index];
        if ([arg isEqualToString:@"-u"]) {
            utc = YES;
            continue;
        }
        NSString *candidate = codex_ios_date_format_string(arg.UTF8String);
        if (candidate != nil) {
            format = candidate;
            continue;
        }
        codex_ios_set_output([NSString stringWithFormat:@"date: unsupported argument: %@\n", arg], output, output_len);
        return 1;
    }

    if (format == nil) {
        format = @"%a %b %e %H:%M:%S %Z %Y";
    }
    codex_ios_set_output([codex_ios_render_date_format(format, utc) stringByAppendingString:@"\n"], output, output_len);
    return 0;
}

static NSArray<NSString *> *codex_macrodex_jsc_args_from_command(NSString *command, NSError **error) {
    if (!codex_ios_command_starts_with_token(command, @[@"jsc", @"macrodex-jsc"])) {
        return nil;
    }
    NSArray<NSString *> *words = codex_ios_split_shell_words(command, error);
    if (words.count == 0) {
        return nil;
    }
    NSString *name = words.firstObject;
    if (![name isEqualToString:@"jsc"] && ![name isEqualToString:@"macrodex-jsc"]) {
        return nil;
    }
    if (words.count == 1) {
        return @[];
    }
    return [words subarrayWithRange:NSMakeRange(1, words.count - 1)];
}

static NSString *const CodexHealthKitPromptedKey = @"macrodex.healthkit.authorizationPrompted";

static HKHealthStore *codex_healthkit_store(void) {
    if (![HKHealthStore isHealthDataAvailable]) {
        return nil;
    }
    static HKHealthStore *store = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[HKHealthStore alloc] init];
    });
    return store;
}

static NSArray<NSDictionary<NSString *, id> *> *codex_healthkit_quantity_catalog(void) {
    return @[
        @{@"name": @"stepCount", @"identifier": HKQuantityTypeIdentifierStepCount, @"unit": @"count", @"stat": @"sum", @"aliases": @[@"steps", @"step_count"]},
        @{@"name": @"distanceWalkingRunning", @"identifier": HKQuantityTypeIdentifierDistanceWalkingRunning, @"unit": @"m", @"stat": @"sum", @"aliases": @[@"walking_running_distance", @"distance"]},
        @{@"name": @"distanceCycling", @"identifier": HKQuantityTypeIdentifierDistanceCycling, @"unit": @"m", @"stat": @"sum", @"aliases": @[@"cycling_distance"]},
        @{@"name": @"flightsClimbed", @"identifier": HKQuantityTypeIdentifierFlightsClimbed, @"unit": @"count", @"stat": @"sum", @"aliases": @[@"flights"]},
        @{@"name": @"activeEnergyBurned", @"identifier": HKQuantityTypeIdentifierActiveEnergyBurned, @"unit": @"kcal", @"stat": @"sum", @"aliases": @[@"active_energy", @"moveEnergy"]},
        @{@"name": @"basalEnergyBurned", @"identifier": HKQuantityTypeIdentifierBasalEnergyBurned, @"unit": @"kcal", @"stat": @"sum", @"aliases": @[@"basal_energy"]},
        @{@"name": @"appleExerciseTime", @"identifier": HKQuantityTypeIdentifierAppleExerciseTime, @"unit": @"min", @"stat": @"sum", @"aliases": @[@"exerciseTime"]},
        @{@"name": @"appleStandTime", @"identifier": HKQuantityTypeIdentifierAppleStandTime, @"unit": @"min", @"stat": @"sum", @"aliases": @[@"standTime"]},
        @{@"name": @"bodyMass", @"identifier": HKQuantityTypeIdentifierBodyMass, @"unit": @"kg", @"stat": @"avg", @"aliases": @[@"weight"]},
        @{@"name": @"bodyMassIndex", @"identifier": HKQuantityTypeIdentifierBodyMassIndex, @"unit": @"count", @"stat": @"avg", @"aliases": @[@"bmi"]},
        @{@"name": @"bodyFatPercentage", @"identifier": HKQuantityTypeIdentifierBodyFatPercentage, @"unit": @"%", @"stat": @"avg", @"aliases": @[@"bodyFat"]},
        @{@"name": @"height", @"identifier": HKQuantityTypeIdentifierHeight, @"unit": @"m", @"stat": @"avg", @"aliases": @[]},
        @{@"name": @"leanBodyMass", @"identifier": HKQuantityTypeIdentifierLeanBodyMass, @"unit": @"kg", @"stat": @"avg", @"aliases": @[]},
        @{@"name": @"heartRate", @"identifier": HKQuantityTypeIdentifierHeartRate, @"unit": @"count/min", @"stat": @"avg", @"aliases": @[@"bpm"]},
        @{@"name": @"restingHeartRate", @"identifier": HKQuantityTypeIdentifierRestingHeartRate, @"unit": @"count/min", @"stat": @"avg", @"aliases": @[@"rhr"]},
        @{@"name": @"walkingHeartRateAverage", @"identifier": HKQuantityTypeIdentifierWalkingHeartRateAverage, @"unit": @"count/min", @"stat": @"avg", @"aliases": @[@"walkingBpm"]},
        @{@"name": @"heartRateVariabilitySDNN", @"identifier": HKQuantityTypeIdentifierHeartRateVariabilitySDNN, @"unit": @"ms", @"stat": @"avg", @"aliases": @[@"hrv", @"hrvSDNN"]},
        @{@"name": @"respiratoryRate", @"identifier": HKQuantityTypeIdentifierRespiratoryRate, @"unit": @"count/min", @"stat": @"avg", @"aliases": @[]},
        @{@"name": @"oxygenSaturation", @"identifier": HKQuantityTypeIdentifierOxygenSaturation, @"unit": @"%", @"stat": @"avg", @"aliases": @[@"spo2"]},
        @{@"name": @"bodyTemperature", @"identifier": HKQuantityTypeIdentifierBodyTemperature, @"unit": @"degC", @"stat": @"avg", @"aliases": @[]},
        @{@"name": @"bloodPressureSystolic", @"identifier": HKQuantityTypeIdentifierBloodPressureSystolic, @"unit": @"mmHg", @"stat": @"avg", @"aliases": @[@"systolic"]},
        @{@"name": @"bloodPressureDiastolic", @"identifier": HKQuantityTypeIdentifierBloodPressureDiastolic, @"unit": @"mmHg", @"stat": @"avg", @"aliases": @[@"diastolic"]},
        @{@"name": @"bloodGlucose", @"identifier": HKQuantityTypeIdentifierBloodGlucose, @"unit": @"mg/dL", @"stat": @"avg", @"aliases": @[@"glucose"]},
        @{@"name": @"dietaryEnergyConsumed", @"identifier": HKQuantityTypeIdentifierDietaryEnergyConsumed, @"unit": @"kcal", @"stat": @"sum", @"aliases": @[@"calories", @"energyConsumed"]},
        @{@"name": @"dietaryProtein", @"identifier": HKQuantityTypeIdentifierDietaryProtein, @"unit": @"g", @"stat": @"sum", @"aliases": @[@"protein"]},
        @{@"name": @"dietaryCarbohydrates", @"identifier": HKQuantityTypeIdentifierDietaryCarbohydrates, @"unit": @"g", @"stat": @"sum", @"aliases": @[@"carbs", @"carbohydrates"]},
        @{@"name": @"dietaryFatTotal", @"identifier": HKQuantityTypeIdentifierDietaryFatTotal, @"unit": @"g", @"stat": @"sum", @"aliases": @[@"fat", @"totalFat"]},
        @{@"name": @"dietaryFatSaturated", @"identifier": HKQuantityTypeIdentifierDietaryFatSaturated, @"unit": @"g", @"stat": @"sum", @"aliases": @[@"saturatedFat"]},
        @{@"name": @"dietaryCholesterol", @"identifier": HKQuantityTypeIdentifierDietaryCholesterol, @"unit": @"mg", @"stat": @"sum", @"aliases": @[@"cholesterol"]},
        @{@"name": @"dietaryFiber", @"identifier": HKQuantityTypeIdentifierDietaryFiber, @"unit": @"g", @"stat": @"sum", @"aliases": @[@"fiber"]},
        @{@"name": @"dietarySugar", @"identifier": HKQuantityTypeIdentifierDietarySugar, @"unit": @"g", @"stat": @"sum", @"aliases": @[@"sugar", @"sugars"]},
        @{@"name": @"dietarySodium", @"identifier": HKQuantityTypeIdentifierDietarySodium, @"unit": @"mg", @"stat": @"sum", @"aliases": @[@"sodium"]},
        @{@"name": @"dietaryPotassium", @"identifier": HKQuantityTypeIdentifierDietaryPotassium, @"unit": @"mg", @"stat": @"sum", @"aliases": @[@"potassium"]},
        @{@"name": @"dietaryCalcium", @"identifier": HKQuantityTypeIdentifierDietaryCalcium, @"unit": @"mg", @"stat": @"sum", @"aliases": @[@"calcium"]},
        @{@"name": @"dietaryIron", @"identifier": HKQuantityTypeIdentifierDietaryIron, @"unit": @"mg", @"stat": @"sum", @"aliases": @[@"iron"]},
        @{@"name": @"dietaryVitaminD", @"identifier": HKQuantityTypeIdentifierDietaryVitaminD, @"unit": @"mcg", @"stat": @"sum", @"aliases": @[@"vitaminD"]},
        @{@"name": @"dietaryWater", @"identifier": HKQuantityTypeIdentifierDietaryWater, @"unit": @"L", @"stat": @"sum", @"aliases": @[@"water"]},
        @{@"name": @"dietaryCaffeine", @"identifier": HKQuantityTypeIdentifierDietaryCaffeine, @"unit": @"mg", @"stat": @"sum", @"aliases": @[@"caffeine"]},
    ];
}

static NSArray<NSDictionary<NSString *, id> *> *codex_healthkit_category_catalog(void) {
    return @[
        @{@"name": @"sleepAnalysis", @"identifier": HKCategoryTypeIdentifierSleepAnalysis, @"aliases": @[@"sleep"]},
        @{@"name": @"mindfulSession", @"identifier": HKCategoryTypeIdentifierMindfulSession, @"aliases": @[@"mindfulness", @"mindful"]},
        @{@"name": @"appleStandHour", @"identifier": HKCategoryTypeIdentifierAppleStandHour, @"aliases": @[@"standHour"]},
    ];
}

static NSArray<NSDictionary<NSString *, id> *> *codex_healthkit_workout_catalog(void) {
    return @[
        @{@"name": @"walking", @"value": @(HKWorkoutActivityTypeWalking)},
        @{@"name": @"running", @"value": @(HKWorkoutActivityTypeRunning)},
        @{@"name": @"cycling", @"value": @(HKWorkoutActivityTypeCycling)},
        @{@"name": @"hiking", @"value": @(HKWorkoutActivityTypeHiking)},
        @{@"name": @"swimming", @"value": @(HKWorkoutActivityTypeSwimming)},
        @{@"name": @"yoga", @"value": @(HKWorkoutActivityTypeYoga)},
        @{@"name": @"highIntensityIntervalTraining", @"value": @(HKWorkoutActivityTypeHighIntensityIntervalTraining), @"aliases": @[@"hiit"]},
        @{@"name": @"traditionalStrengthTraining", @"value": @(HKWorkoutActivityTypeTraditionalStrengthTraining), @"aliases": @[@"strength"]},
        @{@"name": @"functionalStrengthTraining", @"value": @(HKWorkoutActivityTypeFunctionalStrengthTraining), @"aliases": @[@"functionalStrength"]},
        @{@"name": @"mixedCardio", @"value": @(HKWorkoutActivityTypeMixedCardio)},
        @{@"name": @"elliptical", @"value": @(HKWorkoutActivityTypeElliptical)},
        @{@"name": @"rowing", @"value": @(HKWorkoutActivityTypeRowing)},
        @{@"name": @"other", @"value": @(HKWorkoutActivityTypeOther)},
    ];
}

static NSDictionary<NSString *, NSString *> *codex_healthkit_quantity_alias_map(void) {
    static NSDictionary<NSString *, NSString *> *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary<NSString *, NSString *> *next = [NSMutableDictionary dictionary];
        for (NSDictionary<NSString *, id> *entry in codex_healthkit_quantity_catalog()) {
            NSString *identifier = entry[@"identifier"];
            NSArray<NSString *> *names = [@[entry[@"name"], identifier] arrayByAddingObjectsFromArray:entry[@"aliases"] ?: @[]];
            for (NSString *name in names) {
                next[[name lowercaseString]] = identifier;
            }
        }
        map = [next copy];
    });
    return map;
}

static NSDictionary<NSString *, NSString *> *codex_healthkit_category_alias_map(void) {
    static NSDictionary<NSString *, NSString *> *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary<NSString *, NSString *> *next = [NSMutableDictionary dictionary];
        for (NSDictionary<NSString *, id> *entry in codex_healthkit_category_catalog()) {
            NSString *identifier = entry[@"identifier"];
            NSArray<NSString *> *names = [@[entry[@"name"], identifier] arrayByAddingObjectsFromArray:entry[@"aliases"] ?: @[]];
            for (NSString *name in names) {
                next[[name lowercaseString]] = identifier;
            }
        }
        map = [next copy];
    });
    return map;
}

static NSString *codex_healthkit_resolve_identifier(NSDictionary<NSString *, NSString *> *aliases, NSString *value, NSString *prefix) {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return nil;
    }
    NSString *mapped = aliases[[trimmed lowercaseString]];
    if (mapped.length > 0) {
        return mapped;
    }
    if ([trimmed hasPrefix:prefix]) {
        return trimmed;
    }
    return nil;
}

static NSString *codex_healthkit_default_unit_string(NSString *identifier) {
    for (NSDictionary<NSString *, id> *entry in codex_healthkit_quantity_catalog()) {
        if ([entry[@"identifier"] isEqualToString:identifier]) {
            return entry[@"unit"];
        }
    }
    return @"count";
}

static NSString *codex_healthkit_default_stat(NSString *identifier) {
    for (NSDictionary<NSString *, id> *entry in codex_healthkit_quantity_catalog()) {
        if ([entry[@"identifier"] isEqualToString:identifier]) {
            return entry[@"stat"];
        }
    }
    return @"avg";
}

static NSString *codex_healthkit_iso_string(NSDate *date) {
    if (date == nil) {
        return nil;
    }
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    return [formatter stringFromDate:date];
}

static NSDate *codex_healthkit_start_of_day(NSDate *date) {
    return [[NSCalendar currentCalendar] startOfDayForDate:date ?: [NSDate date]];
}

static NSDate *codex_healthkit_parse_date(NSString *value, BOOL endOfDay, NSError **error) {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        if (error) *error = codex_macrodex_error(@"date value is empty");
        return nil;
    }

    NSString *lower = [trimmed lowercaseString];
    NSDate *now = [NSDate date];
    NSCalendar *calendar = [NSCalendar currentCalendar];
    if ([lower isEqualToString:@"now"]) {
        return now;
    }
    if ([lower isEqualToString:@"today"] || [lower isEqualToString:@"yesterday"] || [lower isEqualToString:@"tomorrow"]) {
        NSInteger offset = [lower isEqualToString:@"yesterday"] ? -1 : ([lower isEqualToString:@"tomorrow"] ? 1 : 0);
        NSDate *day = [calendar dateByAddingUnit:NSCalendarUnitDay value:offset toDate:codex_healthkit_start_of_day(now) options:0];
        return endOfDay ? [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:day options:0] : day;
    }

    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([trimmed rangeOfCharacterFromSet:nonDigits].location == NSNotFound && trimmed.length >= 10) {
        double raw = [trimmed doubleValue];
        double seconds = trimmed.length > 10 ? raw / 1000.0 : raw;
        return [NSDate dateWithTimeIntervalSince1970:seconds];
    }

    NSDateFormatter *dateOnly = [[NSDateFormatter alloc] init];
    dateOnly.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    dateOnly.calendar = calendar;
    dateOnly.dateFormat = @"yyyy-MM-dd";
    NSDate *date = [dateOnly dateFromString:trimmed];
    if (date != nil) {
        return endOfDay ? [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:date options:0] : date;
    }

    NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    date = [iso dateFromString:trimmed];
    if (date == nil) {
        iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        date = [iso dateFromString:trimmed];
    }
    if (date != nil) {
        return date;
    }

    NSDateFormatter *localDateTime = [[NSDateFormatter alloc] init];
    localDateTime.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    localDateTime.calendar = calendar;
    for (NSString *format in @[@"yyyy-MM-dd HH:mm:ss", @"yyyy-MM-dd HH:mm", @"yyyy-MM-dd'T'HH:mm:ss", @"yyyy-MM-dd'T'HH:mm"]) {
        localDateTime.dateFormat = format;
        date = [localDateTime dateFromString:trimmed];
        if (date != nil) {
            return date;
        }
    }

    if (error) *error = codex_macrodex_error([NSString stringWithFormat:@"Unable to parse date: %@", value]);
    return nil;
}

static BOOL codex_healthkit_resolve_interval(NSDictionary<NSString *, NSString *> *options, NSInteger defaultDays, BOOL requiresStart, NSDate **startOut, NSDate **endOut, NSError **error) {
    NSDate *start = nil;
    NSDate *end = nil;
    if (options[@"date"].length > 0) {
        start = codex_healthkit_parse_date(options[@"date"], NO, error);
        if (start == nil) return NO;
        end = codex_healthkit_parse_date(options[@"date"], YES, error);
        if (end == nil) return NO;
    }
    if (options[@"start"].length > 0) {
        start = codex_healthkit_parse_date(options[@"start"], NO, error);
        if (start == nil) return NO;
    }
    if (options[@"end"].length > 0) {
        end = codex_healthkit_parse_date(options[@"end"], YES, error);
        if (end == nil) return NO;
    }

    NSDate *now = [NSDate date];
    if (end == nil) {
        end = requiresStart ? start : now;
    }
    if (start == nil && options[@"days"].length > 0) {
        NSInteger days = MAX(1, [options[@"days"] integerValue]);
        start = [[NSCalendar currentCalendar] dateByAddingUnit:NSCalendarUnitDay value:-days toDate:end ?: now options:0];
    }
    if (start == nil && !requiresStart) {
        start = [[NSCalendar currentCalendar] dateByAddingUnit:NSCalendarUnitDay value:-MAX(defaultDays, 1) toDate:end ?: now options:0];
    }
    if (start == nil) {
        if (error) *error = codex_macrodex_error(@"--start is required for writes");
        return NO;
    }
    if (end == nil) {
        end = start;
    }
    if ([end compare:start] == NSOrderedAscending) {
        if (error) *error = codex_macrodex_error(@"--end must be after --start");
        return NO;
    }
    *startOut = start;
    *endOut = end;
    return YES;
}

static HKUnit *codex_healthkit_unit_from_string(NSString *unitString, NSString *identifier, NSError **error) {
    NSString *unitName = unitString.length > 0 ? unitString : codex_healthkit_default_unit_string(identifier);
    NSString *lower = [[unitName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([lower isEqualToString:@"bpm"]) lower = @"count/min";
    if ([lower isEqualToString:@"percent"]) lower = @"%";
    if ([lower isEqualToString:@"kilocalorie"] || [lower isEqualToString:@"kilocalories"]) lower = @"kcal";
    if ([lower isEqualToString:@"milliliter"] || [lower isEqualToString:@"milliliters"]) lower = @"ml";

    @try {
        if ([lower isEqualToString:@"count"]) return [HKUnit countUnit];
        if ([lower isEqualToString:@"count/min"]) return [[HKUnit countUnit] unitDividedByUnit:[HKUnit minuteUnit]];
        if ([lower isEqualToString:@"kcal"]) return [HKUnit kilocalorieUnit];
        if ([lower isEqualToString:@"cal"]) return [HKUnit smallCalorieUnit];
        if ([lower isEqualToString:@"kg"]) return [HKUnit gramUnitWithMetricPrefix:HKMetricPrefixKilo];
        if ([lower isEqualToString:@"g"]) return [HKUnit gramUnit];
        if ([lower isEqualToString:@"mg"]) return [HKUnit gramUnitWithMetricPrefix:HKMetricPrefixMilli];
        if ([lower isEqualToString:@"mcg"] || [lower isEqualToString:@"ug"]) return [HKUnit gramUnitWithMetricPrefix:HKMetricPrefixMicro];
        if ([lower isEqualToString:@"lb"] || [lower isEqualToString:@"lbs"]) return [HKUnit poundUnit];
        if ([lower isEqualToString:@"oz"]) return [HKUnit ounceUnit];
        if ([lower isEqualToString:@"m"]) return [HKUnit meterUnit];
        if ([lower isEqualToString:@"km"]) return [HKUnit meterUnitWithMetricPrefix:HKMetricPrefixKilo];
        if ([lower isEqualToString:@"cm"]) return [HKUnit meterUnitWithMetricPrefix:HKMetricPrefixCenti];
        if ([lower isEqualToString:@"mm"]) return [HKUnit meterUnitWithMetricPrefix:HKMetricPrefixMilli];
        if ([lower isEqualToString:@"mi"] || [lower isEqualToString:@"mile"] || [lower isEqualToString:@"miles"]) return [HKUnit mileUnit];
        if ([lower isEqualToString:@"ft"]) return [HKUnit footUnit];
        if ([lower isEqualToString:@"in"]) return [HKUnit inchUnit];
        if ([lower isEqualToString:@"l"]) return [HKUnit literUnit];
        if ([lower isEqualToString:@"ml"]) return [HKUnit literUnitWithMetricPrefix:HKMetricPrefixMilli];
        if ([lower isEqualToString:@"%"]) return [HKUnit percentUnit];
        if ([lower isEqualToString:@"s"] || [lower isEqualToString:@"sec"] || [lower isEqualToString:@"second"]) return [HKUnit secondUnit];
        if ([lower isEqualToString:@"ms"]) return [HKUnit secondUnitWithMetricPrefix:HKMetricPrefixMilli];
        if ([lower isEqualToString:@"min"]) return [HKUnit minuteUnit];
        if ([lower isEqualToString:@"h"] || [lower isEqualToString:@"hr"]) return [HKUnit hourUnit];
        if ([lower isEqualToString:@"degc"]) return [HKUnit degreeCelsiusUnit];
        if ([lower isEqualToString:@"degf"]) return [HKUnit degreeFahrenheitUnit];
        if ([lower isEqualToString:@"mmhg"]) return [HKUnit millimeterOfMercuryUnit];
        if ([lower isEqualToString:@"mg/dl"]) {
            return [[HKUnit gramUnitWithMetricPrefix:HKMetricPrefixMilli] unitDividedByUnit:[HKUnit literUnitWithMetricPrefix:HKMetricPrefixDeci]];
        }
        return [HKUnit unitFromString:unitName];
    } @catch (NSException *exception) {
        if (error) *error = codex_macrodex_error([NSString stringWithFormat:@"Invalid or incompatible unit: %@", unitName]);
        return nil;
    }
}

static id codex_healthkit_json_safe(id value) {
    if (value == nil || value == (id)kCFNull) {
        return [NSNull null];
    }
    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSDate class]]) {
        return codex_healthkit_iso_string(value);
    }
    if ([value isKindOfClass:[NSData class]]) {
        return [NSString stringWithFormat:@"<data:%lu bytes>", (unsigned long)[(NSData *)value length]];
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *items = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            [items addObject:codex_healthkit_json_safe(item)];
        }
        return items;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            dict[[key description]] = codex_healthkit_json_safe(obj);
        }];
        return dict;
    }
    return [value description];
}

static NSString *codex_healthkit_json_string(id object, BOOL pretty, NSError **error) {
    id safe = codex_healthkit_json_safe(object);
    NSJSONWritingOptions options = pretty ? NSJSONWritingPrettyPrinted : 0;
    NSData *data = [NSJSONSerialization dataWithJSONObject:safe ?: @{} options:options error:error];
    if (data == nil) {
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static int codex_healthkit_emit_json(id object, NSDictionary<NSString *, NSString *> *options, NSString *cwd, char **output, size_t *output_len) {
    NSError *jsonError = nil;
    BOOL compact = [options[@"compact"] isEqualToString:@"true"] || [options[@"pretty"] isEqualToString:@"false"];
    NSString *text = codex_healthkit_json_string(object, !compact, &jsonError);
    if (text == nil) {
        codex_ios_set_output([NSString stringWithFormat:@"JSON error: %@\n", jsonError.localizedDescription ?: @"unknown"], output, output_len);
        return 1;
    }
    text = [text stringByAppendingString:@"\n"];
    NSString *outPath = options[@"out"] ?: options[@"output"];
    if (outPath.length > 0) {
        NSString *resolved = codex_ios_resolve_workspace_path(outPath, cwd);
        NSString *parent = [resolved stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *writeError = nil;
        BOOL ok = [text writeToFile:resolved atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
        if (!ok) {
            codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", writeError.localizedDescription ?: @"failed to write output"], output, output_len);
            return 1;
        }
        return codex_healthkit_emit_json(@{@"ok": @YES, @"path": codex_ios_virtual_path(resolved)}, @{@"compact": @"true"}, cwd, output, output_len);
    }
    codex_ios_set_output(text, output, output_len);
    return 0;
}

static NSDictionary<NSString *, NSString *> *codex_healthkit_parse_options(NSArray<NSString *> *args, NSUInteger startIndex, NSMutableArray<NSString *> **positionals, NSError **error) {
    NSMutableDictionary<NSString *, NSString *> *options = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *pos = [NSMutableArray array];
    for (NSUInteger index = startIndex; index < args.count; index++) {
        NSString *arg = args[index];
        if ([arg hasPrefix:@"--"]) {
            NSString *body = [arg substringFromIndex:2];
            NSString *key = body;
            NSString *value = nil;
            NSRange equals = [body rangeOfString:@"="];
            if (equals.location != NSNotFound) {
                key = [body substringToIndex:equals.location];
                value = [body substringFromIndex:equals.location + 1];
            } else if (index + 1 < args.count && ![args[index + 1] hasPrefix:@"--"]) {
                value = args[++index];
            } else {
                value = @"true";
            }
            if (key.length == 0) {
                if (error) *error = codex_macrodex_error(@"empty option name");
                return nil;
            }
            options[key] = value ?: @"true";
        } else if ([arg isEqualToString:@"-h"]) {
            options[@"help"] = @"true";
        } else {
            [pos addObject:arg];
        }
    }
    if (positionals != NULL) {
        *positionals = pos;
    }
    return options;
}

static NSArray<NSString *> *codex_healthkit_args_from_command(NSString *command, NSError **error) {
    if (!codex_ios_command_starts_with_token(command, @[@"healthkit", @"hk"])) {
        return nil;
    }
    NSArray<NSString *> *words = codex_ios_split_shell_words(command, error);
    if (words.count == 0) {
        return nil;
    }
    NSString *name = words.firstObject;
    if (![name isEqualToString:@"healthkit"] && ![name isEqualToString:@"hk"]) {
        return nil;
    }
    if (words.count == 1) {
        return @[];
    }
    return [words subarrayWithRange:NSMakeRange(1, words.count - 1)];
}

static NSString *codex_healthkit_help_text(void) {
    return @"Usage: healthkit <command> [options]\n"
           @"Commands:\n"
           @"  status\n"
           @"  request [--type quantity|category|workout] [--identifier stepCount]\n"
           @"  types\n"
           @"  characteristics\n"
           @"  query --type quantity|category|workout --identifier stepCount --start today --end now [--limit 100]\n"
           @"  stats --identifier stepCount --start 2026-04-01 --end now --bucket day [--stat sum|avg|min|max|mostRecent]\n"
           @"  sync-nutrition [--date YYYY-MM-DD|--days 7] [--force true]\n"
           @"  write-quantity --identifier dietaryEnergyConsumed --value 450 --unit kcal --start now\n"
           @"  write-category --identifier sleepAnalysis --value asleepCore --start 2026-04-22T23:00:00 --end 2026-04-23T07:00:00\n"
           @"  write-workout --activity running --start 2026-04-23T07:00:00 --end 2026-04-23T07:30:00 [--energy 250 --distance 5000]\n"
           @"Global options: --out /home/codex/file.json, --compact true.\n"
           @"Dates accept now, today, yesterday, YYYY-MM-DD, ISO-8601, or epoch seconds/ms.\n";
}

static HKQuantityType *codex_healthkit_quantity_type(NSString *identifier, NSError **error) {
    NSString *resolved = codex_healthkit_resolve_identifier(codex_healthkit_quantity_alias_map(), identifier, @"HKQuantityTypeIdentifier");
    HKQuantityType *type = resolved.length > 0 ? [HKQuantityType quantityTypeForIdentifier:resolved] : nil;
    if (type == nil && error != NULL) {
        *error = codex_macrodex_error([NSString stringWithFormat:@"Unsupported quantity identifier: %@", identifier ?: @""]);
    }
    return type;
}

static HKCategoryType *codex_healthkit_category_type(NSString *identifier, NSError **error) {
    NSString *resolved = codex_healthkit_resolve_identifier(codex_healthkit_category_alias_map(), identifier, @"HKCategoryTypeIdentifier");
    HKCategoryType *type = resolved.length > 0 ? [HKCategoryType categoryTypeForIdentifier:resolved] : nil;
    if (type == nil && error != NULL) {
        *error = codex_macrodex_error([NSString stringWithFormat:@"Unsupported category identifier: %@", identifier ?: @""]);
    }
    return type;
}

static BOOL codex_healthkit_sample_type_can_share(HKSampleType *type) {
    if (type == nil) {
        return NO;
    }
    NSString *identifier = type.identifier ?: @"";
    static NSSet<NSString *> *readOnlyIdentifiers = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        readOnlyIdentifiers = [NSSet setWithArray:@[
            HKQuantityTypeIdentifierAppleExerciseTime,
            HKQuantityTypeIdentifierAppleStandTime,
            HKQuantityTypeIdentifierRestingHeartRate,
            HKQuantityTypeIdentifierWalkingHeartRateAverage,
            HKQuantityTypeIdentifierHeartRateVariabilitySDNN,
            HKCategoryTypeIdentifierAppleStandHour,
        ]];
    });
    return ![readOnlyIdentifiers containsObject:identifier];
}

static NSSet<HKSampleType *> *codex_healthkit_default_share_types(void) {
    NSMutableSet<HKSampleType *> *types = [NSMutableSet set];
    for (NSDictionary<NSString *, id> *entry in codex_healthkit_quantity_catalog()) {
        HKQuantityType *type = [HKQuantityType quantityTypeForIdentifier:entry[@"identifier"]];
        if (codex_healthkit_sample_type_can_share(type)) [types addObject:type];
    }
    for (NSDictionary<NSString *, id> *entry in codex_healthkit_category_catalog()) {
        HKCategoryType *type = [HKCategoryType categoryTypeForIdentifier:entry[@"identifier"]];
        if (codex_healthkit_sample_type_can_share(type)) [types addObject:type];
    }
    [types addObject:[HKObjectType workoutType]];
    return types;
}

static NSSet<HKObjectType *> *codex_healthkit_default_read_types(void) {
    NSMutableSet<HKObjectType *> *types = [NSMutableSet setWithSet:codex_healthkit_default_share_types()];
    for (HKCharacteristicTypeIdentifier identifier in @[
        HKCharacteristicTypeIdentifierDateOfBirth,
        HKCharacteristicTypeIdentifierBiologicalSex,
        HKCharacteristicTypeIdentifierBloodType,
        HKCharacteristicTypeIdentifierFitzpatrickSkinType,
        HKCharacteristicTypeIdentifierWheelchairUse,
        HKCharacteristicTypeIdentifierActivityMoveMode,
    ]) {
        HKCharacteristicType *type = [HKObjectType characteristicTypeForIdentifier:identifier];
        if (type != nil) [types addObject:type];
    }
    return types;
}

static BOOL codex_healthkit_authorization_sets(NSDictionary<NSString *, NSString *> *options, NSSet<HKSampleType *> **shareTypes, NSSet<HKObjectType *> **readTypes, NSError **error) {
    NSString *identifier = options[@"identifier"];
    NSString *kind = [options[@"type"] lowercaseString];
    if (identifier.length == 0 && kind.length == 0) {
        *shareTypes = codex_healthkit_default_share_types();
        *readTypes = codex_healthkit_default_read_types();
        return YES;
    }

    NSMutableSet<HKSampleType *> *share = [NSMutableSet set];
    NSMutableSet<HKObjectType *> *read = [NSMutableSet set];
    if ([kind isEqualToString:@"quantity"] || (kind.length == 0 && identifier.length > 0)) {
        HKQuantityType *type = codex_healthkit_quantity_type(identifier, nil);
        if (type != nil) {
            if (codex_healthkit_sample_type_can_share(type)) [share addObject:type];
            [read addObject:type];
        }
    }
    if ([kind isEqualToString:@"category"] || (kind.length == 0 && identifier.length > 0 && share.count == 0)) {
        HKCategoryType *type = codex_healthkit_category_type(identifier, nil);
        if (type != nil) {
            if (codex_healthkit_sample_type_can_share(type)) [share addObject:type];
            [read addObject:type];
        }
    }
    if ([kind isEqualToString:@"workout"]) {
        HKSampleType *type = [HKObjectType workoutType];
        [share addObject:type];
        [read addObject:type];
    }
    if (share.count == 0 && read.count == 0) {
        if (error) *error = codex_macrodex_error(@"request needs a supported --type/--identifier pair");
        return NO;
    }
    *shareTypes = share;
    *readTypes = read;
    return YES;
}

static NSDictionary<NSString *, id> *codex_healthkit_status_object(void) {
    HKHealthStore *store = codex_healthkit_store();
    if (store == nil) {
        return @{@"available": @NO, @"message": @"HealthKit is unavailable on this device."};
    }
    NSInteger authorized = 0;
    NSInteger denied = 0;
    NSInteger notDetermined = 0;
    NSMutableArray<NSDictionary *> *writeStatuses = [NSMutableArray array];
    for (HKSampleType *type in codex_healthkit_default_share_types()) {
        HKAuthorizationStatus status = [store authorizationStatusForType:type];
        NSString *statusText = @"notDetermined";
        if (status == HKAuthorizationStatusSharingAuthorized) {
            authorized++;
            statusText = @"sharingAuthorized";
        } else if (status == HKAuthorizationStatusSharingDenied) {
            denied++;
            statusText = @"sharingDenied";
        } else {
            notDetermined++;
        }
        [writeStatuses addObject:@{
            @"identifier": type.identifier ?: @"workout",
            @"writeStatus": statusText,
        }];
    }
    return @{
        @"available": @YES,
        @"promptedByMacrodex": @([[NSUserDefaults standardUserDefaults] boolForKey:CodexHealthKitPromptedKey]),
        @"writeAuthorization": @{
            @"authorized": @(authorized),
            @"denied": @(denied),
            @"notDetermined": @(notDetermined),
        },
        @"readAuthorizationNote": @"iOS does not disclose per-type read authorization status to apps. A query may return no rows if read access was denied.",
        @"writeStatuses": writeStatuses,
    };
}

NSString *codex_healthkit_status_summary(void) {
    NSDictionary<NSString *, id> *status = codex_healthkit_status_object();
    if (![status[@"available"] boolValue]) {
        return status[@"message"] ?: @"HealthKit unavailable";
    }
    NSDictionary *write = status[@"writeAuthorization"];
    return [NSString stringWithFormat:@"Write access: %@ authorized, %@ not decided, %@ denied. Read access is controlled in iOS Health settings.",
            write[@"authorized"] ?: @0,
            write[@"notDetermined"] ?: @0,
            write[@"denied"] ?: @0];
}

static void codex_healthkit_request_authorization_async(NSSet<HKSampleType *> *shareTypes, NSSet<HKObjectType *> *readTypes, void (^completion)(BOOL success, NSError *error)) {
    HKHealthStore *store = codex_healthkit_store();
    if (store == nil) {
        if (completion) completion(NO, codex_macrodex_error(@"HealthKit is unavailable on this device"));
        return;
    }
    NSSet<HKSampleType *> *effectiveShareTypes = shareTypes ?: codex_healthkit_default_share_types();
    NSSet<HKObjectType *> *effectiveReadTypes = readTypes ?: codex_healthkit_default_read_types();
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [store requestAuthorizationToShareTypes:effectiveShareTypes
                                          readTypes:effectiveReadTypes
                                         completion:^(BOOL success, NSError *error) {
                if (completion) completion(success, error);
            }];
        } @catch (NSException *exception) {
            NSString *reason = exception.reason.length > 0 ? exception.reason : exception.name;
            if (completion) completion(NO, codex_macrodex_error([NSString stringWithFormat:@"HealthKit authorization failed: %@", reason ?: @"invalid authorization types"]));
        }
    });
}

void codex_healthkit_request_authorization_from_settings(void) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:CodexHealthKitPromptedKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    codex_healthkit_request_authorization_async(nil, nil, nil);
}

void codex_healthkit_request_authorization_if_needed(void) {
    if (codex_healthkit_store() == nil) {
        return;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:CodexHealthKitPromptedKey]) {
        return;
    }
    [defaults setBool:YES forKey:CodexHealthKitPromptedKey];
    [defaults synchronize];
    codex_healthkit_request_authorization_async(nil, nil, nil);
}

static NSDictionary<NSString *, id> *codex_healthkit_request_blocking(NSDictionary<NSString *, NSString *> *options, NSError **error) {
    NSSet<HKSampleType *> *shareTypes = nil;
    NSSet<HKObjectType *> *readTypes = nil;
    if (!codex_healthkit_authorization_sets(options, &shareTypes, &readTypes, error)) {
        return nil;
    }
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:CodexHealthKitPromptedKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if ([NSThread isMainThread]) {
        codex_healthkit_request_authorization_async(shareTypes, readTypes, nil);
        return @{@"ok": @YES, @"promptShown": @YES, @"completed": @NO, @"message": @"Authorization prompt started on the main thread."};
    }

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block BOOL completed = NO;
    __block BOOL success = NO;
    __block NSError *requestError = nil;
    codex_healthkit_request_authorization_async(shareTypes, readTypes, ^(BOOL ok, NSError *err) {
        success = ok;
        requestError = err;
        completed = YES;
        dispatch_semaphore_signal(sema);
    });
    long wait = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)));
    if (wait != 0 || !completed) {
        if (error) *error = codex_macrodex_error(@"Timed out waiting for HealthKit authorization");
        return nil;
    }
    if (!success) {
        if (error) *error = requestError ?: codex_macrodex_error(@"HealthKit authorization failed");
        return nil;
    }
    return @{@"ok": @YES, @"promptShown": @YES, @"completed": @YES, @"status": codex_healthkit_status_object()};
}

static NSString *codex_healthkit_category_value_name(NSString *identifier, NSInteger value) {
    if ([identifier isEqualToString:HKCategoryTypeIdentifierSleepAnalysis]) {
        switch (value) {
            case HKCategoryValueSleepAnalysisInBed: return @"inBed";
            case HKCategoryValueSleepAnalysisAsleepUnspecified: return @"asleepUnspecified";
            case HKCategoryValueSleepAnalysisAwake: return @"awake";
            case HKCategoryValueSleepAnalysisAsleepCore: return @"asleepCore";
            case HKCategoryValueSleepAnalysisAsleepDeep: return @"asleepDeep";
            case HKCategoryValueSleepAnalysisAsleepREM: return @"asleepREM";
            default: return [NSString stringWithFormat:@"%ld", (long)value];
        }
    }
    if ([identifier isEqualToString:HKCategoryTypeIdentifierAppleStandHour]) {
        switch (value) {
            case HKCategoryValueAppleStandHourStood: return @"stood";
            case HKCategoryValueAppleStandHourIdle: return @"idle";
            default: return [NSString stringWithFormat:@"%ld", (long)value];
        }
    }
    if ([identifier isEqualToString:HKCategoryTypeIdentifierMindfulSession] && value == HKCategoryValueNotApplicable) {
        return @"notApplicable";
    }
    return [NSString stringWithFormat:@"%ld", (long)value];
}

static NSInteger codex_healthkit_category_value(NSString *identifier, NSString *value, NSError **error) {
    NSString *lower = [[value ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (lower.length == 0) {
        if (error) *error = codex_macrodex_error(@"--value is required");
        return NSNotFound;
    }
    if ([identifier isEqualToString:HKCategoryTypeIdentifierSleepAnalysis]) {
        NSDictionary<NSString *, NSNumber *> *values = @{
            @"inbed": @(HKCategoryValueSleepAnalysisInBed),
            @"asleep": @(HKCategoryValueSleepAnalysisAsleepUnspecified),
            @"asleepunspecified": @(HKCategoryValueSleepAnalysisAsleepUnspecified),
            @"awake": @(HKCategoryValueSleepAnalysisAwake),
            @"asleepcore": @(HKCategoryValueSleepAnalysisAsleepCore),
            @"asleepdeep": @(HKCategoryValueSleepAnalysisAsleepDeep),
            @"asleeprem": @(HKCategoryValueSleepAnalysisAsleepREM),
        };
        NSNumber *mapped = values[lower];
        if (mapped != nil) return mapped.integerValue;
    }
    if ([identifier isEqualToString:HKCategoryTypeIdentifierAppleStandHour]) {
        NSDictionary<NSString *, NSNumber *> *values = @{
            @"stood": @(HKCategoryValueAppleStandHourStood),
            @"idle": @(HKCategoryValueAppleStandHourIdle),
        };
        NSNumber *mapped = values[lower];
        if (mapped != nil) return mapped.integerValue;
    }
    if ([identifier isEqualToString:HKCategoryTypeIdentifierMindfulSession] && ([lower isEqualToString:@"notapplicable"] || [lower isEqualToString:@"0"])) {
        return HKCategoryValueNotApplicable;
    }
    NSScanner *scanner = [NSScanner scannerWithString:lower];
    NSInteger integer = 0;
    if ([scanner scanInteger:&integer]) {
        return integer;
    }
    if (error) *error = codex_macrodex_error([NSString stringWithFormat:@"Unsupported category value '%@' for %@", value, identifier]);
    return NSNotFound;
}

static NSDictionary<NSString *, id> *codex_healthkit_source_info(HKSample *sample) {
    NSMutableDictionary<NSString *, id> *source = [NSMutableDictionary dictionary];
    HKSourceRevision *revision = sample.sourceRevision;
    if (revision.source.name.length > 0) source[@"name"] = revision.source.name;
    if (revision.source.bundleIdentifier.length > 0) source[@"bundleIdentifier"] = revision.source.bundleIdentifier;
    if (revision.productType.length > 0) source[@"productType"] = revision.productType;
    return source;
}

static NSDictionary<NSString *, id> *codex_healthkit_device_info(HKDevice *device) {
    if (device == nil) return @{};
    NSMutableDictionary<NSString *, id> *dict = [NSMutableDictionary dictionary];
    if (device.name.length > 0) dict[@"name"] = device.name;
    if (device.manufacturer.length > 0) dict[@"manufacturer"] = device.manufacturer;
    if (device.model.length > 0) dict[@"model"] = device.model;
    if (device.hardwareVersion.length > 0) dict[@"hardwareVersion"] = device.hardwareVersion;
    if (device.softwareVersion.length > 0) dict[@"softwareVersion"] = device.softwareVersion;
    if (device.localIdentifier.length > 0) dict[@"localIdentifier"] = device.localIdentifier;
    if (device.UDIDeviceIdentifier.length > 0) dict[@"udiDeviceIdentifier"] = device.UDIDeviceIdentifier;
    return dict;
}

static NSDictionary<NSString *, id> *codex_healthkit_base_sample(HKSample *sample) {
    return @{
        @"uuid": sample.UUID.UUIDString ?: @"",
        @"startDate": codex_healthkit_iso_string(sample.startDate) ?: @"",
        @"endDate": codex_healthkit_iso_string(sample.endDate) ?: @"",
        @"source": codex_healthkit_source_info(sample),
        @"device": codex_healthkit_device_info(sample.device),
        @"metadata": codex_healthkit_json_safe(sample.metadata ?: @{}),
    };
}

static NSDictionary<NSString *, id> *codex_healthkit_quantity_sample_json(HKQuantitySample *sample, HKUnit *unit, NSString *unitName) {
    NSMutableDictionary *dict = [codex_healthkit_base_sample(sample) mutableCopy];
    dict[@"type"] = @"quantity";
    dict[@"identifier"] = sample.quantityType.identifier ?: @"";
    dict[@"value"] = @([sample.quantity doubleValueForUnit:unit]);
    dict[@"unit"] = unitName ?: @"";
    return dict;
}

static NSDictionary<NSString *, id> *codex_healthkit_category_sample_json(HKCategorySample *sample) {
    NSMutableDictionary *dict = [codex_healthkit_base_sample(sample) mutableCopy];
    dict[@"type"] = @"category";
    dict[@"identifier"] = sample.categoryType.identifier ?: @"";
    dict[@"value"] = @(sample.value);
    dict[@"valueName"] = codex_healthkit_category_value_name(sample.categoryType.identifier, sample.value);
    return dict;
}

static NSString *codex_healthkit_workout_activity_name(HKWorkoutActivityType activityType) {
    for (NSDictionary<NSString *, id> *entry in codex_healthkit_workout_catalog()) {
        if ([entry[@"value"] unsignedIntegerValue] == activityType) {
            return entry[@"name"];
        }
    }
    return [NSString stringWithFormat:@"%lu", (unsigned long)activityType];
}

static HKWorkoutActivityType codex_healthkit_workout_activity_type(NSString *activity, NSError **error) {
    NSString *lower = [[activity ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    for (NSDictionary<NSString *, id> *entry in codex_healthkit_workout_catalog()) {
        if ([[entry[@"name"] lowercaseString] isEqualToString:lower]) {
            return [entry[@"value"] unsignedIntegerValue];
        }
        for (NSString *alias in entry[@"aliases"] ?: @[]) {
            if ([[alias lowercaseString] isEqualToString:lower]) {
                return [entry[@"value"] unsignedIntegerValue];
            }
        }
    }
    NSScanner *scanner = [NSScanner scannerWithString:lower];
    NSInteger raw = 0;
    if ([scanner scanInteger:&raw]) {
        return (HKWorkoutActivityType)raw;
    }
    if (error) *error = codex_macrodex_error([NSString stringWithFormat:@"Unsupported workout activity: %@", activity ?: @""]);
    return HKWorkoutActivityTypeOther;
}

static HKQuantityTypeIdentifier codex_healthkit_distance_identifier_for_activity(HKWorkoutActivityType activity) {
    switch (activity) {
        case HKWorkoutActivityTypeCycling:
            return HKQuantityTypeIdentifierDistanceCycling;
        case HKWorkoutActivityTypeSwimming:
            return HKQuantityTypeIdentifierDistanceSwimming;
        default:
            return HKQuantityTypeIdentifierDistanceWalkingRunning;
    }
}

static HKQuantity *codex_healthkit_workout_sum_quantity(HKWorkout *workout, HKQuantityTypeIdentifier identifier) {
    HKQuantityType *type = [HKQuantityType quantityTypeForIdentifier:identifier];
    if (type == nil) {
        return nil;
    }
    return [[workout statisticsForType:type] sumQuantity];
}

static NSDictionary<NSString *, id> *codex_healthkit_workout_json(HKWorkout *workout) {
    NSMutableDictionary *dict = [codex_healthkit_base_sample(workout) mutableCopy];
    dict[@"type"] = @"workout";
    dict[@"activityType"] = @(workout.workoutActivityType);
    dict[@"activityName"] = codex_healthkit_workout_activity_name(workout.workoutActivityType);
    dict[@"durationSeconds"] = @(workout.duration);
    HKQuantity *energy = codex_healthkit_workout_sum_quantity(workout, HKQuantityTypeIdentifierActiveEnergyBurned);
    if (energy != nil) {
        dict[@"totalEnergyBurnedKcal"] = @([energy doubleValueForUnit:[HKUnit kilocalorieUnit]]);
    }
    HKQuantity *distance = codex_healthkit_workout_sum_quantity(workout, codex_healthkit_distance_identifier_for_activity(workout.workoutActivityType));
    if (distance != nil) {
        dict[@"totalDistanceMeters"] = @([distance doubleValueForUnit:[HKUnit meterUnit]]);
    }
    return dict;
}

static NSPredicate *codex_healthkit_predicate(NSDate *start, NSDate *end) {
    return [HKQuery predicateForSamplesWithStartDate:start endDate:end options:HKQueryOptionStrictStartDate];
}

static NSArray<HKSample *> *codex_healthkit_run_sample_query(HKSampleType *type, NSDate *start, NSDate *end, NSUInteger limit, NSError **error) {
    HKHealthStore *store = codex_healthkit_store();
    if (store == nil) {
        if (error) *error = codex_macrodex_error(@"HealthKit is unavailable on this device");
        return nil;
    }
    NSSortDescriptor *sort = [NSSortDescriptor sortDescriptorWithKey:HKSampleSortIdentifierEndDate ascending:NO];
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSArray<HKSample *> *samples = nil;
    __block NSError *queryError = nil;
    HKSampleQuery *query = [[HKSampleQuery alloc] initWithSampleType:type predicate:codex_healthkit_predicate(start, end) limit:limit sortDescriptors:@[sort] resultsHandler:^(HKSampleQuery *query, NSArray<__kindof HKSample *> *results, NSError *err) {
        samples = results;
        queryError = err;
        dispatch_semaphore_signal(sema);
    }];
    [store executeQuery:query];
    long wait = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)));
    if (wait != 0) {
        [store stopQuery:query];
        if (error) *error = codex_macrodex_error(@"Timed out waiting for HealthKit query");
        return nil;
    }
    if (queryError != nil) {
        if (error) *error = queryError;
        return nil;
    }
    return samples ?: @[];
}

static int codex_healthkit_query(NSDictionary<NSString *, NSString *> *options, NSString *cwd, char **output, size_t *output_len) {
    NSError *error = nil;
    NSDate *start = nil;
    NSDate *end = nil;
    if (!codex_healthkit_resolve_interval(options, 7, NO, &start, &end, &error)) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    NSString *kind = [options[@"type"] lowercaseString];
    NSString *identifier = options[@"identifier"];
    NSUInteger limit = options[@"limit"].length > 0 ? (NSUInteger)MAX(0, [options[@"limit"] integerValue]) : 100;
    if (limit == 0) limit = HKObjectQueryNoLimit;

    NSMutableArray *rows = [NSMutableArray array];
    NSString *resolvedIdentifier = identifier;
    NSString *unitName = options[@"unit"];
    if ([kind isEqualToString:@"quantity"]) {
        HKQuantityType *type = codex_healthkit_quantity_type(identifier, &error);
        if (type == nil) {
            codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
            return 1;
        }
        resolvedIdentifier = type.identifier;
        unitName = unitName.length > 0 ? unitName : codex_healthkit_default_unit_string(type.identifier);
        HKUnit *unit = codex_healthkit_unit_from_string(unitName, type.identifier, &error);
        if (unit == nil) {
            codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
            return 1;
        }
        NSArray<HKSample *> *samples = codex_healthkit_run_sample_query(type, start, end, limit, &error);
        if (samples == nil) {
            codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
            return 1;
        }
        for (HKQuantitySample *sample in samples) {
            [rows addObject:codex_healthkit_quantity_sample_json(sample, unit, unitName)];
        }
    } else if ([kind isEqualToString:@"category"]) {
        HKCategoryType *type = codex_healthkit_category_type(identifier, &error);
        if (type == nil) {
            codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
            return 1;
        }
        resolvedIdentifier = type.identifier;
        NSArray<HKSample *> *samples = codex_healthkit_run_sample_query(type, start, end, limit, &error);
        if (samples == nil) {
            codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
            return 1;
        }
        for (HKCategorySample *sample in samples) {
            [rows addObject:codex_healthkit_category_sample_json(sample)];
        }
    } else if ([kind isEqualToString:@"workout"]) {
        NSArray<HKSample *> *samples = codex_healthkit_run_sample_query([HKObjectType workoutType], start, end, limit, &error);
        if (samples == nil) {
            codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
            return 1;
        }
        for (HKWorkout *workout in samples) {
            [rows addObject:codex_healthkit_workout_json(workout)];
        }
        resolvedIdentifier = @"workout";
    } else {
        codex_ios_set_output(@"healthkit: --type must be quantity, category, or workout\n", output, output_len);
        return 1;
    }

    return codex_healthkit_emit_json(@{
        @"type": kind ?: @"",
        @"identifier": resolvedIdentifier ?: @"",
        @"startDate": codex_healthkit_iso_string(start) ?: @"",
        @"endDate": codex_healthkit_iso_string(end) ?: @"",
        @"count": @(rows.count),
        @"samples": rows,
    }, options, cwd, output, output_len);
}

static NSDateComponents *codex_healthkit_bucket_components(NSString *bucket) {
    NSDateComponents *components = [[NSDateComponents alloc] init];
    NSString *lower = [(bucket ?: @"day") lowercaseString];
    if ([lower isEqualToString:@"hour"]) components.hour = 1;
    else if ([lower isEqualToString:@"week"]) components.day = 7;
    else if ([lower isEqualToString:@"month"]) components.month = 1;
    else components.day = 1;
    return components;
}

static int codex_healthkit_stats(NSDictionary<NSString *, NSString *> *options, NSString *cwd, char **output, size_t *output_len) {
    NSError *error = nil;
    NSDate *start = nil;
    NSDate *end = nil;
    if (!codex_healthkit_resolve_interval(options, 7, NO, &start, &end, &error)) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    HKQuantityType *type = codex_healthkit_quantity_type(options[@"identifier"], &error);
    if (type == nil) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    NSString *unitName = options[@"unit"].length > 0 ? options[@"unit"] : codex_healthkit_default_unit_string(type.identifier);
    HKUnit *unit = codex_healthkit_unit_from_string(unitName, type.identifier, &error);
    if (unit == nil) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    NSString *stat = options[@"stat"].length > 0 ? [options[@"stat"] lowercaseString] : codex_healthkit_default_stat(type.identifier);
    HKStatisticsOptions statOptions = HKStatisticsOptionDiscreteAverage;
    if ([stat isEqualToString:@"sum"]) statOptions = HKStatisticsOptionCumulativeSum;
    else if ([stat isEqualToString:@"min"]) statOptions = HKStatisticsOptionDiscreteMin;
    else if ([stat isEqualToString:@"max"]) statOptions = HKStatisticsOptionDiscreteMax;
    else if ([stat isEqualToString:@"mostrecent"] || [stat isEqualToString:@"latest"]) statOptions = HKStatisticsOptionMostRecent;
    else stat = @"avg";

    HKHealthStore *store = codex_healthkit_store();
    if (store == nil) {
        codex_ios_set_output(@"healthkit: HealthKit is unavailable on this device\n", output, output_len);
        return 1;
    }
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block HKStatisticsCollection *collection = nil;
    __block NSError *queryError = nil;
    HKStatisticsCollectionQuery *query = [[HKStatisticsCollectionQuery alloc] initWithQuantityType:type
                                                                           quantitySamplePredicate:codex_healthkit_predicate(start, end)
                                                                                           options:statOptions
                                                                                        anchorDate:start
                                                                                intervalComponents:codex_healthkit_bucket_components(options[@"bucket"] ?: @"day")];
    query.initialResultsHandler = ^(HKStatisticsCollectionQuery *query, HKStatisticsCollection *result, NSError *err) {
        collection = result;
        queryError = err;
        dispatch_semaphore_signal(sema);
    };
    [store executeQuery:query];
    long wait = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)));
    if (wait != 0) {
        [store stopQuery:query];
        codex_ios_set_output(@"healthkit: Timed out waiting for HealthKit statistics\n", output, output_len);
        return 1;
    }
    if (queryError != nil) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", queryError.localizedDescription], output, output_len);
        return 1;
    }

    NSMutableArray *buckets = [NSMutableArray array];
    [collection enumerateStatisticsFromDate:start toDate:end withBlock:^(HKStatistics *result, BOOL *stop) {
        HKQuantity *quantity = nil;
        if ([stat isEqualToString:@"sum"]) quantity = [result sumQuantity];
        else if ([stat isEqualToString:@"min"]) quantity = [result minimumQuantity];
        else if ([stat isEqualToString:@"max"]) quantity = [result maximumQuantity];
        else if ([stat isEqualToString:@"mostrecent"] || [stat isEqualToString:@"latest"]) quantity = [result mostRecentQuantity];
        else quantity = [result averageQuantity];
        [buckets addObject:@{
            @"startDate": codex_healthkit_iso_string(result.startDate) ?: @"",
            @"endDate": codex_healthkit_iso_string(result.endDate) ?: @"",
            @"value": quantity != nil ? @([quantity doubleValueForUnit:unit]) : [NSNull null],
            @"unit": unitName,
        }];
    }];

    return codex_healthkit_emit_json(@{
        @"type": @"quantity",
        @"identifier": type.identifier ?: @"",
        @"stat": stat,
        @"bucket": options[@"bucket"] ?: @"day",
        @"unit": unitName,
        @"startDate": codex_healthkit_iso_string(start) ?: @"",
        @"endDate": codex_healthkit_iso_string(end) ?: @"",
        @"buckets": buckets,
    }, options, cwd, output, output_len);
}

static NSDictionary<NSString *, id> *codex_healthkit_metadata_from_options(NSDictionary<NSString *, NSString *> *options, NSError **error) {
    NSMutableDictionary<NSString *, id> *metadata = [NSMutableDictionary dictionary];
    NSString *metadataJSON = options[@"metadata"];
    if (metadataJSON.length > 0) {
        NSData *data = [metadataJSON dataUsingEncoding:NSUTF8StringEncoding];
        id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
        if (object == nil) return nil;
        if (![object isKindOfClass:[NSDictionary class]]) {
            if (error) *error = codex_macrodex_error(@"--metadata must be a JSON object");
            return nil;
        }
        [metadata addEntriesFromDictionary:object];
    }
    if (options[@"sync-id"].length > 0) {
        NSInteger syncVersion = options[@"sync-version"].length > 0 ? [options[@"sync-version"] integerValue] : 1;
        metadata[HKMetadataKeySyncIdentifier] = options[@"sync-id"];
        metadata[HKMetadataKeySyncVersion] = @(MAX(syncVersion, 1));
    }
    if (options[@"note"].length > 0) {
        metadata[@"com.dj.Macrodex.note"] = options[@"note"];
    }
    if (![options[@"user-entered"] isEqualToString:@"false"]) {
        metadata[HKMetadataKeyWasUserEntered] = @YES;
    }
    return metadata;
}

static NSDictionary<NSString *, id> *codex_healthkit_save_object_blocking(HKObject *object, NSError **error) {
    HKHealthStore *store = codex_healthkit_store();
    if (store == nil) {
        if (error) *error = codex_macrodex_error(@"HealthKit is unavailable on this device");
        return nil;
    }
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block BOOL success = NO;
    __block NSError *saveError = nil;
    [store saveObject:object withCompletion:^(BOOL ok, NSError *err) {
        success = ok;
        saveError = err;
        dispatch_semaphore_signal(sema);
    }];
    long wait = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)));
    if (wait != 0) {
        if (error) *error = codex_macrodex_error(@"Timed out saving HealthKit object");
        return nil;
    }
    if (!success) {
        if (error) *error = saveError ?: codex_macrodex_error(@"Failed to save HealthKit object");
        return nil;
    }
    return @{@"ok": @YES, @"uuid": object.UUID.UUIDString ?: @""};
}

typedef void (^CodexHealthKitBoolCompletion)(BOOL success, NSError *error);
typedef void (^CodexHealthKitBoolOperation)(CodexHealthKitBoolCompletion completion);

static BOOL codex_healthkit_wait_bool_operation(CodexHealthKitBoolOperation operation, NSString *timeoutMessage, NSError **error) {
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block BOOL success = NO;
    __block NSError *operationError = nil;
    operation(^(BOOL ok, NSError *err) {
        success = ok;
        operationError = err;
        dispatch_semaphore_signal(sema);
    });
    long wait = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)));
    if (wait != 0) {
        if (error) *error = codex_macrodex_error(timeoutMessage ?: @"Timed out waiting for HealthKit operation");
        return NO;
    }
    if (!success) {
        if (error) *error = operationError ?: codex_macrodex_error(@"HealthKit operation failed");
        return NO;
    }
    return YES;
}

static HKWorkout *codex_healthkit_finish_workout_builder_blocking(HKWorkoutBuilder *builder, NSError **error) {
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block HKWorkout *workout = nil;
    __block NSError *operationError = nil;
    [builder finishWorkoutWithCompletion:^(HKWorkout *result, NSError *err) {
        workout = result;
        operationError = err;
        dispatch_semaphore_signal(sema);
    }];
    long wait = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)));
    if (wait != 0) {
        if (error) *error = codex_macrodex_error(@"Timed out finishing HealthKit workout");
        return nil;
    }
    if (workout == nil) {
        if (error) *error = operationError ?: codex_macrodex_error(@"HealthKit saved the workout but did not return a workout object");
        return nil;
    }
    return workout;
}

static NSDictionary<NSString *, id> *codex_healthkit_save_workout_blocking(HKWorkoutActivityType activity, NSDate *start, NSDate *end, HKQuantity *energy, HKQuantity *distance, NSDictionary<NSString *, id> *metadata, NSError **error) {
    HKHealthStore *store = codex_healthkit_store();
    if (store == nil) {
        if (error) *error = codex_macrodex_error(@"HealthKit is unavailable on this device");
        return nil;
    }

    HKWorkoutConfiguration *configuration = [[HKWorkoutConfiguration alloc] init];
    configuration.activityType = activity;
    configuration.locationType = HKWorkoutSessionLocationTypeUnknown;

    HKWorkoutBuilder *builder = [[HKWorkoutBuilder alloc] initWithHealthStore:store configuration:configuration device:nil];
    if (!codex_healthkit_wait_bool_operation(^(CodexHealthKitBoolCompletion completion) {
        [builder beginCollectionWithStartDate:start completion:completion];
    }, @"Timed out starting HealthKit workout", error)) {
        [builder discardWorkout];
        return nil;
    }

    if (metadata.count > 0 && !codex_healthkit_wait_bool_operation(^(CodexHealthKitBoolCompletion completion) {
        [builder addMetadata:metadata completion:completion];
    }, @"Timed out adding HealthKit workout metadata", error)) {
        [builder discardWorkout];
        return nil;
    }

    NSMutableArray<HKSample *> *samples = [NSMutableArray array];
    if (energy != nil) {
        HKQuantityType *energyType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierActiveEnergyBurned];
        if (energyType != nil) {
            [samples addObject:[HKQuantitySample quantitySampleWithType:energyType quantity:energy startDate:start endDate:end metadata:metadata]];
        }
    }
    if (distance != nil) {
        HKQuantityTypeIdentifier distanceIdentifier = codex_healthkit_distance_identifier_for_activity(activity);
        HKQuantityType *distanceType = [HKQuantityType quantityTypeForIdentifier:distanceIdentifier];
        if (distanceType != nil) {
            [samples addObject:[HKQuantitySample quantitySampleWithType:distanceType quantity:distance startDate:start endDate:end metadata:metadata]];
        }
    }
    if (samples.count > 0 && !codex_healthkit_wait_bool_operation(^(CodexHealthKitBoolCompletion completion) {
        [builder addSamples:samples completion:completion];
    }, @"Timed out adding HealthKit workout samples", error)) {
        [builder discardWorkout];
        return nil;
    }

    if (!codex_healthkit_wait_bool_operation(^(CodexHealthKitBoolCompletion completion) {
        [builder endCollectionWithEndDate:end completion:completion];
    }, @"Timed out ending HealthKit workout", error)) {
        [builder discardWorkout];
        return nil;
    }

    HKWorkout *workout = codex_healthkit_finish_workout_builder_blocking(builder, error);
    if (workout == nil) {
        [builder discardWorkout];
        return nil;
    }
    return @{@"ok": @YES, @"uuid": workout.UUID.UUIDString ?: @""};
}

static NSArray<NSDictionary<NSString *, NSString *> *> *codex_healthkit_nutrition_sync_catalog(void) {
    return @[
        @{@"key": @"calories_kcal", @"label": @"Dietary energy", @"identifier": HKQuantityTypeIdentifierDietaryEnergyConsumed, @"unit": @"kcal"},
        @{@"key": @"protein_g", @"label": @"Protein", @"identifier": HKQuantityTypeIdentifierDietaryProtein, @"unit": @"g"},
        @{@"key": @"carbs_g", @"label": @"Carbohydrates", @"identifier": HKQuantityTypeIdentifierDietaryCarbohydrates, @"unit": @"g"},
        @{@"key": @"fat_g", @"label": @"Total fat", @"identifier": HKQuantityTypeIdentifierDietaryFatTotal, @"unit": @"g"},
        @{@"key": @"fiber_g", @"label": @"Fiber", @"identifier": HKQuantityTypeIdentifierDietaryFiber, @"unit": @"g"},
        @{@"key": @"sugars_g", @"label": @"Sugars", @"identifier": HKQuantityTypeIdentifierDietarySugar, @"unit": @"g"},
        @{@"key": @"saturated_fat_g", @"label": @"Saturated fat", @"identifier": HKQuantityTypeIdentifierDietaryFatSaturated, @"unit": @"g"},
        @{@"key": @"cholesterol_mg", @"label": @"Cholesterol", @"identifier": HKQuantityTypeIdentifierDietaryCholesterol, @"unit": @"mg"},
        @{@"key": @"sodium_mg", @"label": @"Sodium", @"identifier": HKQuantityTypeIdentifierDietarySodium, @"unit": @"mg"},
        @{@"key": @"potassium_mg", @"label": @"Potassium", @"identifier": HKQuantityTypeIdentifierDietaryPotassium, @"unit": @"mg"},
        @{@"key": @"calcium_mg", @"label": @"Calcium", @"identifier": HKQuantityTypeIdentifierDietaryCalcium, @"unit": @"mg"},
        @{@"key": @"iron_mg", @"label": @"Iron", @"identifier": HKQuantityTypeIdentifierDietaryIron, @"unit": @"mg"},
        @{@"key": @"vitamin_d_mcg", @"label": @"Vitamin D", @"identifier": HKQuantityTypeIdentifierDietaryVitaminD, @"unit": @"mcg"},
        @{@"key": @"caffeine_mg", @"label": @"Caffeine", @"identifier": HKQuantityTypeIdentifierDietaryCaffeine, @"unit": @"mg"},
    ];
}

static NSString *codex_healthkit_sql_escape(NSString *value) {
    return [value ?: @"" stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
}

static NSDateFormatter *codex_healthkit_day_formatter(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.calendar = [NSCalendar currentCalendar];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd";
    return formatter;
}

static NSString *codex_healthkit_day_key(NSDate *date) {
    return [codex_healthkit_day_formatter() stringFromDate:codex_healthkit_start_of_day(date ?: [NSDate date])];
}

static NSDate *codex_healthkit_date_from_day_key(NSString *dateKey) {
    return [codex_healthkit_day_formatter() dateFromString:dateKey ?: @""];
}

static NSString *codex_healthkit_normalized_day_key(NSString *dateKey) {
    NSString *trimmed = [dateKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return codex_healthkit_day_key([NSDate date]);
    }
    NSDate *date = [codex_healthkit_day_formatter() dateFromString:trimmed];
    return date != nil ? codex_healthkit_day_key(date) : nil;
}

static NSString *codex_healthkit_nutrition_sync_state_key(NSString *dateKey, NSString *nutrientKey) {
    return [NSString stringWithFormat:@"healthkit.nutrition.sync.%@.%@", dateKey ?: @"", nutrientKey ?: @""];
}

static NSString *codex_healthkit_nutrition_sync_identifier(NSString *dateKey, NSString *nutrientKey) {
    return [NSString stringWithFormat:@"com.dj.Macrodex.nutrition.%@.%@", dateKey ?: @"", nutrientKey ?: @""];
}

static NSInteger codex_healthkit_stored_nutrition_sync_version(NSString *dateKey, NSString *nutrientKey) {
    NSString *stateKey = codex_healthkit_sql_escape(codex_healthkit_nutrition_sync_state_key(dateKey, nutrientKey));
    NSError *error = nil;
    NSArray *rows = codex_macrodex_sql_perform([NSString stringWithFormat:@"SELECT value FROM schema_metadata WHERE key = '%@' LIMIT 1", stateKey], &error);
    if (error != nil || ![rows isKindOfClass:[NSArray class]] || rows.count == 0) {
        return NSNotFound;
    }
    id value = rows.firstObject[@"value"];
    return [[value description] integerValue];
}

static void codex_healthkit_mark_nutrition_sync_version(NSString *dateKey, NSString *nutrientKey, NSInteger version) {
    NSString *stateKey = codex_healthkit_sql_escape(codex_healthkit_nutrition_sync_state_key(dateKey, nutrientKey));
    NSString *value = codex_healthkit_sql_escape([NSString stringWithFormat:@"%ld", (long)MAX(version, 1)]);
    NSTimeInterval nowMs = [[NSDate date] timeIntervalSince1970] * 1000.0;
    NSString *sql = [NSString stringWithFormat:
        @"INSERT INTO schema_metadata (key, value, updated_at_ms) VALUES ('%@', '%@', %.0f) "
         "ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at_ms = excluded.updated_at_ms",
        stateKey,
        value,
        nowMs
    ];
    codex_macrodex_sql_perform(sql, nil);
}

static NSInteger codex_healthkit_nutrition_day_version(NSString *dateKey, NSError **error) {
    NSString *escapedDate = codex_healthkit_sql_escape(dateKey);
    NSString *sql = [NSString stringWithFormat:
        @"SELECT MAX(version) AS version FROM ("
         "SELECT COALESCE(MAX(updated_at_ms), 0) AS version FROM food_log_items WHERE log_date = '%@' "
         "UNION ALL "
         "SELECT COALESCE(MAX(flin.updated_at_ms), 0) AS version "
         "FROM food_log_item_nutrients flin "
         "JOIN food_log_items fli ON fli.id = flin.log_item_id "
         "WHERE fli.log_date = '%@'"
         ")",
        escapedDate,
        escapedDate
    ];
    NSArray *rows = codex_macrodex_sql_perform(sql, error);
    if (![rows isKindOfClass:[NSArray class]] || rows.count == 0) {
        return 0;
    }
    id version = rows.firstObject[@"version"];
    return version == (id)kCFNull ? 0 : MAX(0, [[version description] integerValue]);
}

static NSDictionary<NSString *, NSNumber *> *codex_healthkit_nutrition_amounts_for_day(NSString *dateKey, NSError **error) {
    NSString *escapedDate = codex_healthkit_sql_escape(dateKey);
    NSString *coreSQL = [NSString stringWithFormat:
        @"SELECT "
         "COALESCE(SUM(calories_kcal), 0) AS calories_kcal, "
         "COALESCE(SUM(COALESCE(protein_g, 0)), 0) AS protein_g, "
         "COALESCE(SUM(COALESCE(carbs_g, 0)), 0) AS carbs_g, "
         "COALESCE(SUM(COALESCE(fat_g, 0)), 0) AS fat_g "
         "FROM food_log_items WHERE log_date = '%@' AND deleted_at_ms IS NULL",
        escapedDate
    ];
    NSArray *coreRows = codex_macrodex_sql_perform(coreSQL, error);
    if (![coreRows isKindOfClass:[NSArray class]]) {
        return nil;
    }

    NSMutableDictionary<NSString *, NSNumber *> *amounts = [NSMutableDictionary dictionary];
    NSDictionary *core = coreRows.firstObject ?: @{};
    for (NSString *key in @[@"calories_kcal", @"protein_g", @"carbs_g", @"fat_g"]) {
        id value = core[key];
        amounts[key] = value == (id)kCFNull || value == nil ? @0 : @([value doubleValue]);
    }

    NSString *optionalSQL = [NSString stringWithFormat:
        @"SELECT flin.nutrient_key, COALESCE(SUM(flin.amount), 0) AS amount "
         "FROM food_log_item_nutrients flin "
         "JOIN food_log_items fli ON fli.id = flin.log_item_id "
         "WHERE fli.log_date = '%@' AND fli.deleted_at_ms IS NULL AND flin.deleted_at_ms IS NULL "
         "GROUP BY flin.nutrient_key",
        escapedDate
    ];
    NSArray *optionalRows = codex_macrodex_sql_perform(optionalSQL, error);
    if (![optionalRows isKindOfClass:[NSArray class]]) {
        return nil;
    }
    for (NSDictionary *row in optionalRows) {
        NSString *key = [row[@"nutrient_key"] description];
        if (key.length == 0) continue;
        id amount = row[@"amount"];
        amounts[key] = amount == (id)kCFNull || amount == nil ? @0 : @([amount doubleValue]);
    }
    return amounts;
}

static BOOL codex_healthkit_delete_nutrition_sync_sample(HKQuantityType *type, NSString *syncIdentifier, NSUInteger *deletedCount, NSError **error) {
    HKHealthStore *store = codex_healthkit_store();
    if (store == nil) {
        if (error) *error = codex_macrodex_error(@"HealthKit is unavailable on this device");
        return NO;
    }
    NSPredicate *predicate = [HKQuery predicateForObjectsWithMetadataKey:HKMetadataKeySyncIdentifier operatorType:NSEqualToPredicateOperatorType value:syncIdentifier];
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block BOOL success = NO;
    __block NSUInteger deleted = 0;
    __block NSError *deleteError = nil;
    [store deleteObjectsOfType:type predicate:predicate withCompletion:^(BOOL ok, NSUInteger count, NSError *err) {
        success = ok;
        deleted = count;
        deleteError = err;
        dispatch_semaphore_signal(sema);
    }];
    long wait = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)));
    if (wait != 0) {
        if (error) *error = codex_macrodex_error(@"Timed out deleting previous HealthKit nutrition sample");
        return NO;
    }
    if (!success) {
        if (error) *error = deleteError ?: codex_macrodex_error(@"Failed to delete previous HealthKit nutrition sample");
        return NO;
    }
    if (deletedCount != NULL) {
        *deletedCount = deleted;
    }
    return YES;
}

static NSDictionary<NSString *, id> *codex_healthkit_sync_nutrition_day(NSString *dateKey, BOOL force) {
    NSString *normalizedDateKey = codex_healthkit_normalized_day_key(dateKey);
    if (normalizedDateKey.length == 0) {
        return @{@"ok": @YES, @"skipped": @YES, @"reason": @"Invalid or missing date."};
    }

    NSString *databasePath = codex_macrodex_database_path();
    if (databasePath.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:databasePath]) {
        return @{@"ok": @YES, @"skipped": @YES, @"date": normalizedDateKey, @"reason": @"Macrodex nutrition database is not initialized yet."};
    }

    HKHealthStore *store = codex_healthkit_store();
    if (store == nil) {
        return @{@"ok": @YES, @"skipped": @YES, @"date": normalizedDateKey, @"info": @"HealthKit is not set up on this device, so Macrodex skipped Apple Health sync.", @"reason": @"HealthKit is unavailable on this device."};
    }

    NSError *databaseError = nil;
    NSInteger version = codex_healthkit_nutrition_day_version(normalizedDateKey, &databaseError);
    if (databaseError != nil) {
        return @{@"ok": @YES, @"skipped": @YES, @"date": normalizedDateKey, @"reason": databaseError.localizedDescription ?: @"Unable to read nutrition sync version."};
    }

    NSDictionary<NSString *, NSNumber *> *amounts = codex_healthkit_nutrition_amounts_for_day(normalizedDateKey, &databaseError);
    if (amounts == nil) {
        return @{@"ok": @YES, @"skipped": @YES, @"date": normalizedDateKey, @"reason": databaseError.localizedDescription ?: @"Unable to read nutrition totals."};
    }
    BOOL hasLoggedNutrition = NO;
    for (NSDictionary<NSString *, NSString *> *entry in codex_healthkit_nutrition_sync_catalog()) {
        if ([amounts[entry[@"key"]] doubleValue] > 0) {
            hasLoggedNutrition = YES;
            break;
        }
    }
    if (!force && version <= 0 && !hasLoggedNutrition) {
        return @{@"ok": @YES, @"skipped": @YES, @"date": normalizedDateKey, @"reason": @"No logged nutrition for this day."};
    }

    NSDate *start = codex_healthkit_date_from_day_key(normalizedDateKey);
    NSDate *end = [[NSCalendar currentCalendar] dateByAddingUnit:NSCalendarUnitDay value:1 toDate:start options:0];
    if (start == nil || end == nil) {
        return @{@"ok": @YES, @"skipped": @YES, @"date": normalizedDateKey, @"reason": @"Unable to resolve HealthKit sample dates."};
    }

    NSMutableArray<NSDictionary *> *saved = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *deleted = [NSMutableArray array];
    NSMutableArray<NSString *> *unchanged = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *skipped = [NSMutableArray array];

    for (NSDictionary<NSString *, NSString *> *entry in codex_healthkit_nutrition_sync_catalog()) {
        NSString *nutrientKey = entry[@"key"];
        NSString *label = entry[@"label"] ?: nutrientKey;
        NSString *identifier = entry[@"identifier"];
        NSString *unitName = entry[@"unit"];
        NSInteger storedVersion = codex_healthkit_stored_nutrition_sync_version(normalizedDateKey, nutrientKey);
        if (!force && storedVersion == version && version > 0) {
            [unchanged addObject:nutrientKey];
            continue;
        }

        HKQuantityType *type = [HKQuantityType quantityTypeForIdentifier:identifier];
        if (type == nil) {
            [skipped addObject:@{@"key": nutrientKey, @"label": label, @"reason": @"This Apple Health field is unsupported on this OS."}];
            continue;
        }
        if ([store authorizationStatusForType:type] != HKAuthorizationStatusSharingAuthorized) {
            [skipped addObject:@{@"key": nutrientKey, @"label": label, @"identifier": identifier, @"reason": @"Apple Health write access is not enabled for this field."}];
            continue;
        }

        NSString *syncIdentifier = codex_healthkit_nutrition_sync_identifier(normalizedDateKey, nutrientKey);
        double amount = [amounts[nutrientKey] doubleValue];
        if (force || amount <= 0) {
            NSError *deleteError = nil;
            NSUInteger deletedCount = 0;
            if (!codex_healthkit_delete_nutrition_sync_sample(type, syncIdentifier, &deletedCount, &deleteError)) {
                [skipped addObject:@{@"key": nutrientKey, @"label": label, @"identifier": identifier, @"reason": deleteError.localizedDescription ?: @"Failed to delete previous Apple Health sample."}];
                continue;
            }
            if (deletedCount > 0) {
                [deleted addObject:@{@"key": nutrientKey, @"label": label, @"identifier": identifier, @"count": @(deletedCount)}];
            }
            if (amount <= 0) {
                codex_healthkit_mark_nutrition_sync_version(normalizedDateKey, nutrientKey, version);
                continue;
            }
        }

        NSError *unitError = nil;
        HKUnit *unit = codex_healthkit_unit_from_string(unitName, identifier, &unitError);
        if (unit == nil) {
            [skipped addObject:@{@"key": nutrientKey, @"label": label, @"identifier": identifier, @"reason": unitError.localizedDescription ?: @"Invalid Apple Health unit."}];
            continue;
        }

        NSDictionary *metadata = @{
            HKMetadataKeySyncIdentifier: syncIdentifier,
            HKMetadataKeySyncVersion: @(MAX(version, 1)),
            HKMetadataKeyWasUserEntered: @YES,
            @"com.dj.Macrodex.syncKind": @"dailyNutrition",
            @"com.dj.Macrodex.nutritionDate": normalizedDateKey,
            @"com.dj.Macrodex.nutrientKey": nutrientKey,
        };
        HKQuantity *quantity = [HKQuantity quantityWithUnit:unit doubleValue:amount];
        HKQuantitySample *sample = [HKQuantitySample quantitySampleWithType:type quantity:quantity startDate:start endDate:end metadata:metadata];
        NSError *saveError = nil;
        NSDictionary *result = codex_healthkit_save_object_blocking(sample, &saveError);
        if (result == nil) {
            [skipped addObject:@{@"key": nutrientKey, @"label": label, @"identifier": identifier, @"reason": saveError.localizedDescription ?: @"Failed to save Apple Health sample."}];
            continue;
        }
        codex_healthkit_mark_nutrition_sync_version(normalizedDateKey, nutrientKey, version);
        [saved addObject:@{
            @"key": nutrientKey,
            @"label": label,
            @"identifier": identifier,
            @"value": @(amount),
            @"unit": unitName,
            @"uuid": result[@"uuid"] ?: @"",
        }];
    }

    return @{
        @"ok": @YES,
        @"date": normalizedDateKey,
        @"version": @(version),
        @"saved": saved,
        @"deleted": deleted,
        @"unchanged": unchanged,
        @"skipped": skipped,
        @"info": skipped.count > 0 ? @"Some Apple Health fields were skipped. Check skipped[].reason for setup or permission details." : @"Apple Health nutrition sync completed.",
    };
}

void codex_healthkit_sync_nutrition_day_async(NSString *dateKey) {
    NSString *dateKeyCopy = [dateKey copy];
    static dispatch_queue_t nutritionSyncQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        nutritionSyncQueue = dispatch_queue_create("com.dj.Macrodex.healthkit-nutrition-sync", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(nutritionSyncQueue, ^{
        @autoreleasepool {
            (void)codex_healthkit_sync_nutrition_day(dateKeyCopy, NO);
        }
    });
}

static NSArray<NSString *> *codex_healthkit_sync_nutrition_date_keys(NSDictionary<NSString *, NSString *> *options, NSError **error) {
    NSMutableArray<NSString *> *dateKeys = [NSMutableArray array];
    if (options[@"date"].length > 0) {
        NSDate *date = codex_healthkit_parse_date(options[@"date"], NO, error);
        if (date == nil) return nil;
        return @[codex_healthkit_day_key(date)];
    }

    if (options[@"start"].length > 0 || options[@"end"].length > 0) {
        NSDate *start = options[@"start"].length > 0 ? codex_healthkit_parse_date(options[@"start"], NO, error) : codex_healthkit_start_of_day([NSDate date]);
        if (start == nil) return nil;
        NSDate *end = options[@"end"].length > 0 ? codex_healthkit_parse_date(options[@"end"], NO, error) : start;
        if (end == nil) return nil;
        NSDate *cursor = codex_healthkit_start_of_day(start);
        NSDate *last = codex_healthkit_start_of_day(end);
        NSCalendar *calendar = [NSCalendar currentCalendar];
        NSUInteger count = 0;
        while ([cursor compare:last] != NSOrderedDescending && count < 731) {
            [dateKeys addObject:codex_healthkit_day_key(cursor)];
            cursor = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:cursor options:0];
            count++;
        }
        return dateKeys;
    }

    NSInteger days = options[@"days"].length > 0 ? MAX(1, MIN(731, [options[@"days"] integerValue])) : 1;
    NSDate *today = codex_healthkit_start_of_day([NSDate date]);
    NSCalendar *calendar = [NSCalendar currentCalendar];
    for (NSInteger offset = days - 1; offset >= 0; offset--) {
        NSDate *date = [calendar dateByAddingUnit:NSCalendarUnitDay value:-offset toDate:today options:0];
        [dateKeys addObject:codex_healthkit_day_key(date)];
    }
    return dateKeys;
}

static int codex_healthkit_sync_nutrition(NSDictionary<NSString *, NSString *> *options, NSString *cwd, char **output, size_t *output_len) {
    NSError *error = nil;
    NSArray<NSString *> *dateKeys = codex_healthkit_sync_nutrition_date_keys(options, &error);
    if (dateKeys == nil) {
        return codex_healthkit_emit_json(@{
            @"ok": @NO,
            @"skipped": @YES,
            @"reason": error.localizedDescription ?: @"Unable to resolve sync dates.",
        }, options, cwd, output, output_len);
    }

    BOOL force = [options[@"force"] isEqualToString:@"true"] || [options[@"force"] isEqualToString:@"1"];
    NSMutableArray<NSDictionary *> *days = [NSMutableArray arrayWithCapacity:dateKeys.count];
    for (NSString *dateKey in dateKeys) {
        [days addObject:codex_healthkit_sync_nutrition_day(dateKey, force)];
    }
    return codex_healthkit_emit_json(@{
        @"ok": @YES,
        @"command": @"sync-nutrition",
        @"force": @(force),
        @"count": @(days.count),
        @"days": days,
    }, options, cwd, output, output_len);
}

static int codex_healthkit_write_quantity(NSDictionary<NSString *, NSString *> *options, NSString *cwd, char **output, size_t *output_len) {
    NSError *error = nil;
    HKQuantityType *type = codex_healthkit_quantity_type(options[@"identifier"], &error);
    if (type == nil) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    if (!codex_healthkit_sample_type_can_share(type)) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@ is read-only for Macrodex\n", type.identifier ?: options[@"identifier"] ?: @"type"], output, output_len);
        return 1;
    }
    if (options[@"value"].length == 0) {
        codex_ios_set_output(@"healthkit: --value is required\n", output, output_len);
        return 1;
    }
    NSDate *start = nil;
    NSDate *end = nil;
    if (!codex_healthkit_resolve_interval(options, 0, YES, &start, &end, &error)) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    NSString *unitName = options[@"unit"].length > 0 ? options[@"unit"] : codex_healthkit_default_unit_string(type.identifier);
    HKUnit *unit = codex_healthkit_unit_from_string(unitName, type.identifier, &error);
    if (unit == nil) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    NSDictionary *metadata = codex_healthkit_metadata_from_options(options, &error);
    if (metadata == nil) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    HKQuantity *quantity = [HKQuantity quantityWithUnit:unit doubleValue:[options[@"value"] doubleValue]];
    HKQuantitySample *sample = [HKQuantitySample quantitySampleWithType:type quantity:quantity startDate:start endDate:end metadata:metadata];
    NSDictionary *result = codex_healthkit_save_object_blocking(sample, &error);
    if (result == nil) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    NSMutableDictionary *payload = [result mutableCopy];
    payload[@"type"] = @"quantity";
    payload[@"identifier"] = type.identifier ?: @"";
    payload[@"value"] = @([options[@"value"] doubleValue]);
    payload[@"unit"] = unitName;
    payload[@"startDate"] = codex_healthkit_iso_string(start) ?: @"";
    payload[@"endDate"] = codex_healthkit_iso_string(end) ?: @"";
    return codex_healthkit_emit_json(payload, options, cwd, output, output_len);
}

static int codex_healthkit_write_category(NSDictionary<NSString *, NSString *> *options, NSString *cwd, char **output, size_t *output_len) {
    NSError *error = nil;
    HKCategoryType *type = codex_healthkit_category_type(options[@"identifier"], &error);
    if (type == nil) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    if (!codex_healthkit_sample_type_can_share(type)) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@ is read-only for Macrodex\n", type.identifier ?: options[@"identifier"] ?: @"type"], output, output_len);
        return 1;
    }
    NSDate *start = nil;
    NSDate *end = nil;
    if (!codex_healthkit_resolve_interval(options, 0, YES, &start, &end, &error)) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    NSInteger value = codex_healthkit_category_value(type.identifier, options[@"value"], &error);
    if (value == NSNotFound) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    NSDictionary *metadata = codex_healthkit_metadata_from_options(options, &error);
    if (metadata == nil) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    HKCategorySample *sample = [HKCategorySample categorySampleWithType:type value:value startDate:start endDate:end metadata:metadata];
    NSDictionary *result = codex_healthkit_save_object_blocking(sample, &error);
    if (result == nil) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    NSMutableDictionary *payload = [result mutableCopy];
    payload[@"type"] = @"category";
    payload[@"identifier"] = type.identifier ?: @"";
    payload[@"value"] = @(value);
    payload[@"valueName"] = codex_healthkit_category_value_name(type.identifier, value);
    payload[@"startDate"] = codex_healthkit_iso_string(start) ?: @"";
    payload[@"endDate"] = codex_healthkit_iso_string(end) ?: @"";
    return codex_healthkit_emit_json(payload, options, cwd, output, output_len);
}

static int codex_healthkit_write_workout(NSDictionary<NSString *, NSString *> *options, NSString *cwd, char **output, size_t *output_len) {
    NSError *error = nil;
    NSDate *start = nil;
    NSDate *end = nil;
    if (!codex_healthkit_resolve_interval(options, 0, YES, &start, &end, &error)) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    HKWorkoutActivityType activity = codex_healthkit_workout_activity_type(options[@"activity"] ?: @"other", &error);
    if (error != nil) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    HKQuantity *energy = options[@"energy"].length > 0
        ? [HKQuantity quantityWithUnit:[HKUnit kilocalorieUnit] doubleValue:[options[@"energy"] doubleValue]]
        : nil;
    HKQuantity *distance = options[@"distance"].length > 0
        ? [HKQuantity quantityWithUnit:[HKUnit meterUnit] doubleValue:[options[@"distance"] doubleValue]]
        : nil;
    NSDictionary *metadata = codex_healthkit_metadata_from_options(options, &error);
    if (metadata == nil) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    NSTimeInterval duration = options[@"duration"].length > 0 ? [options[@"duration"] doubleValue] : [end timeIntervalSinceDate:start];
    NSDictionary *result = codex_healthkit_save_workout_blocking(activity, start, end, energy, distance, metadata, &error);
    if (result == nil) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
        return 1;
    }
    NSMutableDictionary *payload = [result mutableCopy];
    payload[@"type"] = @"workout";
    payload[@"activityType"] = @(activity);
    payload[@"activityName"] = codex_healthkit_workout_activity_name(activity);
    payload[@"startDate"] = codex_healthkit_iso_string(start) ?: @"";
    payload[@"endDate"] = codex_healthkit_iso_string(end) ?: @"";
    payload[@"durationSeconds"] = @(duration);
    if (energy != nil) payload[@"totalEnergyBurnedKcal"] = @([energy doubleValueForUnit:[HKUnit kilocalorieUnit]]);
    if (distance != nil) payload[@"totalDistanceMeters"] = @([distance doubleValueForUnit:[HKUnit meterUnit]]);
    return codex_healthkit_emit_json(payload, options, cwd, output, output_len);
}

static NSString *codex_healthkit_biological_sex_name(HKBiologicalSex value) {
    switch (value) {
        case HKBiologicalSexFemale: return @"female";
        case HKBiologicalSexMale: return @"male";
        case HKBiologicalSexOther: return @"other";
        case HKBiologicalSexNotSet:
        default: return @"notSet";
    }
}

static NSString *codex_healthkit_blood_type_name(HKBloodType value) {
    switch (value) {
        case HKBloodTypeAPositive: return @"A+";
        case HKBloodTypeANegative: return @"A-";
        case HKBloodTypeBPositive: return @"B+";
        case HKBloodTypeBNegative: return @"B-";
        case HKBloodTypeABPositive: return @"AB+";
        case HKBloodTypeABNegative: return @"AB-";
        case HKBloodTypeOPositive: return @"O+";
        case HKBloodTypeONegative: return @"O-";
        case HKBloodTypeNotSet:
        default: return @"notSet";
    }
}

static NSString *codex_healthkit_wheelchair_use_name(HKWheelchairUse value) {
    switch (value) {
        case HKWheelchairUseNo: return @"no";
        case HKWheelchairUseYes: return @"yes";
        case HKWheelchairUseNotSet:
        default: return @"notSet";
    }
}

static int codex_healthkit_characteristics(NSDictionary<NSString *, NSString *> *options, NSString *cwd, char **output, size_t *output_len) {
    HKHealthStore *store = codex_healthkit_store();
    if (store == nil) {
        codex_ios_set_output(@"healthkit: HealthKit is unavailable on this device\n", output, output_len);
        return 1;
    }
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    NSError *error = nil;
    NSDateComponents *birth = [store dateOfBirthComponentsWithError:&error];
    if (birth != nil) {
        payload[@"dateOfBirthComponents"] = @{
            @"year": birth.year == NSDateComponentUndefined ? [NSNull null] : @(birth.year),
            @"month": birth.month == NSDateComponentUndefined ? [NSNull null] : @(birth.month),
            @"day": birth.day == NSDateComponentUndefined ? [NSNull null] : @(birth.day),
        };
    }
    error = nil;
    HKBiologicalSexObject *sex = [store biologicalSexWithError:&error];
    if (sex != nil) payload[@"biologicalSex"] = codex_healthkit_biological_sex_name(sex.biologicalSex);
    error = nil;
    HKBloodTypeObject *blood = [store bloodTypeWithError:&error];
    if (blood != nil) payload[@"bloodType"] = codex_healthkit_blood_type_name(blood.bloodType);
    error = nil;
    HKWheelchairUseObject *wheelchair = [store wheelchairUseWithError:&error];
    if (wheelchair != nil) payload[@"wheelchairUse"] = codex_healthkit_wheelchair_use_name(wheelchair.wheelchairUse);
    payload[@"readAuthorizationNote"] = @"If a characteristic is missing, it may be unset or read access may not be granted.";
    return codex_healthkit_emit_json(payload, options, cwd, output, output_len);
}

static int codex_healthkit_types(NSDictionary<NSString *, NSString *> *options, NSString *cwd, char **output, size_t *output_len) {
    return codex_healthkit_emit_json(@{
        @"quantities": codex_healthkit_quantity_catalog(),
        @"categories": codex_healthkit_category_catalog(),
        @"workouts": codex_healthkit_workout_catalog(),
        @"rawIdentifiers": @{
            @"quantity": @"Any valid HKQuantityTypeIdentifier... string can be used with --identifier.",
            @"category": @"Any valid HKCategoryTypeIdentifier... string can be used with --identifier.",
        },
    }, options, cwd, output, output_len);
}

static int codex_healthkit_run(NSArray<NSString *> *args, const char *cwd, char **output, size_t *output_len) {
    NSString *cwdString = cwd != NULL && cwd[0] != '\0' ? [NSString stringWithUTF8String:cwd] : codex_ios_default_cwd();
    if (args.count == 0 || [args.firstObject isEqualToString:@"help"] || [args.firstObject isEqualToString:@"--help"] || [args.firstObject isEqualToString:@"-h"]) {
        codex_ios_set_output(codex_healthkit_help_text(), output, output_len);
        return 0;
    }

    NSString *command = [args.firstObject lowercaseString];
    NSError *parseError = nil;
    NSMutableArray<NSString *> *positionals = nil;
    NSDictionary<NSString *, NSString *> *options = codex_healthkit_parse_options(args, 1, &positionals, &parseError);
    if (options == nil) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", parseError.localizedDescription], output, output_len);
        return 2;
    }
    if ([options[@"help"] isEqualToString:@"true"]) {
        codex_ios_set_output(codex_healthkit_help_text(), output, output_len);
        return 0;
    }

    if ([command isEqualToString:@"status"]) {
        return codex_healthkit_emit_json(codex_healthkit_status_object(), options, cwdString, output, output_len);
    }
    if ([command isEqualToString:@"request"]) {
        NSError *error = nil;
        NSDictionary *result = codex_healthkit_request_blocking(options, &error);
        if (result == nil) {
            codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", error.localizedDescription], output, output_len);
            return 1;
        }
        return codex_healthkit_emit_json(result, options, cwdString, output, output_len);
    }
    if ([command isEqualToString:@"types"]) {
        return codex_healthkit_types(options, cwdString, output, output_len);
    }
    if ([command isEqualToString:@"characteristics"] || [command isEqualToString:@"profile"]) {
        return codex_healthkit_characteristics(options, cwdString, output, output_len);
    }
    if ([command isEqualToString:@"query"]) {
        return codex_healthkit_query(options, cwdString, output, output_len);
    }
    if ([command isEqualToString:@"stats"] || [command isEqualToString:@"statistics"]) {
        return codex_healthkit_stats(options, cwdString, output, output_len);
    }
    if ([command isEqualToString:@"sync-nutrition"] || [command isEqualToString:@"sync-macros"] || [command isEqualToString:@"sync-dietary"]) {
        return codex_healthkit_sync_nutrition(options, cwdString, output, output_len);
    }
    if ([command isEqualToString:@"write-quantity"] || [command isEqualToString:@"save-quantity"]) {
        return codex_healthkit_write_quantity(options, cwdString, output, output_len);
    }
    if ([command isEqualToString:@"write-category"] || [command isEqualToString:@"save-category"]) {
        return codex_healthkit_write_category(options, cwdString, output, output_len);
    }
    if ([command isEqualToString:@"write-workout"] || [command isEqualToString:@"save-workout"]) {
        return codex_healthkit_write_workout(options, cwdString, output, output_len);
    }

    codex_ios_set_output([NSString stringWithFormat:@"healthkit: unknown command '%@'\n%@", args.firstObject, codex_healthkit_help_text()], output, output_len);
    return 2;
}

int healthkit_main(int argc, char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(argc - 1, 0)];
        for (int index = 1; index < argc; index++) {
            [args addObject:[NSString stringWithUTF8String:argv[index]]];
        }
        char cwdBuffer[PATH_MAX];
        NSString *cwd = getcwd(cwdBuffer, sizeof(cwdBuffer)) != NULL ? [NSString stringWithUTF8String:cwdBuffer] : codex_ios_default_cwd();
        char *output = NULL;
        size_t outputLen = 0;
        int code = codex_healthkit_run(args, cwd.UTF8String, &output, &outputLen);
        if (output != NULL && outputLen > 0) {
            fwrite(output, 1, outputLen, stdout);
            free(output);
        }
        return code;
    }
}

static int codex_macrodex_jsc_run(NSArray<NSString *> *args, const char *cwd, char **output, size_t *output_len) {
    NSMutableString *buffer = [NSMutableString string];
    NSString *cwdString = cwd != NULL && cwd[0] != '\0' ? [NSString stringWithUTF8String:cwd] : codex_ios_default_cwd();
    int code = codex_macrodex_jsc_run_args(args, cwdString, buffer);
    codex_ios_set_output(buffer, output, output_len);
    return code;
}

int jsc_main(int argc, char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(argc - 1, 0)];
        for (int index = 1; index < argc; index++) {
            [args addObject:[NSString stringWithUTF8String:argv[index]]];
        }
        char cwdBuffer[PATH_MAX];
        NSString *cwd = getcwd(cwdBuffer, sizeof(cwdBuffer)) != NULL ? [NSString stringWithUTF8String:cwdBuffer] : codex_ios_default_cwd();
        return codex_macrodex_jsc_run_args(args, cwd, nil);
    }
}

static __attribute__((unused)) int codex_ios_host_spawn_run(const char *cmd, const char *cwd, char **output, size_t *output_len) {
    NSLog(@"[command-bridge] run cmd='%s' cwd='%s'", cmd, cwd ? cwd : "(null)");

    int pipefd[2] = {-1, -1};
    if (pipe(pipefd) != 0) {
        NSLog(@"[command-bridge] pipe FAILED errno=%d (%s)", errno, strerror(errno));
        return -1;
    }
    fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
    fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    posix_spawn_file_actions_addclose(&actions, pipefd[1]);

    NSString *scriptString = codex_ios_host_shell_script([NSString stringWithUTF8String:cmd]);
    const char *scriptArg = scriptString.UTF8String;
    const char *cwdArg = (cwd != NULL && cwd[0] != '\0') ? cwd : ".";
    const char *script = "cd \"$1\" && exec /bin/sh -c \"$2\"";
    char *const argv[] = {
        "sh",
        "-c",
        (char *)script,
        "sh",
        (char *)cwdArg,
        (char *)scriptArg,
        NULL
    };

    pid_t pid = 0;
    int spawnErr = posix_spawn(&pid, "/bin/sh", &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipefd[1]);

    if (spawnErr != 0) {
        close(pipefd[0]);
        NSLog(@"[command-bridge] posix_spawn FAILED errno=%d (%s)", spawnErr, strerror(spawnErr));
        return -1;
    }

    NSMutableData *data = [NSMutableData data];
    char chunk[4096];
    for (;;) {
        ssize_t count = read(pipefd[0], chunk, sizeof(chunk));
        if (count > 0) {
            [data appendBytes:chunk length:(NSUInteger)count];
            continue;
        }
        if (count == 0) {
            break;
        }
        if (errno == EINTR) {
            continue;
        }
        NSLog(@"[command-bridge] read FAILED errno=%d (%s)", errno, strerror(errno));
        break;
    }
    close(pipefd[0]);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            NSLog(@"[command-bridge] waitpid FAILED errno=%d (%s)", errno, strerror(errno));
            status = -1;
            break;
        }
    }

    int code = -1;
    if (status == -1) {
        code = -1;
    } else if (WIFEXITED(status)) {
        code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        code = 128 + WTERMSIG(status);
    }

    size_t total = data.length;
    char *buf = NULL;
    if (total > 0) {
        buf = malloc(total + 1);
        if (buf != NULL) {
            memcpy(buf, data.bytes, total);
        } else {
            total = 0;
        }
    }

    NSLog(@"[command-bridge] code=%d output_len=%zu for cmd='%s'", code, total, cmd);

    if (buf && total > 0) {
        buf[total] = '\0';
        *output = buf;
        *output_len = total;
    } else {
        free(buf);
    }

    return code;
}

/// Returns the default working directory for codex sessions (/home/codex inside the sandbox).
NSString *codex_ios_default_cwd(void) {
    NSString *root = codex_sandbox_root();
    if (!root) return nil;
    return [root stringByAppendingPathComponent:@"home/codex"];
}

void macrodex_command_bridge_init(void) {
    codex_sandbox_root();
}

int macrodex_command_bridge_run(const char *cmd, const char *cwd, char **output, size_t *output_len) {
    *output = NULL;
    *output_len = 0;

    NSString *normalizedCmd = codex_ios_normalize_shell_command(cmd);

    BOOL builtinHandled = NO;
    int builtinCode = codex_ios_run_embedded_builtin_if_needed(normalizedCmd, output, output_len, &builtinHandled);
    if (builtinHandled) {
        return builtinCode;
    }

    NSError *healthKitParseError = nil;
    NSArray<NSString *> *healthKitArgs = codex_healthkit_args_from_command(normalizedCmd, &healthKitParseError);
    if (healthKitParseError != nil) {
        codex_ios_set_output([NSString stringWithFormat:@"healthkit: %@\n", healthKitParseError.localizedDescription], output, output_len);
        return 2;
    }
    if (healthKitArgs != nil) {
        return codex_healthkit_run(healthKitArgs, cwd, output, output_len);
    }

    NSError *jscParseError = nil;
    NSArray<NSString *> *jscArgs = codex_macrodex_jsc_args_from_command(normalizedCmd, &jscParseError);
    if (jscParseError != nil) {
        codex_ios_set_output([NSString stringWithFormat:@"jsc: %@\n", jscParseError.localizedDescription], output, output_len);
        return 2;
    }
    if (jscArgs != nil) {
        return codex_macrodex_jsc_run(jscArgs, cwd, output, output_len);
    }

    NSString *macrodexSQL = codex_macrodex_sql_from_command(normalizedCmd);
    if (macrodexSQL != nil) {
        return codex_macrodex_sql_run(macrodexSQL, output, output_len);
    }

#if TARGET_OS_SIMULATOR
    const char *simRunCmd = normalizedCmd.UTF8String;
    if (cmd != NULL && strcmp(cmd, simRunCmd) != 0) {
        NSLog(@"[ios-system] normalized cmd from '%s' to '%s'", cmd, simRunCmd);
    }
    return codex_ios_host_spawn_run(simRunCmd, cwd, output, output_len);
#else
    codex_ios_set_output(@"Shell commands are not available in this Pi-only iOS build.\n", output, output_len);
    return 127;
#endif
}
