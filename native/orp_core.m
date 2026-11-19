#import <UIKit/UIKit.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdarg.h>
#include <time.h>
#include "orp_core.h"
#include "orp_charts.h"
#include "orp_engine.h"
#include "orp_hook.h"
#include "orp_il2cpp.h"
#include "orp_index.h"
#include "orp_patch_config.h"

NSString *const ORPResultNotification = @"ORPResultNotification";

extern void orp_ui_start(void);
extern void orp_ui_prompt_account(NSString *name, NSString *pw, NSString *(^done)(NSString *name, NSString *pw));

static orp_store *gStore;                 // only touched on gQ
static dispatch_queue_t gQ;
static volatile int gOverall = -1;        // total rating of the active account; -1 = not loaded yet
static dispatch_source_t gSyncTimer;
static NSString *gActive = @"";           // active local account; @"" = the game's built-in "Offline..." user
static NSObject *gLock;

NSString *orp_data_dir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        dir = [docs stringByAppendingPathComponent:@"OfflineRating"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return dir;
}

void orp_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char body[900];
    vsnprintf(body, sizeof body, fmt, ap);
    va_end(ap);
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    char ts[32];
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tmv);
    NSLog(@"[OfflineRating] %s", body);
    static dispatch_queue_t lq;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lq = dispatch_queue_create("orp.log", DISPATCH_QUEUE_SERIAL); });
    NSString *line = [NSString stringWithFormat:@"%s %s\n", ts, body];
    dispatch_async(lq, ^{
        NSString *path = [orp_data_dir() stringByAppendingPathComponent:@"log.txt"];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if ([attr fileSize] > 512 * 1024) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) { [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil]; h = [NSFileHandle fileHandleForWritingAtPath:path]; }
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    });
}

static NSString *constantsPath(void) { return [orp_data_dir() stringByAppendingPathComponent:@"constants.csv"]; }

