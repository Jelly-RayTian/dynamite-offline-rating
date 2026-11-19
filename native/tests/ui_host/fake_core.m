// Stand-in for orp_core.m so orp_ui.m can be rendered in the iOS Simulator.
#import <UIKit/UIKit.h>
#include <stdarg.h>
#include "../../orp_core.h"

NSString *const ORPResultNotification = @"ORPResultNotification";
void orp_log(const char *fmt, ...) { va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap); printf("\n"); }
NSString *orp_data_dir(void) { return NSTemporaryDirectory(); }

static void add(orp_snapshot *s, const char *t, const char *d, double D, int p, int g, int m, double r, int score) {
    orp_row *x = &s->rows[s->count++];
    memset(x, 0, sizeof *x);
    strlcpy(x->title, t, sizeof x->title); strlcpy(x->difficulty, d, sizeof x->difficulty);
    x->constant = D; x->perfect = p; x->good = g; x->miss = m; x->rating = r; x->score = score;
    x->accuracy = (p + g / 2.0) / (double)(p + g + m);
}

void orp_core_fetch_snapshot(void (^cb)(const orp_snapshot *)) {
    orp_snapshot *s = calloc(1, sizeof *s);
    const char *mode = getenv("ORP_SAMPLE") ?: "full";
    if (strcmp(mode, "empty") != 0) {
        add(s, "ULTiMATE INFLATiON", "TERA 17", 17.0, 1970, 12, 3, 1893, 962100);
        add(s, "ouroboros -twin stroke of the end-", "GIGA 15", 16.1, 2010, 9, 0, 1704, 975300);
        add(s, "Emptiness", "GIGA 15", 16.0, 1880, 20, 2, 1566, 961200);
        add(s, "終の舞姫", "GIGA 15", 15.88, 1760, 31, 4, 1402, 951000);
        add(s, "Quaint Echo", "GIGA 15", 15.68, 1431, 16, 18, 1117, 930943);
        add(s, "WE ARE HARDCORE", "GIGA 15", 15.62, 1442, 26, 13, 1108, 931716);
        add(s, "七つの鍵盤と大きな円盤のための練習曲 第一番 ハ短調", "MEGA 14", 14.9, 1320, 40, 6, 984, 902211);
        add(s, "Circulatory Spacetime", "GIGA 15", 15.5, 1534, 1, 0, 1562, 998000);
        add(s, "BATTLE NO.1", "MEGA 14", 14.2, 1200, 18, 5, 922, 940000);
        add(s, "[PRAW]", "GIGA 15", 15.8, 1660, 22, 9, 1210, 944000);
        add(s, "Urania", "MEGA 13", 13.4, 980, 9, 2, 861, 951000);
        add(s, "ICARUS", "MEGA 13", 13.1, 1010, 31, 8, 702, 905000);
        add(s, "F13", "HARD 11", 11.0, 700, 3, 0, 507, 995000);
        add(s, "kyrka", "HARD 12", 12.2, 640, 12, 1, 411, 960000);
        if (strcmp(mode, "full20") == 0) {
            add(s, "Concvssion", "MEGA 13", 13.0, 940, 14, 3, 840, 944000);
            add(s, "Decomposition", "MEGA 13", 13.3, 1100, 25, 4, 806, 931000);
            add(s, "Nhelv", "GIGA 15", 15.1, 1500, 10, 0, 1330, 972000);
            add(s, "Berry Go!!", "MEGA 14", 14.3, 1280, 8, 1, 1010, 968000);
            add(s, "Dement ~after legend~", "MEGA 14", 14.5, 1390, 21, 2, 1090, 957000);
            add(s, "Sigma", "MEGA 13", 13.8, 1210, 11, 0, 995, 975000);
        }
        for (int i = 0; i < s->count; i++) for (int j = i + 1; j < s->count; j++) if (s->rows[j].rating > s->rows[i].rating) { orp_row t = s->rows[i]; s->rows[i] = s->rows[j]; s->rows[j] = t; }
        double sum = 0; for (int i = 0; i < s->count; i++) sum += s->rows[i].rating;
        s->overall = (int)(sum + 0.5);
        s->plays = 37;
        strlcpy(s->unrated[0].title, "Quaint Echo (old test)", 200); strlcpy(s->unrated[0].difficulty, "CASUAL", 16);
        strlcpy(s->unrated[1].title, "My custom chart", 200); strlcpy(s->unrated[1].difficulty, "MEGA 13", 16);
        s->unratedCount = 2;
    }
    for (int i = 0; i < s->count; i++) snprintf(s->covers[i], sizeof s->covers[i], "fake/%s.jpg.rnx", s->rows[i].title);
    strlcpy(s->account, "Ray", sizeof s->account);
    dispatch_async(dispatch_get_main_queue(), ^{ cb(s); free(s); });
}

void orp_account_list_get(orp_account_list *out) {
    memset(out, 0, sizeof *out);
    strlcpy(out->active, "Ray", sizeof out->active);
    out->activeHasPassword = getenv("ORP_NOPW") ? 0 : 1;
    out->count = 4;
    out->items[0].name[0] = 0;
    strlcpy(out->items[1].name, "Player2", 64);
    strlcpy(out->items[2].name, "Ray", 64); out->items[2].hasPassword = out->activeHasPassword;
    strlcpy(out->items[3].name, "测试账号", 64); out->items[3].hasPassword = 1;
}
int orp_account_switch(const char *name, const char *pw, char *err, size_t cap) { return 0; }
int orp_account_change_password(const char *o, const char *n, char *err, size_t cap) { return 0; }

// Layout test only: draws a busy fake "cover" (the real one comes from the game's own decryption on the device).
UIImage *orp_cover_for_path(NSString *p) {
    if (getenv("ORP_NOCOVER")) return nil;
    NSUInteger h = 5381; for (NSUInteger i = 0; i < p.length; i++) h = h * 33 + [p characterAtIndex:i];
    CGSize sz = CGSizeMake(360, 202);
    return [[[UIGraphicsImageRenderer alloc] initWithSize:sz] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        CGFloat hue = (h % 360) / 360.0;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        NSArray *cols = @[(id)[UIColor colorWithHue:hue saturation:0.8 brightness:0.9 alpha:1].CGColor, (id)[UIColor colorWithHue:fmod(hue + 0.3, 1) saturation:0.9 brightness:0.4 alpha:1].CGColor];
        CGGradientRef g = CGGradientCreateWithColors(cs, (CFArrayRef)cols, NULL);
        CGContextDrawLinearGradient(c.CGContext, g, CGPointZero, CGPointMake(sz.width, sz.height), 0);
        CGGradientRelease(g); CGColorSpaceRelease(cs);
        [[UIColor colorWithWhite:1 alpha:0.35] setFill];
        UIRectFill(CGRectMake(sz.width * 0.55, 0, 40, sz.height));
        UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(sz.width * 0.15, sz.height * 0.1, sz.height * 0.8, sz.height * 0.8)];
        [[UIColor colorWithWhite:0 alpha:0.25] setFill]; [circle fill];
    }];
}
