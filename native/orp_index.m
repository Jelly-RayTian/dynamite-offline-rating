#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include "orp_index.h"

@interface ORPEntry : NSObject
@property NSString *title, *uuid, *cover;
@property BOOL ranked;
@property NSArray<NSString *> *classes, *maps;
@property NSArray<NSNumber *> *levels;
@end
@implementation ORPEntry
@end

static NSString *gPath;
static NSArray<ORPEntry *> *gEntries;
static time_t gMtime;
static off_t gSize;

void orp_index_set_path(const char *path) {
    @synchronized ([ORPEntry class]) { gPath = [NSString stringWithUTF8String:path]; gMtime = 0; gSize = -1; }
}

static void reloadIfNeeded(void) {
    if (!gPath) return;
    struct stat st;
    if (stat(gPath.fileSystemRepresentation, &st) != 0) { gEntries = nil; gMtime = 0; gSize = -1; return; }
    if (gEntries && st.st_mtime == gMtime && st.st_size == gSize) return;
    NSString *text = [NSString stringWithContentsOfFile:gPath encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    NSMutableArray *out = [NSMutableArray array];
    ORPEntry *cur = nil;
    NSMutableArray *cls, *lv;
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r"]];
        if ([l hasPrefix:@"B."]) { cur = [ORPEntry new]; cur.uuid = [l substringFromIndex:2]; cur.title = @""; cur.maps = @[]; cls = [NSMutableArray array]; lv = [NSMutableArray array]; continue; }
        if (!cur) continue;
        if ([l isEqualToString:@"E."]) { cur.classes = cls; cur.levels = lv; [out addObject:cur]; cur = nil; continue; }
        if (l.length < 2 || [l characterAtIndex:1] != '?') continue;
        NSString *v = [l substringFromIndex:2];
        switch ([l characterAtIndex:0]) {
            case 'N': cur.title = v; break;
            case 'C': cur.cover = v; break;
            case 'R': cur.ranked = [v isEqualToString:@"1"]; break;
            case 'H':
                for (NSString *d in [v componentsSeparatedByString:@";"]) {
                    if (!d.length) continue;
                    NSArray *p = [d componentsSeparatedByString:@","];
                    [cls addObject:[[p[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] uppercaseString]];
                    [lv addObject:@(p.count > 1 ? [p[1] intValue] : 0)];
                }
                break;
            case 'M': {
                NSMutableArray *m = [NSMutableArray array];
                for (NSString *p in [v componentsSeparatedByString:@";"]) if (p.length) [m addObject:p];
                cur.maps = m;
                break;
            }
            default: break;
        }
    }
    gEntries = out;
    gMtime = st.st_mtime;
    gSize = st.st_size;
}

int orp_index_any_cover(char *out, size_t cap) {
    if (cap == 0) return 0;
    out[0] = 0;
    @synchronized ([ORPEntry class]) {
        reloadIfNeeded();
        for (ORPEntry *e in gEntries) if (e.cover.length) { strlcpy(out, e.cover.UTF8String, cap); return 1; }
    }
    return 0;
}

int orp_index_cover_for_uuid(const char *uuid, char *out, size_t cap) {
    if (!uuid || !*uuid || cap == 0) return 0;
    out[0] = 0;
    NSString *u = [NSString stringWithUTF8String:uuid];
    if (!u) return 0;
    @synchronized ([ORPEntry class]) {
        reloadIfNeeded();
        for (ORPEntry *e in gEntries) {
            if ([e.uuid isEqualToString:u] && e.cover.length) { strlcpy(out, e.cover.UTF8String, cap); return 1; }
        }
    }
    return 0;
}

int orp_index_count(void) {
    @synchronized ([ORPEntry class]) { reloadIfNeeded(); return (int)gEntries.count; }
}

int orp_index_lookup(const char *prefix, orp_index_hit *hit) {
    if (!prefix || !*prefix) return 0;
    NSString *pre = [NSString stringWithUTF8String:prefix];
    if (!pre) return 0;
    @synchronized ([ORPEntry class]) {
        reloadIfNeeded();
        ORPEntry *found = nil;
        NSUInteger idx = 0;
        int matches = 0;
        for (ORPEntry *e in gEntries) {
            for (NSUInteger i = 0; i < e.maps.count; i++) {
                if ([e.maps[i] hasPrefix:pre]) {
                    if (matches == 0 || e != found || i != idx) matches++;
                    if (!found) { found = e; idx = i; }
                }
            }
        }
        if (matches == 0) return 0;
        if (matches > 1) return -1;
        memset(hit, 0, sizeof *hit);
        strlcpy(hit->title, found.title.UTF8String, sizeof hit->title);
        strlcpy(hit->uuid, found.uuid.UTF8String, sizeof hit->uuid);
        if (idx < found.classes.count) strlcpy(hit->cls, [found.classes[idx] UTF8String], sizeof hit->cls);
        if (idx < found.levels.count) hit->level = [found.levels[idx] intValue];
        hit->ranked = found.ranked;
        return 1;
    }
}
