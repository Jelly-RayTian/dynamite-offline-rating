#ifndef ORP_CORE_H
#define ORP_CORE_H

#import <UIKit/UIKit.h>
#include "orp_store.h"

// One finished chart, as delivered to the UI.
typedef struct {
    char title[200];
    char cls[16];          // CASUAL / NORMAL / HARD / MEGA / GIGA / TERA
    double constant;       // 0 = unknown
    double rating;         // -1 = not rated (unknown constant)
    int isBest;
    double accuracy;       // 0..1
    int perfect, good, miss, score;
    int overallBefore, overallAfter;
} orp_result;

typedef struct {
    orp_row rows[20];
    int count;
    orp_row unrated[12];
    int unratedCount;
    int overall;
    int plays;
    int algo;
    int synthetic;          // plays imported from a seed file (not actually played)
    char covers[20][240];   // cover image path (relative to Documents) per row, "" if unknown
    char account[64];       // active local account (the game's "Offline..." user by default)
} orp_snapshot;

// Local accounts. item.name == "" is the game's built-in "Offline..." user.
typedef struct { char name[64]; int hasPassword; } orp_account_item;
typedef struct {
    char active[64];          // "" = default
    int activeHasPassword;
    int count;
    orp_account_item items[16];   // items[0] is always the default account
} orp_account_list;
void orp_account_list_get(orp_account_list *out);
// Cover art for a chart: reads <Documents>/<rel path> (an encrypted *.rnx image), decrypts it with the game's own
// function and returns a small UIImage (cached in memory). Main thread only. nil if unavailable.
UIImage *orp_cover_for_path(NSString *relPath);
// All return 0 on success, otherwise fill `err` with a user-facing message (Chinese + English).
int orp_account_switch(const char *name, const char *password, char *err, size_t cap);          // name "" = default
int orp_account_change_password(const char *old_pw, const char *new_pw, char *err, size_t cap);  // active account; new_pw "" removes it

// Posted on the main thread after each COMPLETED chart. userInfo[@"result"] is an
// NSValue wrapping an orp_result.
extern NSString *const ORPResultNotification;

void orp_core_start(void);
// Builds a snapshot on the core queue and calls `cb` on the main thread.
void orp_core_fetch_snapshot(void (^cb)(const orp_snapshot *snap));
// Directory shown in the Files app: Documents/OfflineRating
NSString *orp_data_dir(void);
void orp_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#endif
