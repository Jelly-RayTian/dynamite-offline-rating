#import <Foundation/Foundation.h>
#include "../orp_charts.h"
static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)
int main(int argc, char **argv) {
    @autoreleasepool {
        CHECK(orp_charts_builtin_count() == 397, "count %d", orp_charts_builtin_count());
        // every CSV row resolves to its own constant (incl. non-ASCII titles)
        NSString *csv = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:nil];
        NSArray *lines = [csv componentsSeparatedByString:@"\n"];
        int ok = 0, total = 0;
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSString *l = lines[i]; if (!l.length) continue;
            // title may contain commas: parse from the right: ...,grade,constant,full_r
            NSArray *p = [l componentsSeparatedByString:@","];
            NSUInteger n = p.count; if (n < 4) continue;
            double d = [p[n - 2] doubleValue];
            NSString *cls = [[p[n - 3] componentsSeparatedByString:@" "] firstObject];
            NSString *title = [[p subarrayWithRange:NSMakeRange(0, n - 3)] componentsJoinedByString:@","];
            if ([title hasPrefix:@"\""]) { title = [title substringWithRange:NSMakeRange(1, title.length - 2)]; title = [title stringByReplacingOccurrencesOfString:@"\"\"" withString:@"\""]; }
            int diff = [cls isEqualToString:@"HARD"] ? 2 : [cls isEqualToString:@"MEGA"] ? 3 : [cls isEqualToString:@"GIGA"] ? 4 : 5;
            total++;
            if (orp_chart_constant(title.UTF8String, diff) == d) ok++;
            else printf("  unresolved: %s [%s] %.2f\n", title.UTF8String, cls.UTF8String, d);
        }
        CHECK(total == 397 && ok == 397, "resolved %d/%d", ok, total);
        CHECK(orp_chart_constant("circulatory spacetime", 4) == 15.5, "case-insensitive");
        CHECK(orp_chart_constant("  Circulatory Spacetime ", 4) == 15.5, "trim");
        CHECK(orp_chart_constant("Circulatory Spacetime", 3) == 0, "wrong difficulty -> unknown");
        CHECK(orp_chart_constant("No Such Song", 4) == 0, "unknown title");
        CHECK(orp_chart_constant(NULL, 4) == 0 && orp_chart_constant("", 4) == 0, "null/empty");
        // overrides
        NSString *tmp = [NSString stringWithFormat:@"%s/ov_%d.csv", getenv("ORP_TEST_DIR") ?: "/tmp", getpid()];
        [@"# comment\nMy Song, With Comma,MEGA,12.5\nCirculatory Spacetime,GIGA,15.9\nbad line\n" writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:nil];
        CHECK(orp_charts_load_overrides(tmp.UTF8String) == 2, "override count");
        CHECK(orp_chart_constant("My Song, With Comma", 3) == 12.5, "override with comma in title");
        CHECK(orp_chart_constant("Circulatory Spacetime", 4) == 15.9, "override wins over built-in");
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        printf("charts test done, %d failures\n", fails);
    }
    return fails ? 1 : 0;
}