static void writeConstantsTemplate(void) {
    NSString *p = constantsPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return;
    NSString *t =
        @"# Offline Rating - chart constants (D) added by you.\n"
        @"# One chart per line:  title,CLASS,constant\n"
        @"# CLASS is one of CASUAL NORMAL HARD MEGA GIGA TERA. Title must match the in-game title.\n"
        @"# These entries override the built-in table. Restart the game after editing.\n"
        @"# Example:\n"
        @"# My Song Title,MEGA,12.5\n";
    [t writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// ------------------------------------------------------------------ local accounts
// One SQLite file per account. The game's "Offline..." user keeps the original ratings.sqlite3.
// No password is stored or checked: the accounts only separate whose results are whose.
static NSString *activeName(void) { @synchronized (gLock) { return gActive; } }

static NSString *accountsDir(void) {
    NSString *d = [orp_data_dir() stringByAppendingPathComponent:@"accounts"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static NSString *accountHash(NSString *name) {
    const char *u = name.UTF8String;
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(u, (CC_LONG)strlen(u), md);
    NSMutableString *h = [NSMutableString string];
    for (int i = 0; i < 12; i++) [h appendFormat:@"%02x", md[i]];
    return h;
}

static NSString *dbPathFor(NSString *name) {
    if (!name.length) return [orp_data_dir() stringByAppendingPathComponent:@"ratings.sqlite3"];
    return [accountsDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"acc_%@.sqlite3", accountHash(name)]];
}

// ------------------------------------------------------------------ cover art
UIImage *orp_cover_for_path(NSString *rel) {
    if (!rel.length) return nil;
    if (!NSThread.isMainThread) { __block UIImage *r = nil; dispatch_sync(dispatch_get_main_queue(), ^{ r = orp_cover_for_path(rel); }); return r; }
    static NSCache<NSString *, UIImage *> *cache;
    static NSMutableSet<NSString *> *failed;
    static int loggedOk;
    if (!cache) { cache = [NSCache new]; cache.countLimit = 64; failed = [NSMutableSet set]; }
    UIImage *hit = [cache objectForKey:rel];
    if (hit) return hit;
    if ([failed containsObject:rel]) return nil;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSData *enc = [NSData dataWithContentsOfFile:[docs stringByAppendingPathComponent:rel]];
    if (!enc.length) { [failed addObject:rel]; orp_log("cover: file missing '%s'", rel.UTF8String); return nil; }
    size_t outLen = 0;
    unsigned char *dec = orp_il2cpp_decrypt_bytes(enc.bytes, enc.length, &outLen);
    UIImage *img = nil;
    if (dec) img = [UIImage imageWithData:[NSData dataWithBytesNoCopy:dec length:outLen freeWhenDone:YES]];
    if (!img) { [failed addObject:rel]; orp_log("cover: could not decode '%s' (%s)", rel.UTF8String, dec ? "not an image" : "decrypt failed"); return nil; }
    CGFloat maxSide = 360, k = MIN(1.0, maxSide / MAX(img.size.width, img.size.height));
    if (k < 1.0) {   // thumbnail only: keep memory small
        CGSize ns = CGSizeMake(floor(img.size.width * k), floor(img.size.height * k));
        UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat];
        f.scale = 1;
        UIImage *src = img;
        img = [[[UIGraphicsImageRenderer alloc] initWithSize:ns format:f] imageWithActions:^(UIGraphicsImageRendererContext *c) { [src drawInRect:CGRectMake(0, 0, ns.width, ns.height)]; }];
    }
    [cache setObject:img forKey:rel];
    if (loggedOk++ < 3) orp_log("cover: ok '%s' (%zu bytes encrypted, %zu decrypted, thumbnail %dx%d)", rel.UTF8String, (size_t)enc.length, outLen, (int)img.size.width, (int)img.size.height);
    return img;
}

// ---- registry: accounts.txt, one line per account:  idhash \t name \t salt \t passwordHash \t created
// salt/passwordHash are empty when the account has no password. The password is only ever stored as
// SHA-256(salt:password) with a random per-account salt (it protects against casual peeking, nothing more).
static NSMutableDictionary<NSString *, NSMutableDictionary *> *gReg;

static NSString *regPath(void) { return [orp_data_dir() stringByAppendingPathComponent:@"accounts.txt"]; }

static NSString *sha256hex(NSString *s) {
    const char *u = s.UTF8String;
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(u, (CC_LONG)strlen(u), md);
    NSMutableString *h = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [h appendFormat:@"%02x", md[i]];
    return h;
}
static NSString *pwHash(NSString *salt, NSString *pw) { return sha256hex([NSString stringWithFormat:@"%@:%@", salt, pw]); }

static void saveRegistryLocked(void) {   // caller holds gLock
    NSMutableString *out = [NSMutableString string];
    for (NSString *n in [gReg.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *r = gReg[n];
        [out appendFormat:@"%@\t%@\t%@\t%@\t%@\n", accountHash(n), n, r[@"salt"], r[@"hash"], r[@"created"]];
    }
    [out writeToFile:regPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void loadRegistryIfNeeded(void) {
    @synchronized (gLock) {
        if (gReg) return;
        gReg = [NSMutableDictionary dictionary];
        NSString *t = [NSString stringWithContentsOfFile:regPath() encoding:NSUTF8StringEncoding error:nil] ?: @"";
        for (NSString *line in [t componentsSeparatedByString:@"\n"]) {
            NSArray *c = [line componentsSeparatedByString:@"\t"];
            if (c.count < 2 || ![c[1] length]) continue;   // legacy lines have only idhash + name (= no password)
            gReg[c[1]] = [@{@"salt": c.count > 2 ? c[2] : @"", @"hash": c.count > 3 ? c[3] : @"", @"created": c.count > 4 ? c[4] : @"0"} mutableCopy];
        }
    }
}

static BOOL accountExists(NSString *n) { loadRegistryIfNeeded(); @synchronized (gLock) { return gReg[n] != nil; } }
static BOOL accountHasPassword(NSString *n) { loadRegistryIfNeeded(); @synchronized (gLock) { return [gReg[n][@"hash"] length] > 0; } }
static BOOL accountVerify(NSString *n, NSString *pw) {
    loadRegistryIfNeeded();
    @synchronized (gLock) {
        NSDictionary *r = gReg[n];
        if (!r) return NO;
        if (![r[@"hash"] length]) return YES;   // no password set: anything is accepted
        return [pwHash(r[@"salt"], pw ?: @"") isEqualToString:r[@"hash"]];
    }
}
static void accountSetPasswordLocked(NSMutableDictionary *r, NSString *pw) {
    if (pw.length) {
        NSString *salt = [NSString stringWithFormat:@"%08x%08x", arc4random(), arc4random()];
        r[@"salt"] = salt; r[@"hash"] = pwHash(salt, pw);
    } else { r[@"salt"] = @""; r[@"hash"] = @""; }
}
static void accountCreateRec(NSString *n, NSString *pw) {
    loadRegistryIfNeeded();
    @synchronized (gLock) {
        if (gReg[n]) return;
        NSMutableDictionary *r = [@{@"salt": @"", @"hash": @"", @"created": [NSString stringWithFormat:@"%ld", (long)time(NULL)]} mutableCopy];
        accountSetPasswordLocked(r, pw);
        gReg[n] = r;
        saveRegistryLocked();
    }
}

// Must run on gQ.
static void doActivate(NSString *name) {
    if (gStore && [activeName() isEqualToString:name]) return;
    if (gStore) { orp_store_close(gStore); gStore = NULL; }
    gStore = orp_store_open(dbPathFor(name).fileSystemRepresentation);
    @synchronized (gLock) { gActive = name; }
    gOverall = gStore ? orp_store_overall(gStore) : 0;
    if (name.length && !accountExists(name)) accountCreateRec(name, @"");   // accounts made by older versions
    [name writeToFile:[orp_data_dir() stringByAppendingPathComponent:@"active_account.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    orp_log("account: active = '%s' (%d plays, rating %d, db %s)", name.length ? name.UTF8String : "Offline...",
            gStore ? orp_store_play_count(gStore) : -1, gOverall, gStore ? "ok" : "FAILED");
}

// Callable from the game thread (never from gQ itself).
static void activateAccount(NSString *name) {
    dispatch_sync(gQ, ^{ doActivate(name); });
}

void orp_account_list_get(orp_account_list *out) {
    memset(out, 0, sizeof *out);
    loadRegistryIfNeeded();
    NSString *act = activeName();
    strlcpy(out->active, act.UTF8String, sizeof out->active);
    @synchronized (gLock) {
        out->activeHasPassword = act.length && [gReg[act][@"hash"] length] > 0;
        out->count = 1;   // items[0] = default account
        for (NSString *n in [gReg.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if (out->count >= 16) break;
            orp_account_item *it = &out->items[out->count++];
            strlcpy(it->name, n.UTF8String, sizeof it->name);
            it->hasPassword = [gReg[n][@"hash"] length] > 0;
        }
    }
}

int orp_account_switch(const char *name, const char *password, char *err, size_t cap) {
    NSString *n = name ? ([NSString stringWithUTF8String:name] ?: @"") : @"";
    NSString *p = password ? ([NSString stringWithUTF8String:password] ?: @"") : @"";
    if (n.length) {
        if (!accountExists(n)) { strlcpy(err, "账号不存在 · Unknown account", cap); return -1; }
        if (!accountVerify(n, p)) { strlcpy(err, "密码错误 · Wrong password", cap); return -1; }
    }
    activateAccount(n);
    orp_il2cpp_set_user_name(n.length ? n.UTF8String : "Offline...");
    if (gOverall >= 0) orp_il2cpp_set_user_r(gOverall);
    orp_log("account: switched to '%s'", n.length ? n.UTF8String : "Offline...");
    return 0;
}

int orp_account_change_password(const char *oldpw, const char *newpw, char *err, size_t cap) {
    NSString *act = activeName();
    NSString *o = oldpw ? ([NSString stringWithUTF8String:oldpw] ?: @"") : @"";
    NSString *nw = newpw ? ([NSString stringWithUTF8String:newpw] ?: @"") : @"";
    if (!act.length) { strlcpy(err, "默认离线账号不能设置密码 · The default offline account has no password", cap); return -1; }
    if (accountHasPassword(act) && !accountVerify(act, o)) { strlcpy(err, "当前密码不正确 · Current password is wrong", cap); return -1; }
    @synchronized (gLock) {
        NSMutableDictionary *r = gReg[act];
        if (!r) { strlcpy(err, "账号不存在 · Unknown account", cap); return -1; }
        accountSetPasswordLocked(r, nw);
        saveRegistryLocked();
    }
    orp_log("account: password %s for '%s'", nw.length ? "changed" : "removed", act.UTF8String);
    return 0;
}

// ------------------------------------------------------------------ seed files (synthetic plays)
// Documents/OfflineRating/seed.csv - TAB separated, one play per line:
//   account  uuid  CLASS  label  title  perfect  good  miss  score  bleed  mirror  played_at
// The plays are written into that account's database, flagged `synthetic`, then the file is renamed seed.csv.done.
// Documents/OfflineRating/seed_clear.txt - one account name per line ("*" = every account, "(default)" = the Offline... account):
// removes that account's synthetic plays, then the file is renamed seed_clear.txt.done.
static orp_store *storeForAccount(NSString *acct, NSMutableDictionary<NSString *, NSValue *> *temp) {   // gQ
    if ([acct isEqualToString:activeName()] && gStore) return gStore;
    NSValue *v = temp[acct];
    if (v) return (orp_store *)v.pointerValue;
    orp_store *st = orp_store_open(dbPathFor(acct).fileSystemRepresentation);
    if (st) temp[acct] = [NSValue valueWithPointer:st];
    return st;
}
static void closeTemp(NSMutableDictionary<NSString *, NSValue *> *temp) {
    for (NSValue *v in temp.allValues) orp_store_close((orp_store *)v.pointerValue);
    [temp removeAllObjects];
}
static void markDone(NSString *path) {
    NSString *done = [path stringByAppendingString:@".done"];
    [[NSFileManager defaultManager] removeItemAtPath:done error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:path toPath:done error:nil];
}

static void seedClearIfPresent(void) {   // gQ
    NSString *path = [orp_data_dir() stringByAppendingPathComponent:@"seed_clear.txt"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    loadRegistryIfNeeded();
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *l = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!l.length || [l hasPrefix:@"#"]) continue;
        if ([l isEqualToString:@"*"]) { [names addObject:@""]; @synchronized (gLock) { [names addObjectsFromArray:gReg.allKeys]; } }
        else [names addObject:[l isEqualToString:@"(default)"] ? @"" : l];
    }
    NSMutableDictionary<NSString *, NSValue *> *temp = [NSMutableDictionary dictionary];
    for (NSString *n in names) {
        orp_store *st = storeForAccount(n, temp);
        if (st) orp_log("seed: removed %d synthetic plays from '%s'", orp_store_delete_synthetic(st), n.length ? n.UTF8String : "Offline...");
    }
    closeTemp(temp);
    if (gStore) gOverall = orp_store_overall(gStore);
    markDone(path);
}

static void seedImportIfPresent(void) {   // gQ
    NSString *path = [orp_data_dir() stringByAppendingPathComponent:@"seed.csv"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    NSMutableDictionary<NSString *, NSValue *> *temp = [NSMutableDictionary dictionary];
    int imported = 0, skipped = 0;
    NSMutableSet<NSString *> *accts = [NSMutableSet set];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *l = [line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
        if (!l.length || [l hasPrefix:@"#"]) continue;
        NSArray<NSString *> *c = [l componentsSeparatedByString:@"\t"];
        if (c.count < 12) { skipped++; continue; }
        NSString *acct = c[0], *uuid = c[1], *cls = c[2], *label = c[3], *title = c[4];
        double d = orp_chart_constant(title.UTF8String, orp_class_index(cls.UTF8String));
        orp_store *st = d > 0 ? storeForAccount(acct, temp) : NULL;
        if (!st) { skipped++; continue; }
        if (acct.length && !accountExists(acct)) accountCreateRec(acct, @"");
        NSString *key = [NSString stringWithFormat:@"%@|%@", uuid, cls];
        if (orp_store_record_play_ex(st, key.UTF8String, title.UTF8String, label.UTF8String, d, c[8].intValue, c[5].intValue, c[6].intValue,
                                     c[7].intValue, c[9].intValue, c[10].intValue, 1, c[11].longLongValue, 1, NULL, NULL) == 0) { imported++; [accts addObject:acct]; }
        else skipped++;
    }
    closeTemp(temp);
    if (gStore) gOverall = orp_store_overall(gStore);
    markDone(path);
    orp_log("seed: imported %d synthetic plays into %lu account(s), %d skipped; active account rating is now %d",
            imported, (unsigned long)accts.count, skipped, gOverall);
}

// ------------------------------------------------------------------ startup / sync
static void installTick(int n) {
    int r = orp_hook_install();
    if (r == 0 && n < 2400) {  // up to ~10 minutes
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ installTick(n + 1); });
    } else if (r == 0) {
        orp_log("hook: gave up waiting for UnityFramework");
    }
}

void orp_core_start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLock = [NSObject new];
        gQ = dispatch_queue_create("orp.core", DISPATCH_QUEUE_SERIAL);
        dispatch_async(gQ, ^{
            writeConstantsTemplate();
            NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            orp_index_set_path([docs stringByAppendingPathComponent:@"__rena_index_2"].fileSystemRepresentation);
            NSString *saved = [[NSString stringWithContentsOfFile:[orp_data_dir() stringByAppendingPathComponent:@"active_account.txt"]
                                                         encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
            doActivate(saved);
            int n = orp_charts_load_overrides(constantsPath().fileSystemRepresentation);
            seedClearIfPresent();
            seedImportIfPresent();
            orp_log("core: started, %d user constants, %d built-in", n, orp_charts_builtin_count());
        });
        dispatch_async(dispatch_get_main_queue(), ^{ installTick(0); });
        // Keep the game's own player name + R in sync with the active account, so its screens show them.
        gSyncTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(gSyncTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), (uint64_t)(0.5 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(gSyncTimer, ^{
            static int loggedR = -2;
            static NSString *loggedName;
            NSString *name = activeName();
            if (orp_il2cpp_set_user_name(name.length ? name.UTF8String : "Offline...") == 1 && ![loggedName isEqualToString:name]) {
                orp_log("game: player name set to '%s'", name.UTF8String);
                loggedName = name;
            }
            int r = gOverall;
            if (r < 0) return;
            int rc = orp_il2cpp_set_user_r(r);
            if (rc == 1 && loggedR != r) { orp_log("game: player R set to %d", r); loggedR = r; }
            static BOOL coverSelfTest;
            if (rc != 0 && !coverSelfTest) {   // the game's runtime is up: prove once that the cover decryption works here
                coverSelfTest = YES;
                char rel[240];
                if (orp_index_any_cover(rel, sizeof rel)) { UIImage *img = orp_cover_for_path([NSString stringWithUTF8String:rel]); orp_log("cover self-test: %s", img ? "OK" : "FAILED"); }
                else orp_log("cover self-test: no cover path in the index");
            }
        });
        dispatch_resume(gSyncTimer);
        orp_ui_start();
    });
}

void orp_core_fetch_snapshot(void (^cb)(const orp_snapshot *)) {
    dispatch_async(gQ, ^{
        orp_snapshot *snap = (orp_snapshot *)calloc(1, sizeof(orp_snapshot));
        if (gStore) {
            snap->count = orp_store_best(gStore, snap->rows, 20);
            snap->unratedCount = orp_store_unrated(gStore, snap->unrated, 12);
            snap->overall = orp_store_overall(gStore);
            snap->plays = orp_store_play_count(gStore);
            snap->algo = orp_store_algorithm(gStore);
            snap->synthetic = orp_store_synthetic_count(gStore);
            for (int i = 0; i < snap->count; i++) {   // chart_key is "<uuid>|<CLASS>" for charts resolved through the index
                const char *bar = strchr(snap->rows[i].chart_key, '|');
                size_t ul = bar ? (size_t)(bar - snap->rows[i].chart_key) : 0;
                if (ul == 24) { char u[32]; memcpy(u, snap->rows[i].chart_key, 24); u[24] = 0; orp_index_cover_for_uuid(u, snap->covers[i], sizeof snap->covers[i]); }
            }
        }
        NSString *name = activeName();
        strlcpy(snap->account, name.length ? name.UTF8String : "Offline...", sizeof snap->account);
        dispatch_async(dispatch_get_main_queue(), ^{ cb(snap); free(snap); });
    });
}

// ------------------------------------------------------------------ hook handlers (game thread)
// A finished chart. NewMarkUpload.AfterPlayUploadAsync(score, perfect, good, miss, bleed, mirror, alive, ...)
static void orp_on_result(int score, int perfect, int good, int miss, unsigned bleed, unsigned mirror, unsigned alive) {
    @autoreleasepool {
        char title[256] = {0}, chartId[96] = {0}, file[256] = {0};
        int diff = -1;
        orp_il2cpp_static_string("ChartInfoManager", "Name", title, sizeof title);
        orp_il2cpp_static_int("ChartInfoManager", "Difficulty", &diff);
        orp_il2cpp_static_string("NewMarkUpload", "lastChartId", chartId, sizeof chartId);
        orp_il2cpp_static_string("PlaybackSystem", "FileName", file, sizeof file);
        int bl = (bleed & 0xFF) != 0, mi = (mirror & 0xFF) != 0, al = (alive & 0xFF) != 0;
        orp_log("result: score=%d P/G/M=%d/%d/%d bleed=%d mirror=%d alive=%d | title='%s' diff=%d chartId='%s' file='%s'",
                score, perfect, good, miss, bl, mi, al, title, diff, chartId, file);

        NSString *nsTitle = [NSString stringWithUTF8String:title] ?: @"";
        NSString *nsId = [NSString stringWithUTF8String:chartId] ?: @"";
        dispatch_async(gQ, ^{
            if (!gStore) return;
            // Resolve the chart: the index gives the true title / difficulty class / level / uuid.
            orp_index_hit hit;
            int ir = nsId.length ? orp_index_lookup(nsId.UTF8String, &hit) : 0;
            NSString *useTitle = nsTitle;
            char cls[16];
            char label[32];
            NSString *key;
            if (ir == 1) {
                useTitle = [NSString stringWithUTF8String:hit.title] ?: nsTitle;
                strlcpy(cls, hit.cls, sizeof cls);
                snprintf(label, sizeof label, hit.level > 0 ? "%s %d" : "%s", hit.cls, hit.level);
                key = [NSString stringWithFormat:@"%s|%s", hit.uuid, hit.cls];
            } else {
                strlcpy(cls, orp_difficulty_class(diff), sizeof cls);   // ChartInfoManager.Difficulty is unreliable
                strlcpy(label, cls, sizeof label);
                key = nsTitle.length ? [NSString stringWithFormat:@"%@|%s", nsTitle, cls] : (nsId.length ? nsId : @"unknown|?");
                orp_log("index: chart not resolved (result %d) - falling back to title + ChartInfoManager.Difficulty", ir);
            }
            // The result screen can trigger the upload call twice for one play: ignore exact repeats.
            static NSString *lastSig;
            static CFAbsoluteTime lastAt;
            NSString *sig = [NSString stringWithFormat:@"%@#%@#%d#%d#%d#%d#%d", activeName(), key, score, perfect, good, miss, al];
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (lastSig && [lastSig isEqualToString:sig] && now - lastAt < 5.0) { orp_log("result: duplicate ignored"); return; }
            lastSig = sig;
            lastAt = now;

            double d = 0;
            if (ir == 1) d = orp_chart_constant(useTitle.UTF8String, hit.cls[0] ? orp_class_index(hit.cls) : diff);
            else d = orp_chart_constant(nsTitle.UTF8String, diff);
            int before = orp_store_overall(gStore);
            double r = -1;
            int isBest = 0;
            if (orp_store_record_play(gStore, key.UTF8String, useTitle.UTF8String, label, d, score, perfect, good, miss, bl, mi, al,
                                      (long long)time(NULL), &r, &isBest) != 0) {
                orp_log("store: record failed");
                return;
            }
            int after = orp_store_overall(gStore);
            gOverall = after;
            orp_log("store: '%s' [%s] constant=%.2f rating=%.0f best=%d overall %d -> %d", useTitle.UTF8String, label, d, r, isBest, before, after);
            if (!al) return;  // failed play: stored, but no popup
            orp_result res;
            memset(&res, 0, sizeof res);
            strlcpy(res.title, useTitle.UTF8String, sizeof res.title);
            strlcpy(res.cls, label, sizeof res.cls);
            res.constant = d;
            res.rating = r;
            res.isBest = isBest;
            res.accuracy = orp_accuracy(perfect, good, miss);
            res.perfect = perfect; res.good = good; res.miss = miss; res.score = score;
            res.overallBefore = before; res.overallAfter = after;
            NSValue *v = [NSValue valueWithBytes:&res objCType:@encode(orp_result)];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:ORPResultNotification object:nil userInfo:@{@"result": v}];
            });
        });
    }
}

// Login / register typed into the game's own screens. The server is gone, so both are handled locally:
// pick (or create) the local account, then let the game run its OWN offline login (LoginAsync with a null
// username builds the "Offline..." user and calls the success callback), and finally put the typed name
// and this account's rating on that user.
//   LoginAsync(this, username, password, onSuccess, onNetworkError, onError, methodInfo)
//   RegisterAsync has the same shape; we simply run LoginAsync for it as well.
static int g_in_login_redirect;

// Tell the game's own login screen that the login failed (its onNetworkError(string) callback shows the text and
// re-enables the buttons) - so a wrong password does not leave the screen hanging.
static void failLogin(uint64_t *regs, NSString *msg) {
    orp_log("account: login refused: %s", msg.UTF8String);
    void *cb = (void *)regs[4];
    if (!cb || !orp_il2cpp_invoke_with_string(cb, "Invoke", msg.UTF8String)) orp_log("account: could not deliver the error to the game UI");
}

static int orp_on_login(uint64_t *regs, int isRegister) {
    if (g_in_login_redirect) return 0;   // this is our own nested call: let the original function run
    @autoreleasepool {
        char buf[256] = {0}, pbuf[256] = {0};
        orp_il2cpp_string_to_utf8((void *)regs[1], buf, sizeof buf);    // regs[1] == NULL (DoOffline) -> ""
        orp_il2cpp_string_to_utf8((void *)regs[2], pbuf, sizeof pbuf);
        NSString *name = [[NSString stringWithUTF8String:buf] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
        NSString *pw = [NSString stringWithUTF8String:pbuf] ?: @"";
        if (name.length > 32) name = [name substringToIndex:32];
        orp_log("account: %s requested for '%s'", isRegister ? "register" : "login", name.length ? name.UTF8String : "(offline)");
        if (name.length) {
            if (isRegister) {   // the game's own register panel
                if (accountExists(name)) { failLogin(regs, @"账号已存在 · Account already exists"); return 1; }
                accountCreateRec(name, pw);
            } else {
                if (!accountExists(name)) { failLogin(regs, @"账号不存在，请先点「注册」 · Unknown account, please register first"); return 1; }
                if (!accountVerify(name, pw)) { failLogin(regs, @"密码错误 · Wrong password"); return 1; }
            }
        }
        activateAccount(name);

        typedef void (*LoginFn)(void *, void *, void *, void *, void *, void *, void *);
        LoginFn login = (LoginFn)(orp_game_base() + ORP_SITES[ORP_SITE_LOGIN].site_rva);
        g_in_login_redirect = 1;
        login((void *)regs[0], NULL, NULL, (void *)regs[3], (void *)regs[4], (void *)regs[5], (void *)regs[6]);
        g_in_login_redirect = 0;

        orp_il2cpp_set_user_name(name.length ? name.UTF8String : "Offline...");
        if (gOverall >= 0) orp_il2cpp_set_user_r(gOverall);
    }
    return 1;   // the original (server) function is skipped
}

// The "Register" button of the title screen. The game's version opens its (dead) website. Instead we ask for a
// name (+ optional password) in a native dialog, put it into the game's own username/password fields and press
// the game's own login (UI1TitleScreen.TriggerLogin) - which our LoginAsync hook turns into a local account.
static void *gTitleScreen;   // UI1TitleScreen*

static NSString *runRegisterFlow(NSString *name, NSString *pw) {
    if (name.length > 32) return @"用户名最多 32 个字符 · At most 32 characters";
    if (accountExists(name)) return @"账号已存在，请直接登录 · Account exists - sign in instead";
    void *ts = gTitleScreen;
    if (!ts || strcmp(orp_il2cpp_class_name_of(ts), "UI1TitleScreen") != 0) { orp_log("register: title screen is gone, nothing done"); return @"标题界面已关闭，请重试 · Title screen is gone, please try again"; }
    void *uf = orp_il2cpp_get_obj_field(ts, "UsernameField");
    void *pf = orp_il2cpp_get_obj_field(ts, "PasswordField");
    if (!uf || !pf) { orp_log("register: username/password fields not found"); return @"找不到登录输入框 · Login fields not found"; }
    accountCreateRec(name, pw);
    int a = orp_il2cpp_input_set_text(uf, name.UTF8String);
    int b = orp_il2cpp_input_set_text(pf, pw.length ? pw.UTF8String : "local");   // the game wants something in the field
    int ok = 0;
    orp_il2cpp_call(ts, "TriggerLogin", 0, NULL, &ok);
    orp_log("register: '%s' created (%s), fields set (%d,%d), TriggerLogin ok=%d", name.UTF8String, pw.length ? "with password" : "no password", a, b, ok);
    return nil;
}

static int orp_on_jump_register(uint64_t *regs) {
    gTitleScreen = (void *)regs[0];
    char u[160] = {0}, p[160] = {0};
    void *uf = orp_il2cpp_get_obj_field(gTitleScreen, "UsernameField");
    void *pf = orp_il2cpp_get_obj_field(gTitleScreen, "PasswordField");
    if (uf) orp_il2cpp_input_get_text(uf, u, sizeof u);
    if (pf) orp_il2cpp_input_get_text(pf, p, sizeof p);
    orp_log("register: button pressed (website skipped), prefill '%s'", u);
    NSString *nu = [NSString stringWithUTF8String:u] ?: @"";
    NSString *np = [NSString stringWithUTF8String:p] ?: @"";
    orp_ui_prompt_account(nu, np, ^NSString *(NSString *n, NSString *pw) { return runRegisterFlow(n, pw); });
    return 1;   // the original (OpenURL) is skipped
}

int orp_dispatch(uint64_t *regs, int site) {
    switch (site) {
        case ORP_SITE_UPLOAD:
            orp_on_result((int)regs[0], (int)regs[1], (int)regs[2], (int)regs[3], (unsigned)regs[4], (unsigned)regs[5], (unsigned)regs[6]);
            return 0;
        case ORP_SITE_LOGIN:    return orp_on_login(regs, 0);
        case ORP_SITE_REGISTER: return orp_on_login(regs, 1);
        case ORP_SITE_JUMPREG:  return orp_on_jump_register(regs);
        default: return 0;
    }
}
