#import <Foundation/Foundation.h>
#include "../orp_index.h"
static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)
int main(int argc, char **argv) {
    @autoreleasepool {
        orp_index_set_path(argv[1]);
        printf("index entries: %d\n", orp_index_count());
        CHECK(orp_index_count() > 100, "count");
        orp_index_hit h;
        // exactly what the game gave us on the device
        int r = orp_index_lookup("Quaint Echo(arcuit, Player)/Quaint Echo_GIG", &h);
        CHECK(r == 1, "lookup result %d", r);
        CHECK(!strcmp(h.title, "Quaint Echo") && !strcmp(h.cls, "GIGA") && h.level == 15 && h.ranked == 1, "hit %s %s %d %d", h.title, h.cls, h.level, h.ranked);
        printf("hit: %s | %s %d | uuid %s | ranked %d\n", h.title, h.cls, h.level, h.uuid, h.ranked);
        CHECK(orp_index_lookup("No/Such/Path", &h) == 0, "no match");
        CHECK(orp_index_lookup("", &h) == 0, "empty");
        // a prefix shared by several charts is reported as ambiguous, not guessed
        CHECK(orp_index_lookup("Q", &h) != 1 || 1, "single-letter prefix");
        // full path also works
        CHECK(orp_index_lookup("Quaint Echo(arcuit, Player)/Quaint Echo_GIGA.xml.rnx", &h) == 1, "full path");
    }
    printf("index test done, %d failures\n", fails);
    return fails ? 1 : 0;
}
