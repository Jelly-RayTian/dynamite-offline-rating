#import <UIKit/UIKit.h>
#include "../../orp_core.h"
extern void orp_ui_start(void);
extern void orp_ui_prompt_account(NSString *name, NSString *pw, NSString *(^done)(NSString *, NSString *));
extern UIViewController *orp_ui_test_root(void);
extern void orp_ui_test_open(UIViewController *vc);
extern void orp_ui_test_register(UIViewController *vc);
extern void orp_ui_test_account(UIViewController *vc);

@interface Host : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation Host
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new];
    // fake "game" backdrop: busy, colourful, to check legibility on top of it
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = UIScreen.mainScreen.bounds;
    g.colors = @[(id)[UIColor colorWithRed:0.1 green:0.35 blue:0.8 alpha:1].CGColor, (id)[UIColor colorWithRed:0.6 green:0.1 blue:0.35 alpha:1].CGColor, (id)[UIColor colorWithRed:0.05 green:0.1 blue:0.2 alpha:1].CGColor];
    [vc.view.layer addSublayer:g];
    UILabel *l = [UILabel new]; l.text = @"GAME"; l.font = [UIFont systemFontOfSize:120 weight:UIFontWeightHeavy]; l.textColor = [UIColor colorWithWhite:1 alpha:0.25]; [l sizeToFit]; l.center = CGPointMake(500, 300);
    [vc.view addSubview:l];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSUInteger si = [args indexOfObject:@"-snapshot"];
    NSString *outPath = (si != NSNotFound && si + 1 < args.count) ? args[si + 1] : nil;
    // Render the real UI at the iPad Pro 11" landscape size (1194x834 pt), independent of simulator orientation.
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1194, 834)];
    container.clipsToBounds = YES;
    [vc.view addSubview:container];
    CAGradientLayer *gl = [CAGradientLayer layer];
    gl.frame = container.bounds;
    gl.colors = @[(id)[UIColor colorWithRed:0.10 green:0.30 blue:0.75 alpha:1].CGColor, (id)[UIColor colorWithRed:0.55 green:0.10 blue:0.35 alpha:1].CGColor, (id)[UIColor colorWithRed:0.05 green:0.10 blue:0.20 alpha:1].CGColor];
    [container.layer addSublayer:gl];
    UILabel *gl2 = [UILabel new]; gl2.text = @"GAME SCREEN"; gl2.font = [UIFont systemFontOfSize:110 weight:UIFontWeightHeavy]; gl2.textColor = [UIColor colorWithWhite:1 alpha:0.22]; [gl2 sizeToFit]; gl2.center = CGPointMake(600, 520);
    [container addSubview:gl2];
    UIViewController *root = orp_ui_test_root();
    [vc addChildViewController:root];
    root.view.frame = container.bounds;
    [container addSubview:root.view];
    [root didMoveToParentViewController:vc];
    [container layoutIfNeeded];
    if ([args containsObject:@"-toast"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            orp_result r; memset(&r, 0, sizeof r);
            strlcpy(r.title, "WE ARE HARDCORE", sizeof r.title); strlcpy(r.cls, "GIGA 15", sizeof r.cls);
            r.constant = 15.62; r.rating = 1108; r.isBest = 1; r.accuracy = 0.9824; r.perfect = 1442; r.good = 26; r.miss = 13; r.score = 931716;
            r.overallBefore = 9800; r.overallAfter = 9908;
            NSValue *v = [NSValue valueWithBytes:&r objCType:@encode(orp_result)];
            [[NSNotificationCenter defaultCenter] postNotificationName:ORPResultNotification object:nil userInfo:@{@"result": v}];
        });
    }
    if ([args containsObject:@"-panel"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ orp_ui_test_open(root); });
    }
    if ([args containsObject:@"-alert"]) {
        orp_ui_start();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            orp_ui_prompt_account(@"Ray", @"", ^NSString *(NSString *n, NSString *p) { printf("DONE name=%s pw=%s\n", n.UTF8String, p.UTF8String); return nil; });
        });
    }
    if ([args containsObject:@"-register"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ orp_ui_test_register(root); });
    }
    if ([args containsObject:@"-account"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ orp_ui_test_account(root); });
    }
    if (outPath) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [container layoutIfNeeded];
            UIGraphicsImageRenderer *rr = [[UIGraphicsImageRenderer alloc] initWithSize:container.bounds.size];
            UIImage *img = [rr imageWithActions:^(UIGraphicsImageRendererContext *c) { [container.layer renderInContext:c.CGContext]; }];
            [UIImagePNGRepresentation(img) writeToFile:outPath atomically:YES];
            printf("SNAPSHOT %s\n", outPath.UTF8String);
            exit(0);
        });
    }
    return YES;
}
@end
int main(int c, char **v) { @autoreleasepool { return UIApplicationMain(c, v, nil, @"Host"); } }
