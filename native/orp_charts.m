#import <Foundation/Foundation.h>
#include <strings.h>
#include "orp_charts.h"

typedef struct { const char *title; const char *cls; double d; } orp_chart_entry;
static const orp_chart_entry kBuiltin[] = {
#include "orp_chart_table.inc"
};

static NSMutableDictionary<NSString *, NSNumber *> *gBuiltin;
static NSMutableDictionary<NSString *, NSNumber *> *gOverrides;
static dispatch_once_t gOnce;

static NSString *normalize(NSString *s) {
    NSString *n = [s precomposedStringWithCompatibilityMapping];  // NFKC
    n = [n lowercaseString];
    return [n stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *makeKey(NSString *title, NSString *cls) {
    return [NSString stringWithFormat:@"%@|%@", normalize(title), [cls uppercaseString]];
}

static void ensureInit(void) {
    dispatch_once(&gOnce, ^{
        gBuiltin = [NSMutableDictionary dictionary];
        gOverrides = [NSMutableDictionary dictionary];
        for (size_t i = 0; i < sizeof kBuiltin / sizeof kBuiltin[0]; i++) {
            NSString *t = [NSString stringWithUTF8String:kBuiltin[i].title];
            NSString *c = [NSString stringWithUTF8String:kBuiltin[i].cls];
            if (t && c) gBuiltin[makeKey(t, c)] = @(kBuiltin[i].d);
        }
    });
}

const char *orp_difficulty_class(int e) {
    static const char *names[] = {"CASUAL", "NORMAL", "HARD", "MEGA", "GIGA", "TERA"};
    return (e >= 0 && e < 6) ? names[e] : "?";
}

int orp_class_index(const char *cls) {
    if (!cls) return -1;
    for (int i = 0; i < 6; i++) if (strcasecmp(cls, orp_difficulty_class(i)) == 0) return i;
    return -1;
}

double orp_chart_constant(const char *title, int diff) {
    if (!title || !*title) return 0;
    ensureInit();
    NSString *t = [NSString stringWithUTF8String:title];
    if (!t) return 0;
    NSString *key = makeKey(t, [NSString stringWithUTF8String:orp_difficulty_class(diff)]);
    @synchronized (gOverrides) {
        NSNumber *o = gOverrides[key];
        if (o) return o.doubleValue;
    }
    NSNumber *b = gBuiltin[key];
    return b ? b.doubleValue : 0;
}

int orp_charts_load_overrides(const char *path) {
    ensureInit();
    NSError *err = nil;
    NSString *text = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:path]
                                               encoding:NSUTF8StringEncoding error:&err];
    if (!text) return 0;
    int n = 0;
    NSMutableDictionary *fresh = [NSMutableDictionary dictionary];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (l.length == 0 || [l hasPrefix:@"#"]) continue;
        NSRange last = [l rangeOfString:@"," options:NSBackwardsSearch];
        if (last.location == NSNotFound) continue;
        NSString *num = [[l substringFromIndex:last.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *rest = [l substringToIndex:last.location];
        NSRange mid = [rest rangeOfString:@"," options:NSBackwardsSearch];
        if (mid.location == NSNotFound) continue;
        NSString *cls = [[rest substringFromIndex:mid.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *title = [rest substringToIndex:mid.location];
        double d = num.doubleValue;
        if (d <= 0 || title.length == 0 || cls.length == 0) continue;
        fresh[makeKey(title, cls)] = @(d);
        n++;
    }
    @synchronized (gOverrides) { [gOverrides removeAllObjects]; [gOverrides addEntriesFromDictionary:fresh]; }
    return n;
}

int orp_charts_builtin_count(void) {
    ensureInit();
    return (int)gBuiltin.count;
}
