// Rating overlay: a pass-through UIWindow above the game with
//  - a pill showing the current total Rating (tap = open the Best-20 board),
//  - a result card after every completed chart,
//  - the Best-20 board: 2 columns x 10 slanted cards, styled after Phigros "B19" score images
//    (parallelogram cards, slanted artwork block, big score, rating tag), all 20 visible at once.
// Touches outside our own views fall through to the game.
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#include "orp_core.h"
#include "orp_engine.h"

// ------------------------------------------------------------------ palette
static UIColor *RGB(int r, int g, int b, CGFloat a) { return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a]; }
static UIColor *kAccent(void) { return RGB(61, 214, 255, 1); }
static UIColor *kGold(void)   { return RGB(255, 204, 64, 1); }
static UIColor *kText(void)   { return RGB(240, 246, 255, 1); }
static UIColor *kDim(void)    { return RGB(160, 176, 204, 1); }
static UIColor *kFaint(void)  { return RGB(160, 176, 204, 0.55); }

static UIColor *diffColor(NSString *label) {
    NSString *c = [[label componentsSeparatedByString:@" "].firstObject uppercaseString];
    if ([c isEqualToString:@"CASUAL"]) return RGB(96, 214, 140, 1);
    if ([c isEqualToString:@"NORMAL"]) return RGB(86, 164, 255, 1);
    if ([c isEqualToString:@"HARD"])   return RGB(255, 150, 72, 1);
    if ([c isEqualToString:@"MEGA"])   return RGB(214, 104, 255, 1);
    if ([c isEqualToString:@"GIGA"])   return RGB(190, 200, 218, 1);
    if ([c isEqualToString:@"TERA"])   return RGB(255, 92, 116, 1);
    return kDim();
}
static UIColor *rankColor(NSInteger i) {
    if (i == 0) return kGold();
    if (i == 1) return RGB(214, 224, 240, 1);
    if (i == 2) return RGB(226, 150, 100, 1);
    return RGB(255, 255, 255, 0.16);
}
static UIFont *mono(CGFloat s, UIFontWeight w) { return [UIFont monospacedDigitSystemFontOfSize:s weight:w]; }
static UIFont *sys(CGFloat s, UIFontWeight w)  { return [UIFont systemFontOfSize:s weight:w]; }
static NSString *algoName(int a) { return @"goodbird"; }

// A "/"-slanted parallelogram: the top edge is shifted right by `skew`.
static UIBezierPath *parallelogram(CGRect r, CGFloat skew) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(CGRectGetMinX(r) + skew, CGRectGetMinY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMinY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r) - skew, CGRectGetMaxY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r))];
    [p closePath];
    return p;
}

static UIImage *blurredCopy(UIImage *src, CGFloat radius) {
    if (!src.CGImage) return nil;
    CIImage *in = [CIImage imageWithCGImage:src.CGImage];
    CIFilter *f = [CIFilter filterWithName:@"CIGaussianBlur"];
    [f setValue:[in imageByClampingToExtent] forKey:kCIInputImageKey];
    [f setValue:@(radius) forKey:kCIInputRadiusKey];
    CIImage *out = [f.outputImage imageByCroppingToRect:in.extent];
    static CIContext *ctx;
    if (!ctx) ctx = [CIContext contextWithOptions:nil];
    CGImageRef cg = [ctx createCGImage:out fromRect:in.extent];
    if (!cg) return nil;
    UIImage *r = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return r;
}

static void styleGradient(UIView *v, CGFloat radius) {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.colors = @[(id)RGB(22, 32, 58, 0.985).CGColor, (id)RGB(8, 12, 24, 0.985).CGColor];
    g.startPoint = CGPointMake(0, 0);
    g.endPoint = CGPointMake(1, 1);
    g.cornerRadius = radius;
    g.name = @"orpgrad";
    [v.layer insertSublayer:g atIndex:0];
    v.layer.cornerRadius = radius;
    v.layer.borderWidth = 1;
    v.layer.borderColor = RGB(61, 214, 255, 0.35).CGColor;
    v.layer.shadowColor = UIColor.blackColor.CGColor;
    v.layer.shadowOpacity = 0.55;
    v.layer.shadowRadius = 22;
    v.layer.shadowOffset = CGSizeMake(0, 8);
}
static void layoutGradient(UIView *v) {
    for (CALayer *l in v.layer.sublayers) if ([l.name isEqualToString:@"orpgrad"]) l.frame = v.bounds;
}

// ------------------------------------------------------------------ one board card
@interface ORPCardView : UIView
@property(nonatomic, assign) NSInteger rank;          // 0-based
@property(nonatomic, assign) BOOL filled;
@property(nonatomic, copy) NSString *titleText, *diffText, *detailText, *scoreText, *accText, *ratingText, *badgeText;
@property(nonatomic, strong) UIColor *dcolor;
@property(nonatomic, assign) CGFloat accNorm;
@property(nonatomic, strong) UIImage *coverImage;   // real cover art (nil = coloured placeholder)
@end

@implementation ORPCardView {
    CAGradientLayer *_bg, *_art;
    CALayer *_cover;
    CAShapeLayer *_mask, *_artMask, *_coverMask, *_border, *_strip, *_accTrack, *_accFill;
    UILabel *_rankL, *_initial, *_title, *_sub, *_detail, *_score, *_acc, *_rating, *_badge;
}
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    _bg = [CAGradientLayer layer];
    _bg.colors = @[(id)RGB(30, 40, 68, 0.80).CGColor, (id)RGB(10, 14, 28, 0.86).CGColor];
    _bg.startPoint = CGPointMake(0, 0); _bg.endPoint = CGPointMake(1, 1);
    [self.layer addSublayer:_bg];
    _art = [CAGradientLayer layer];
    _art.startPoint = CGPointMake(0, 0); _art.endPoint = CGPointMake(1, 1);
    [self.layer addSublayer:_art];
    _artMask = [CAShapeLayer layer];
    _art.mask = _artMask;
    _cover = [CALayer layer];
    _cover.contentsGravity = kCAGravityResizeAspectFill;
    _cover.masksToBounds = YES;
    _cover.hidden = YES;
    _coverMask = [CAShapeLayer layer];
    _cover.mask = _coverMask;
    [self.layer addSublayer:_cover];
    _strip = [CAShapeLayer layer];
    [self.layer addSublayer:_strip];
    _accTrack = [CAShapeLayer layer]; _accTrack.fillColor = RGB(255, 255, 255, 0.08).CGColor;
    _accFill = [CAShapeLayer layer];
    [self.layer addSublayer:_accTrack];
    [self.layer addSublayer:_accFill];
    _border = [CAShapeLayer layer];
    _border.fillColor = UIColor.clearColor.CGColor;
    _border.lineWidth = 2;
    [self.layer addSublayer:_border];
    _mask = [CAShapeLayer layer];
    self.layer.mask = _mask;

    _rankL = [UILabel new]; _rankL.font = mono(12, UIFontWeightHeavy); _rankL.textAlignment = NSTextAlignmentCenter; _rankL.layer.cornerRadius = 4; _rankL.layer.masksToBounds = YES;
    _initial = [UILabel new]; _initial.font = sys(34, UIFontWeightHeavy); _initial.textColor = RGB(255, 255, 255, 0.55); _initial.textAlignment = NSTextAlignmentCenter;
    _title = [UILabel new]; _title.font = sys(15, UIFontWeightSemibold); _title.textColor = kText(); _title.adjustsFontSizeToFitWidth = YES; _title.minimumScaleFactor = 0.7;
    _sub = [UILabel new]; _sub.font = sys(12, UIFontWeightHeavy);
    _detail = [UILabel new]; _detail.font = mono(10.5, UIFontWeightMedium); _detail.textColor = kFaint();
    _score = [UILabel new]; _score.font = mono(20, UIFontWeightSemibold); _score.textColor = kText(); _score.textAlignment = NSTextAlignmentRight;
    _acc = [UILabel new]; _acc.font = mono(12, UIFontWeightSemibold); _acc.textAlignment = NSTextAlignmentRight;
    _rating = [UILabel new]; _rating.font = mono(27, UIFontWeightHeavy); _rating.textAlignment = NSTextAlignmentRight;
    _badge = [UILabel new]; _badge.font = sys(11, UIFontWeightHeavy); _badge.textAlignment = NSTextAlignmentCenter; _badge.layer.cornerRadius = 3; _badge.layer.masksToBounds = YES;
    for (UIView *v in @[_initial, _rankL, _title, _sub, _detail, _score, _acc, _rating, _badge]) [self addSubview:v];
    return self;
}

- (void)refresh {
    UIColor *dc = _dcolor ?: kDim();
    CGFloat alpha = _filled ? 1 : 0.38;
    _rankL.text = [NSString stringWithFormat:@"%ld", (long)_rank + 1];
    _rankL.textColor = _rank < 3 && _filled ? RGB(10, 14, 26, 1) : kText();
    _rankL.backgroundColor = _rank < 3 && _filled ? rankColor(_rank) : RGB(0, 0, 0, 0.45);
    _title.text = _filled ? _titleText : @"—";
    _title.textColor = _filled ? kText() : kFaint();
    NSMutableAttributedString *sub = [[NSMutableAttributedString alloc] initWithString:_filled ? _diffText : @"" attributes:@{NSForegroundColorAttributeName: dc, NSFontAttributeName: sys(12, UIFontWeightHeavy)}];
    _sub.attributedText = sub;
    _detail.text = _filled ? _detailText : @"";
    _score.text = _filled ? _scoreText : @"";
    _acc.text = _filled ? _accText : @"";
    _acc.textColor = _filled && _accNorm >= 0.95 ? kGold() : kDim();
    _rating.text = _filled ? _ratingText : @"";
    _rating.textColor = _rank < 3 ? kGold() : kAccent();
    _badge.text = _badgeText;
    _badge.hidden = _badgeText.length == 0 || !_filled;
    BOOL ap = [_badgeText isEqualToString:@"AP"];
    _badge.textColor = RGB(10, 14, 26, 1);
    _badge.backgroundColor = ap ? kGold() : kAccent();
    // artwork tile: hue from the title so every chart gets its own colour, difficulty colour on the edge
    NSUInteger h = 5381;
    for (NSUInteger i = 0; i < _titleText.length; i++) h = h * 33 + [_titleText characterAtIndex:i];
    CGFloat hue = (h % 360) / 360.0;
    _art.colors = _filled
        ? @[(id)[UIColor colorWithHue:hue saturation:0.42 brightness:0.72 alpha:1].CGColor, (id)[UIColor colorWithHue:fmod(hue + 0.10, 1) saturation:0.55 brightness:0.26 alpha:1].CGColor]
        : @[(id)RGB(60, 70, 96, 1).CGColor, (id)RGB(24, 30, 48, 1).CGColor];
    NSString *first = @"";
    for (NSUInteger i = 0; i < _titleText.length; ) {   // first letter or digit (skips "[", "(", quotes ...)
        NSRange r = [_titleText rangeOfComposedCharacterSequenceAtIndex:i];
        NSString *ch = [_titleText substringWithRange:r];
        if ([ch rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet].location != NSNotFound) { first = ch.uppercaseString; break; }
        i = NSMaxRange(r);
    }
    if (!first.length && _titleText.length) first = [_titleText substringToIndex:[_titleText rangeOfComposedCharacterSequenceAtIndex:0].length];
    _initial.text = (_filled && !_coverImage) ? first : @"";
    _cover.contents = _coverImage ? (id)_coverImage.CGImage : nil;
    _cover.hidden = !(_coverImage && _filled);
    _strip.fillColor = (_filled ? dc : RGB(255, 255, 255, 0.1)).CGColor;
    _accFill.fillColor = [dc colorWithAlphaComponent:0.85].CGColor;
    _border.strokeColor = (_filled && _rank == 0 ? RGB(255, 204, 64, 0.85) : RGB(255, 255, 255, _filled ? 0.16 : 0.07)).CGColor;
    for (UIView *v in self.subviews) v.alpha = (v == _rankL) ? 1 : alpha;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat sk = h * 0.26;
    CGRect all = CGRectMake(0, 0, w, h);
    _bg.frame = all;
    _mask.path = parallelogram(all, sk).CGPath;
    _border.path = parallelogram(CGRectInset(all, 0.5, 0.5), sk).CGPath;
    CGFloat tw = h * 1.9;
    _art.frame = all;
    _artMask.path = parallelogram(CGRectMake(0, 0, tw, h), sk).CGPath;
    _cover.frame = CGRectMake(0, 0, tw, h);
    _coverMask.path = parallelogram(CGRectMake(0, 0, tw, h), sk).CGPath;
    UIBezierPath *strip = [UIBezierPath bezierPath];
    [strip moveToPoint:CGPointMake(tw - 5, 0)]; [strip addLineToPoint:CGPointMake(tw, 0)];
    [strip addLineToPoint:CGPointMake(tw - sk, h)]; [strip addLineToPoint:CGPointMake(tw - sk - 5, h)]; [strip closePath];
    _strip.path = strip.CGPath;
    _initial.frame = CGRectMake(sk * 0.5, 0, tw - sk * 1.2, h);
    _rankL.frame = CGRectMake(sk + 3, 4, 24, 16);

    CGFloat x0 = tw + 10 + sk * 0.35, ratingW = 82, scoreW = 112;
    CGFloat rightEdge = w - sk * 0.5 - 12;
    _rating.frame = CGRectMake(rightEdge - ratingW, 0, ratingW, h);
    _score.frame = CGRectMake(rightEdge - ratingW - 8 - scoreW, h * 0.5 - 24, scoreW, 26);
    _acc.frame = CGRectMake(rightEdge - ratingW - 8 - scoreW, h * 0.5 + 3, scoreW, 16);
    CGFloat textW = MAX(40, _score.frame.origin.x - x0 - 6);
    BOOL three = h >= 54;      // title / difficulty / P-G-M when there is room, otherwise two lines
    CGFloat ty = three ? 4 : MAX(3, h * 0.5 - 21);
    _title.frame = CGRectMake(x0, ty, textW, 20);
    CGFloat subW = MIN(textW - 30, ceil([_sub.attributedText size].width) + 2);
    _sub.frame = CGRectMake(x0, ty + (three ? 19 : 21), MAX(40, subW), 15);
    _badge.frame = CGRectMake(x0 + MAX(40, subW) + 8, ty + (three ? 20 : 22), 24, 13);
    _detail.hidden = !three;
    _detail.frame = CGRectMake(x0, ty + 34, textW, 13);
    // accuracy bar along the bottom edge of the text area
    CGFloat bx = x0, bw = MAX(40, rightEdge - ratingW - 8 - bx - 4);
    CGFloat by = h - 3.5;
    _accTrack.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(bx, by, bw, 2) cornerRadius:1].CGPath;
    _accFill.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(bx, by, _filled ? bw * MAX(0.03, MIN(1.0, _accNorm)) : 0, 2) cornerRadius:1].CGPath;
}
@end

// ------------------------------------------------------------------ window
@interface ORPWindow : UIWindow
@end
@implementation ORPWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return (v == self || v == self.rootViewController.view) ? nil : v;
}
@end

// ------------------------------------------------------------------ root VC
@interface ORPRootVC : UIViewController <UITextFieldDelegate>
- (void)openPanel;
- (void)showRegisterName:(NSString *)name pw:(NSString *)pw error:(NSString *)err done:(NSString *(^)(NSString *, NSString *))done;
- (void)showAccount;
@end

@implementation ORPRootVC {
    UIButton *_fab;
    UIView *_toast, *_toastBar;
    UILabel *_toastTag, *_toastTitle, *_toastBig, *_toastLow;
    UIView *_dim, *_board, *_header;
    UILabel *_avatar, *_name, *_tag, *_ratingLabel, *_ratingBig, *_stats, *_note;
    CAShapeLayer *_slash;
    UIButton *_close;
    NSMutableArray<ORPCardView *> *_cards;
    UIScrollView *_scroll;
    orp_snapshot _snap;
    BOOL _hasSnap, _panelOpen, _fabPlaced, _animateNext;
    NSInteger _toastGen, _coverGen;
    UIImageView *_bgImage;
    UIView *_bgTint;
    // local registration card
    UIView *_regDim, *_regCard;
    UILabel *_regTitle, *_regSub, *_regErr;
    UITextField *_regUser, *_regPass;
    UIButton *_regCancel, *_regOK;
    NSString *(^_regDone)(NSString *, NSString *);
    BOOL _regFixedUser;
    __weak UIWindow *_regPrevKey;
    // account settings sheet
    UIButton *_acctBtn, *_acX, *_acSave;
    UIView *_acDim, *_acCard;
    UILabel *_acName, *_acSub, *_acStats, *_acPwTitle, *_acSwTitle, *_acMsg;
    UITextField *_acOld, *_acNew, *_acNew2;
    NSMutableArray<UIButton *> *_acChips;
    orp_account_list _acList;
    __weak UIWindow *_acPrevKey;
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }

- (UILabel *)label:(UIFont *)f color:(UIColor *)c {
    UILabel *l = [UILabel new];
    l.font = f; l.textColor = c;
    return l;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    // ---- pill button
    _fab = [UIButton buttonWithType:UIButtonTypeCustom];
    _fab.backgroundColor = RGB(8, 12, 24, 0.62);
    _fab.layer.cornerRadius = 11;
    _fab.layer.borderWidth = 1.2;
    _fab.layer.borderColor = RGB(61, 214, 255, 0.75).CGColor;
    _fab.alpha = 0.78;
    [self setFabTotal:-1];
    [_fab addTarget:self action:@selector(openPanel) forControlEvents:UIControlEventTouchUpInside];
    [_fab addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragFab:)]];
    [self.view addSubview:_fab];

    // ---- result card
    _toast = [UIView new];
    styleGradient(_toast, 12);
    _toast.hidden = YES;
    _toastBar = [UIView new]; _toastBar.layer.cornerRadius = 2;
    _toastTag = [self label:sys(9, UIFontWeightHeavy) color:kGold()];
    _toastTitle = [self label:sys(11.5, UIFontWeightBold) color:kText()];
    _toastBig = [self label:mono(17, UIFontWeightHeavy) color:kAccent()];
    _toastLow = [self label:mono(9, UIFontWeightRegular) color:kFaint()];
    for (UIView *v in @[_toastBar, _toastTag, _toastTitle, _toastBig, _toastLow]) [_toast addSubview:v];
    for (UILabel *l in @[_toastTitle, _toastLow]) { l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.7; }
    [_toast addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openPanel)]];
    [self.view addSubview:_toast];

    // ---- Best-20 board
    _dim = [UIView new];
    _dim.backgroundColor = RGB(5, 8, 16, 1.0);      // a standalone page, not a see-through overlay
    _dim.hidden = YES;
    [self.view addSubview:_dim];
    _bgImage = [UIImageView new];                    // blurred cover of the #1 chart, like the Phigros B19 images
    _bgImage.contentMode = UIViewContentModeScaleAspectFill;
    _bgImage.clipsToBounds = YES;
    _bgImage.alpha = 0;
    [_dim addSubview:_bgImage];
    _bgTint = [UIView new];
    _bgTint.backgroundColor = RGB(4, 7, 16, 0.66);
    [_dim addSubview:_bgTint];
    // faint diagonal light bars behind the board (the slanted look of the game's own UI)
    for (int i = 0; i < 3; i++) {
        CAShapeLayer *bar = [CAShapeLayer layer];
        bar.name = [NSString stringWithFormat:@"bar%d", i];
        bar.fillColor = RGB(61, 214, 255, 0.035 + 0.012 * i).CGColor;
        [_dim.layer addSublayer:bar];
    }
    _scroll = [UIScrollView new];
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.alwaysBounceVertical = NO;
    [_dim addSubview:_scroll];
    _board = [UIView new];
    [_board addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(noop)]];
    [_scroll addSubview:_board];

    _header = [UIView new];
    [_board addSubview:_header];
    _avatar = [self label:sys(26, UIFontWeightHeavy) color:RGB(10, 14, 26, 1)];
    _avatar.textAlignment = NSTextAlignmentCenter;
    _avatar.layer.cornerRadius = 28; _avatar.layer.masksToBounds = YES;
    _avatar.backgroundColor = kAccent();
    _name = [self label:sys(23, UIFontWeightBold) color:kText()];
    _tag = [self label:sys(12, UIFontWeightMedium) color:kDim()];
    _tag.text = @"";
    _tag.hidden = YES;
    _acctBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _acctBtn.layer.cornerRadius = 15;
    _acctBtn.layer.borderWidth = 1;
    _acctBtn.layer.borderColor = RGB(61, 214, 255, 0.55).CGColor;
    _acctBtn.backgroundColor = RGB(61, 214, 255, 0.10);
    _acctBtn.titleLabel.font = sys(13, UIFontWeightHeavy);
    [_acctBtn setTitle:@"账号设置 · Account  ›" forState:UIControlStateNormal];
    [_acctBtn setTitleColor:kAccent() forState:UIControlStateNormal];
    [_acctBtn addTarget:self action:@selector(showAccount) forControlEvents:UIControlEventTouchUpInside];
    _slash = [CAShapeLayer layer];
    _slash.strokeColor = RGB(255, 255, 255, 0.45).CGColor; _slash.lineWidth = 2;
    [_header.layer addSublayer:_slash];
    _ratingLabel = [self label:sys(12, UIFontWeightHeavy) color:kDim()];
    _ratingLabel.attributedText = [[NSAttributedString alloc] initWithString:@"RATING" attributes:@{NSKernAttributeName: @3.0, NSForegroundColorAttributeName: kDim(), NSFontAttributeName: sys(12, UIFontWeightHeavy)}];
    _ratingLabel.textAlignment = NSTextAlignmentRight;
    _ratingBig = [self label:mono(54, UIFontWeightHeavy) color:kAccent()];
    _ratingBig.textAlignment = NSTextAlignmentRight;
    _ratingBig.adjustsFontSizeToFitWidth = YES; _ratingBig.minimumScaleFactor = 0.5;
    _stats = [self label:sys(12, UIFontWeightMedium) color:kDim()];
    _stats.textAlignment = NSTextAlignmentRight;
    for (UIView *v in @[_avatar, _name, _tag, _acctBtn, _ratingLabel, _ratingBig, _stats]) [_header addSubview:v];

    _cards = [NSMutableArray array];
    for (int i = 0; i < 20; i++) {
        ORPCardView *c = [ORPCardView new];
        c.rank = i;
        [_board addSubview:c];
        [_cards addObject:c];
    }
    _note = [self label:sys(11, UIFontWeightRegular) color:kFaint()];
    _note.numberOfLines = 2;
    [_board addSubview:_note];

    _close = [UIButton buttonWithType:UIButtonTypeCustom];
    _close.backgroundColor = RGB(255, 255, 255, 0.10);
    _close.layer.cornerRadius = 18;
    _close.layer.borderWidth = 1;
    _close.layer.borderColor = RGB(255, 255, 255, 0.25).CGColor;
    [_close setTitle:@"‹  返回游戏" forState:UIControlStateNormal];
    _close.titleLabel.font = sys(15, UIFontWeightBold);
    [_close setTitleColor:kText() forState:UIControlStateNormal];
    [_close addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [_board addSubview:_close];

    // ---- local registration card (replaces the game's "open website" Register button)
    _regDim = [UIView new];
    _regDim.backgroundColor = RGB(3, 5, 12, 0.72);
    _regDim.hidden = YES;
    [_regDim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(regDismissKeyboard)]];
    [self.view addSubview:_regDim];
    _regCard = [UIView new];
    styleGradient(_regCard, 22);
    [_regDim addSubview:_regCard];
    _regTitle = [self label:sys(21, UIFontWeightBold) color:kText()];
    _regTitle.text = @"创建本地账号";
    _regSub = [self label:sys(12, UIFontWeightMedium) color:kDim()];
    _regSub.numberOfLines = 3;
    _regSub.text = @"Create local account\n离线账号，只用来区分各人的成绩，不联网。密码可以留空。";
    _regErr = [self label:sys(12, UIFontWeightSemibold) color:RGB(255, 108, 120, 1)];
    _regUser = [self regField:@"用户名 / Username" secure:NO];
    _regPass = [self regField:@"密码（可选） / Password (optional)" secure:YES];
    _regCancel = [self regButton:@"取消" filled:NO action:@selector(regCancel)];
    _regOK = [self regButton:@"创建并登录" filled:YES action:@selector(regSubmit)];
    for (UIView *v in @[_regTitle, _regSub, _regUser, _regPass, _regErr, _regCancel, _regOK]) [_regCard addSubview:v];
    [_regCard addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(regDismissKeyboard)]];

    [self buildAccountSheet];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onResult:) name:ORPResultNotification object:nil];
}

- (UITextField *)regField:(NSString *)placeholder secure:(BOOL)secure {
    UITextField *t = [UITextField new];
    t.backgroundColor = RGB(255, 255, 255, 0.08);
    t.layer.cornerRadius = 11;
    t.layer.borderWidth = 1;
    t.layer.borderColor = RGB(255, 255, 255, 0.10).CGColor;
    t.textColor = kText();
    t.font = sys(17, UIFontWeightMedium);
    t.tintColor = kAccent();
    t.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder attributes:@{NSForegroundColorAttributeName: kFaint(), NSFontAttributeName: sys(16, UIFontWeightRegular)}];
    t.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 10)];
    t.leftViewMode = UITextFieldViewModeAlways;
    t.autocorrectionType = UITextAutocorrectionTypeNo;
    t.autocapitalizationType = UITextAutocapitalizationTypeNone;
    t.spellCheckingType = UITextSpellCheckingTypeNo;
    t.clearButtonMode = secure ? UITextFieldViewModeNever : UITextFieldViewModeWhileEditing;
    t.secureTextEntry = secure;
    t.returnKeyType = secure ? UIReturnKeyGo : UIReturnKeyNext;
    t.keyboardAppearance = UIKeyboardAppearanceDark;
    t.delegate = self;
    return t;
}

- (UIButton *)regButton:(NSString *)title filled:(BOOL)filled action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.layer.cornerRadius = 12;
    b.titleLabel.font = sys(15, UIFontWeightHeavy);
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.7;
    [b setTitle:title forState:UIControlStateNormal];
    if (filled) { b.backgroundColor = kAccent(); [b setTitleColor:RGB(6, 12, 24, 1) forState:UIControlStateNormal]; }
    else { b.backgroundColor = RGB(255, 255, 255, 0.09); [b setTitleColor:kText() forState:UIControlStateNormal]; }
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    if (tf == _regUser) [_regPass becomeFirstResponder];
    else if (tf == _regPass) [self regSubmit];
    else if (tf == _acOld) [_acNew becomeFirstResponder];
    else if (tf == _acNew) [_acNew2 becomeFirstResponder];
    else if (tf == _acNew2) [self acSave];
    return NO;
}
- (void)regDismissKeyboard { [_regUser resignFirstResponder]; [_regPass resignFirstResponder]; }

- (void)showRegisterName:(NSString *)name pw:(NSString *)pw error:(NSString *)err done:(NSString *(^)(NSString *, NSString *))done {
    [self showCredentialsTitle:@"创建本地账号" sub:@"Create local account\n离线账号，只用来区分各人的成绩，不联网。密码可以留空。"
                          user:name fixedUser:NO pw:pw okTitle:@"创建并登录" error:err done:done];
}

// Shared card: register (name editable) and "switch account" (name fixed, password required).
// `done` returns an error message to keep the card open, or nil on success.
- (void)showCredentialsTitle:(NSString *)title sub:(NSString *)sub user:(NSString *)user fixedUser:(BOOL)fixed pw:(NSString *)pw
                     okTitle:(NSString *)okTitle error:(NSString *)err done:(NSString *(^)(NSString *, NSString *))done {
    if (_regDim.hidden) {
        UIWindow *prev = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *w in UIApplication.sharedApplication.windows) if (w != self.view.window && w.isKeyWindow) prev = w;
#pragma clang diagnostic pop
        _regPrevKey = prev;
    }
    _regDone = done;
    _regFixedUser = fixed;
    _regTitle.text = title;
    _regSub.text = sub;
    [_regOK setTitle:okTitle forState:UIControlStateNormal];
    _regUser.text = user; _regPass.text = pw;
    _regUser.enabled = !fixed; _regUser.alpha = fixed ? 0.6 : 1;
    _regErr.text = err ?: @"";
    _toastGen++; _toast.hidden = YES;
    _regDim.hidden = NO;
    _regDim.alpha = 0;
    [self.view bringSubviewToFront:_regDim];
    [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    [self.view.window makeKeyWindow];   // the text fields need keyboard focus
    [UIView animateWithDuration:0.2 animations:^{ self->_regDim.alpha = 1; }];
    [(fixed ? _regPass : _regUser) becomeFirstResponder];
    orp_log("ui: credentials card shown (%s)", fixed ? "fixed user" : "new user");
}

- (void)hideRegister {
    [self regDismissKeyboard];
    [UIView animateWithDuration:0.16 animations:^{ self->_regDim.alpha = 0; } completion:^(BOOL f) { self->_regDim.hidden = YES; }];
    [_regPrevKey makeKeyWindow];   // give the keyboard focus back to the game
}
- (void)regCancel { orp_log("ui: credentials card cancelled"); _regDone = nil; [self hideRegister]; }
- (void)regSubmit {
    NSString *n = [_regUser.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSString *p = _regPass.text ?: @"";
    if (!n.length) { _regErr.text = @"请输入用户名 · Please enter a username"; [_regUser becomeFirstResponder]; return; }
    NSString *e = _regDone ? _regDone(n, p) : nil;
    if (e.length) { _regErr.text = e; orp_log("ui: credentials card refused: %s", e.UTF8String); return; }
    orp_log("ui: credentials card accepted ('%s')", n.UTF8String);
    _regDone = nil;
    [self hideRegister];
}

// ---- account settings sheet
- (void)buildAccountSheet {
    _acDim = [UIView new];
    _acDim.backgroundColor = RGB(3, 5, 12, 0.66);
    _acDim.hidden = YES;
    [_acDim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideAccount)]];
    [self.view addSubview:_acDim];
    _acCard = [UIView new];
    styleGradient(_acCard, 22);
    [_acDim addSubview:_acCard];
    [_acCard addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(acDismissKeyboard)]];
    _acName = [self label:sys(24, UIFontWeightBold) color:kText()];
    _acSub = [self label:sys(12, UIFontWeightMedium) color:kDim()];
    _acSub.numberOfLines = 2;
    _acStats = [self label:mono(12, UIFontWeightMedium) color:kAccent()];
    _acPwTitle = [self label:sys(11, UIFontWeightHeavy) color:kFaint()];
    _acPwTitle.attributedText = [[NSAttributedString alloc] initWithString:@"修改密码 · CHANGE PASSWORD" attributes:@{NSKernAttributeName: @1.2, NSForegroundColorAttributeName: kFaint(), NSFontAttributeName: sys(11, UIFontWeightHeavy)}];
    _acSwTitle = [self label:sys(11, UIFontWeightHeavy) color:kFaint()];
    _acSwTitle.attributedText = [[NSAttributedString alloc] initWithString:@"切换账号 · SWITCH ACCOUNT" attributes:@{NSKernAttributeName: @1.2, NSForegroundColorAttributeName: kFaint(), NSFontAttributeName: sys(11, UIFontWeightHeavy)}];
    _acOld = [self regField:@"当前密码 / Current password" secure:YES];
    _acNew = [self regField:@"新密码（留空 = 移除密码） / New password" secure:YES];
    _acNew2 = [self regField:@"再次输入新密码 / Repeat new password" secure:YES];
    _acOld.returnKeyType = UIReturnKeyNext; _acNew.returnKeyType = UIReturnKeyNext; _acNew2.returnKeyType = UIReturnKeyDone;
    _acSave = [self regButton:@"保存密码" filled:YES action:@selector(acSave)];
    _acMsg = [self label:sys(12, UIFontWeightSemibold) color:kDim()];
    _acMsg.numberOfLines = 2;
    _acX = [UIButton buttonWithType:UIButtonTypeCustom];
    _acX.backgroundColor = RGB(255, 255, 255, 0.10);
    _acX.layer.cornerRadius = 17;
    [_acX setTitle:@"✕" forState:UIControlStateNormal];
    _acX.titleLabel.font = sys(15, UIFontWeightBold);
    [_acX setTitleColor:kText() forState:UIControlStateNormal];
    [_acX addTarget:self action:@selector(hideAccount) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *v in @[_acName, _acSub, _acStats, _acPwTitle, _acOld, _acNew, _acNew2, _acSave, _acMsg, _acSwTitle, _acX]) [_acCard addSubview:v];
    _acChips = [NSMutableArray array];
}

- (void)acDismissKeyboard { [_acOld resignFirstResponder]; [_acNew resignFirstResponder]; [_acNew2 resignFirstResponder]; }

- (void)showAccount {
    if (!_acDim.hidden) return;
    UIWindow *prev = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *w in UIApplication.sharedApplication.windows) if (w != self.view.window && w.isKeyWindow) prev = w;
#pragma clang diagnostic pop
    _acPrevKey = prev;
    _acOld.text = @""; _acNew.text = @""; _acNew2.text = @"";
    [self refreshAccountSheet];
    _acDim.hidden = NO;
    _acDim.alpha = 0;
    [self.view bringSubviewToFront:_acDim];
    [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    [self.view.window makeKeyWindow];
    [UIView animateWithDuration:0.2 animations:^{ self->_acDim.alpha = 1; }];
}
- (void)hideAccount {
    [self acDismissKeyboard];
    [UIView animateWithDuration:0.16 animations:^{ self->_acDim.alpha = 0; } completion:^(BOOL f) { self->_acDim.hidden = YES; }];
    [_acPrevKey makeKeyWindow];
}

- (void)refreshAccountSheet {
    orp_account_list_get(&_acList);
    BOOL isDef = _acList.active[0] == 0;
    _acName.text = isDef ? @"Offline..." : ([NSString stringWithUTF8String:_acList.active] ?: @"?");
    _acSub.text = isDef ? @"默认离线账号，不能设置密码。\n点游戏登录页的「点此注册」创建自己的账号。"
                        : (_acList.activeHasPassword ? @"本地账号 · 已设置密码\nLocal account · password set" : @"本地账号 · 未设置密码\nLocal account · no password");
    _acOld.hidden = isDef || !_acList.activeHasPassword;
    _acNew.hidden = _acNew2.hidden = _acSave.hidden = _acPwTitle.hidden = isDef;
    _acMsg.text = @"";
    for (UIButton *c in _acChips) [c removeFromSuperview];
    [_acChips removeAllObjects];
    for (int i = 0; i < _acList.count; i++) {
        if (strcmp(_acList.items[i].name, _acList.active) == 0) continue;   // not the current one
        NSString *nm = _acList.items[i].name[0] ? [NSString stringWithUTF8String:_acList.items[i].name] : @"Offline...";
        UIButton *b = [self regButton:[NSString stringWithFormat:@"%@%@", _acList.items[i].hasPassword ? @"🔒 " : @"", nm] filled:NO action:@selector(acChip:)];
        b.tag = i;
        b.titleLabel.font = sys(13, UIFontWeightSemibold);
        b.layer.cornerRadius = 10;
        [_acCard addSubview:b];
        [_acChips addObject:b];
    }
    _acSwTitle.hidden = _acChips.count == 0;
    __weak ORPRootVC *w = self;
    orp_core_fetch_snapshot(^(const orp_snapshot *snap) {
        ORPRootVC *me = w;
        if (!me) return;
        me->_acStats.text = [NSString stringWithFormat:@"Rating %d   ·   %d plays   ·   %d / 20 charts", snap->overall, snap->plays, snap->count];
    });
    [self.view setNeedsLayout];
}

- (void)acMessage:(NSString *)msg ok:(BOOL)ok {
    _acMsg.textColor = ok ? RGB(112, 224, 140, 1) : RGB(255, 108, 120, 1);
    _acMsg.text = msg;
}

- (void)acSave {
    NSString *o = _acOld.text ?: @"", *n1 = _acNew.text ?: @"", *n2 = _acNew2.text ?: @"";
    if (![n1 isEqualToString:n2]) { [self acMessage:@"两次输入的新密码不一致 · The two new passwords differ" ok:NO]; return; }
    char err[200] = {0};
    if (orp_account_change_password(o.UTF8String, n1.UTF8String, err, sizeof err) != 0) { [self acMessage:[NSString stringWithUTF8String:err] ok:NO]; return; }
    _acOld.text = @""; _acNew.text = @""; _acNew2.text = @"";
    [self acDismissKeyboard];
    [self refreshAccountSheet];
    [self acMessage:n1.length ? @"密码已更新 · Password updated" : @"已移除密码 · Password removed" ok:YES];
}

- (void)afterAccountSwitch {
    [self refreshAccountSheet];
    [self refreshTotalOnly];
    if (_panelOpen) [self reloadSnapshot];
}

- (void)acChip:(UIButton *)b {
    NSInteger i = b.tag;
    if (i < 0 || i >= _acList.count) return;
    orp_account_item it = _acList.items[i];
    NSString *name = [NSString stringWithUTF8String:it.name] ?: @"";
    __weak ORPRootVC *w = self;
    if (it.hasPassword) {
        [self showCredentialsTitle:@"切换账号" sub:@"输入这个账号的密码\nEnter this account's password" user:name fixedUser:YES pw:@"" okTitle:@"切换" error:nil
                              done:^NSString *(NSString *n, NSString *p) {
            char err[160] = {0};
            if (orp_account_switch(n.UTF8String, p.UTF8String, err, sizeof err) != 0) return [NSString stringWithUTF8String:err];
            [w afterAccountSwitch];
            return nil;
        }];
    } else {
        char err[160] = {0};
        if (orp_account_switch(it.name, "", err, sizeof err) == 0) [self afterAccountSwitch];
        else [self acMessage:[NSString stringWithUTF8String:err] ok:NO];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshTotalOnly];
}

- (void)noop {}

// ---- layout
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets sa = self.view.safeAreaInsets;
    CGSize s = self.view.bounds.size;
    if (!_fabPlaced) { _fab.frame = CGRectMake(sa.left + 8, sa.top + 6, 30, 22); _fabPlaced = YES; [self layoutFab]; }

    CGFloat tw = MIN(340, s.width - sa.left - sa.right - 24);
    _toast.frame = CGRectMake((s.width - tw) / 2, sa.top + 6, tw, 66);
    layoutGradient(_toast);
    _toastBar.frame = CGRectMake(10, 10, 3, 46);
    _toastTag.frame = CGRectMake(20, 6, tw - 30, 11);
    _toastTitle.frame = CGRectMake(20, 17, tw - 30, 15);
    _toastBig.frame = CGRectMake(20, 31, tw - 30, 22);
    _toastLow.frame = CGRectMake(20, 53, tw - 30, 11);

    _dim.frame = self.view.bounds;
    _bgImage.frame = _dim.bounds;
    _bgTint.frame = _dim.bounds;
    for (int i = 0; i < 3; i++) {   // diagonal light bars
        for (CALayer *l in _dim.layer.sublayers) if ([l.name isEqualToString:[NSString stringWithFormat:@"bar%d", i]]) {
            CGFloat x = s.width * (0.18 + 0.27 * i), w = 120 + 60 * i;
            UIBezierPath *p = [UIBezierPath bezierPath];
            [p moveToPoint:CGPointMake(x + 260, 0)]; [p addLineToPoint:CGPointMake(x + 260 + w, 0)];
            [p addLineToPoint:CGPointMake(x + w, s.height)]; [p addLineToPoint:CGPointMake(x, s.height)]; [p closePath];
            ((CAShapeLayer *)l).path = p.CGPath;
        }
    }
    _scroll.frame = CGRectMake(sa.left, sa.top, s.width - sa.left - sa.right, s.height - sa.top - sa.bottom);
    [self layoutBoard];

    _regDim.frame = self.view.bounds;
    CGFloat rcw = MIN(470, s.width - sa.left - sa.right - 32), rch = 320;
    _regCard.frame = CGRectMake((s.width - rcw) / 2, MAX(sa.top + 16, s.height * 0.5 - rch * 0.5 - 150), rcw, rch);   // high enough to stay above the keyboard
    layoutGradient(_regCard);
    _regTitle.frame = CGRectMake(24, 22, rcw - 48, 28);
    _regSub.frame = CGRectMake(24, 54, rcw - 48, 50);
    _regUser.frame = CGRectMake(24, 112, rcw - 48, 46);
    _regPass.frame = CGRectMake(24, 168, rcw - 48, 46);
    _regErr.frame = CGRectMake(26, 220, rcw - 52, 18);
    CGFloat bwAll = rcw - 48 - 12, bwCancel = floor(bwAll * 0.36);
    _regCancel.frame = CGRectMake(24, 252, bwCancel, 48);
    _regOK.frame = CGRectMake(24 + bwCancel + 12, 252, bwAll - bwCancel, 48);

    // ---- account settings sheet
    _acDim.frame = self.view.bounds;
    CGFloat acw = MIN(520, s.width - sa.left - sa.right - 32), ax = 24, aw = acw - 48, y = 22;
    _acName.frame = CGRectMake(ax, y, aw - 40, 30); y += 32;
    _acSub.frame = CGRectMake(ax, y, aw, 32); y += 34;
    _acStats.frame = CGRectMake(ax, y, aw, 16); y += 30;
    if (!_acPwTitle.hidden) {
        _acPwTitle.frame = CGRectMake(ax, y, aw, 14); y += 20;
        if (!_acOld.hidden) { _acOld.frame = CGRectMake(ax, y, aw, 42); y += 50; }
        _acNew.frame = CGRectMake(ax, y, aw, 42); y += 50;
        _acNew2.frame = CGRectMake(ax, y, aw, 42); y += 50;
        CGFloat sw = floor(aw * 0.40);
        _acSave.frame = CGRectMake(ax, y, sw, 44);
        _acMsg.frame = CGRectMake(ax + sw + 12, y, aw - sw - 12, 44);
        y += 60;
    }
    if (_acChips.count) {
        _acSwTitle.frame = CGRectMake(ax, y, aw, 14); y += 22;
        CGFloat cx = ax, rowY = y;
        for (UIButton *c in _acChips) {
            CGFloat cwid = MIN(aw, ceil([c.currentTitle sizeWithAttributes:@{NSFontAttributeName: c.titleLabel.font}].width) + 32);
            if (cx + cwid > ax + aw) { cx = ax; rowY += 40; }
            c.frame = CGRectMake(cx, rowY, cwid, 34);
            cx += cwid + 8;
        }
        y = rowY + 44;
    } else if (!_acPwTitle.hidden) { y += 0; }
    CGFloat ach = MIN(y + 14, s.height - sa.top - sa.bottom - 24);
    _acCard.frame = CGRectMake((s.width - acw) / 2, MAX(sa.top + 12, (s.height - ach) / 2 - 70), acw, ach);
    layoutGradient(_acCard);
    _acX.frame = CGRectMake(acw - 24 - 34 + 10, 18, 34, 34);
}

- (void)layoutBoard {
    // The board is laid out at a fixed natural size and scaled to fill the page.
    CGSize vs = _scroll.bounds.size;
    CGFloat bw = 1150, gap = 10, headerH = 96, footerH = 26, vgap = 7, rowH = 62;
    CGFloat boardH = headerH + 10 * rowH + 9 * vgap + footerH + 8;
    CGFloat k = MIN(1.0, MIN((vs.width - 16) / bw, (vs.height - 12) / boardH));   // fill the page
    _board.transform = CGAffineTransformIdentity;
    _board.bounds = CGRectMake(0, 0, bw, boardH);
    _board.center = CGPointMake(vs.width / 2, vs.height / 2);
    _board.transform = CGAffineTransformMakeScale(k, k);
    _scroll.contentSize = vs;
    _scroll.scrollEnabled = NO;
    _header.frame = CGRectMake(0, 0, bw, headerH);
    _close.frame = CGRectMake(6, 30, 126, 36);                      // back button (top-left of the page)
    _avatar.frame = CGRectMake(146, 20, 56, 56);
    _name.frame = CGRectMake(216, 14, bw * 0.3, 30);
    _acctBtn.frame = CGRectMake(216, 48, 178, 30);
    UIBezierPath *sl = [UIBezierPath bezierPath];
    CGFloat sx = bw * 0.52;
    [sl moveToPoint:CGPointMake(sx + 16, 14)]; [sl addLineToPoint:CGPointMake(sx - 16, headerH - 10)];
    _slash.path = sl.CGPath;
    CGFloat rx = sx + 40, rw = bw - rx - 14;
    _ratingLabel.frame = CGRectMake(rx, 8, rw, 16);
    _ratingBig.frame = CGRectMake(rx, 22, rw, 58);
    _stats.frame = CGRectMake(rx, 76, rw, 16);
    CGFloat cw = (bw - gap) / 2;
    for (int i = 0; i < 20; i++) {
        int row = i / 2, col = i % 2;
        _cards[i].frame = CGRectMake(col * (cw + gap), headerH + row * (rowH + vgap), cw, rowH);
    }
    _note.frame = CGRectMake(8, boardH - footerH - 2, bw - 16, footerH);
}

// ---- pill
- (void)setFabTotal:(int)total {
    NSString *txt = total >= 0 ? [NSString stringWithFormat:@"R  %d", total] : @"R";
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:txt attributes:@{NSFontAttributeName: mono(11, UIFontWeightHeavy), NSForegroundColorAttributeName: kAccent()}];
    [_fab setAttributedTitle:a forState:UIControlStateNormal];
    [self layoutFab];
}
- (void)layoutFab {
    // Keep the LEFT edge fixed: when the number grows the pill must never slide off the screen.
    CGSize sz = [_fab.currentAttributedTitle size];
    CGRect f = _fab.frame;
    CGFloat w = MAX(30, ceil(sz.width) + 14);
    CGFloat maxX = self.view.bounds.size.width > 0 ? self.view.bounds.size.width - w - 6 : f.origin.x;
    _fab.frame = CGRectMake(MIN(f.origin.x, maxX), f.origin.y, w, 22);
}
- (void)dragFab:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.view];
    CGPoint c = CGPointMake(_fab.center.x + t.x, _fab.center.y + t.y);
    CGSize s = self.view.bounds.size;
    c.x = MAX(30, MIN(s.width - 30, c.x));
    c.y = MAX(20, MIN(s.height - 20, c.y));
    _fab.center = c;
    [g setTranslation:CGPointZero inView:self.view];
}

// ---- board
- (void)openPanel {
    _panelOpen = YES;
    _animateNext = YES;
    _toastGen++;
    _toast.hidden = YES;
    _dim.hidden = NO;
    _dim.alpha = 0;
    _fab.hidden = YES;
    [self.view bringSubviewToFront:_dim];
    [UIView animateWithDuration:0.2 animations:^{ self->_dim.alpha = 1; }];
    [self reloadSnapshot];
}
- (void)closePanel {
    _panelOpen = NO;
    [UIView animateWithDuration:0.18 animations:^{ self->_dim.alpha = 0; } completion:^(BOOL f) { if (!self->_panelOpen) { self->_dim.hidden = YES; self->_fab.hidden = NO; } }];
}

- (void)refreshTotalOnly {
    __weak ORPRootVC *w = self;
    orp_core_fetch_snapshot(^(const orp_snapshot *s) { [w setFabTotal:s->overall]; });
}

- (void)reloadSnapshot {
    __weak ORPRootVC *wself = self;
    orp_core_fetch_snapshot(^(const orp_snapshot *s) {
        ORPRootVC *me = wself;
        if (!me) return;
        me->_snap = *s;
        me->_hasSnap = YES;
        [me applySnapshot];
    });
}

- (void)applySnapshot {
    const orp_snapshot *s = &_snap;
    [self setFabTotal:s->overall];
    NSString *acct = [NSString stringWithUTF8String:s->account] ?: @"Offline...";
    _name.text = acct;
    NSString *first = acct.length ? [[acct substringToIndex:[acct rangeOfComposedCharacterSequenceAtIndex:0].length] uppercaseString] : @"?";
    _avatar.text = first;
    _ratingBig.text = [NSString stringWithFormat:@"%d", s->overall];
    double sum = 0, top = 0;
    for (int i = 0; i < s->count; i++) { sum += s->rows[i].rating; if (s->rows[i].rating > top) top = s->rows[i].rating; }
    _stats.text = [NSString stringWithFormat:@"%d / 20 charts   ·   avg %.0f   ·   max %.0f   ·   %d plays   ·   %@",
                   s->count, s->count ? sum / s->count : 0.0, top, s->plays, algoName(s->algo)];

    for (int i = 0; i < 20; i++) {
        ORPCardView *c = _cards[i];
        c.rank = i;
        c.coverImage = nil;
        if (i < s->count) {
            const orp_row *r = &s->rows[i];
            NSString *label = [NSString stringWithUTF8String:r->difficulty] ?: @"?";
            c.filled = YES;
            c.titleText = [NSString stringWithUTF8String:r->title] ?: @"?";
            c.diffText = [NSString stringWithFormat:@"%@  ·  D %.2f", label, r->constant];
            c.dcolor = diffColor(label);
            c.detailText = [NSString stringWithFormat:@"P%d  G%d  M%d%s%s", r->perfect, r->good, r->miss, r->bleed ? "  bleed" : "", r->mirror ? "  mirror" : ""];
            c.scoreText = [NSString stringWithFormat:@"%07d", r->score];
            double acc = r->accuracy * 100.0;
            c.accText = [NSString stringWithFormat:@"%.2f%%", acc];
            c.ratingText = [NSString stringWithFormat:@"%.0f", r->rating];
            c.badgeText = (r->miss == 0 && r->good == 0) ? @"AP" : (r->miss == 0 ? @"FC" : @"");
            c.accNorm = (acc - 90.0) / 10.0;
        } else {
            c.filled = NO; c.titleText = @""; c.badgeText = @""; c.accNorm = 0; c.dcolor = nil;
        }
        [c refresh];
        if (_animateNext) {   // staggered slide-in
            c.alpha = 0;
            c.transform = CGAffineTransformMakeTranslation(i % 2 ? 24 : -24, 0);
            [UIView animateWithDuration:0.28 delay:0.012 * i options:UIViewAnimationOptionCurveEaseOut animations:^{ c.alpha = 1; c.transform = CGAffineTransformIdentity; } completion:nil];
        }
    }
    _animateNext = NO;
    [self loadCovers];
    if (s->unratedCount > 0) {
        NSMutableString *n = [NSMutableString stringWithFormat:@"Unrated · 未定级 %d:  ", s->unratedCount];
        for (int i = 0; i < s->unratedCount && i < 3; i++) [n appendFormat:@"%s [%s]%@", s->unrated[i].title, s->unrated[i].difficulty, i + 1 < MIN(3, s->unratedCount) ? @",  " : @""];
        if (s->unratedCount > 3) [n appendString:@" …"];
        [n appendString:@"\n文件 App › Dynamite R › OfflineRating › constants.csv  ←  曲名,难度,定数"];
        _note.text = n;
    } else {
        _note.text = @"Rating = sum of your 20 best charts, one per chart.  数据库与日志在 文件 App › Dynamite R › OfflineRating";
    }
    if (s->synthetic > 0) _note.text = [_note.text stringByAppendingFormat:@"\n其中 %d 条是合成成绩，不是实际打出来的 · %d plays are synthetic (not played)", s->synthetic, s->synthetic];
    [self.view setNeedsLayout];
}

// Cover art is decrypted with the game's own function; do it one card at a time so the board stays responsive.
- (void)loadCovers {
    NSInteger gen = ++_coverGen;
    _bgImage.alpha = 0;
    for (int i = 0; i < _snap.count && i < 20; i++) {
        NSString *path = [NSString stringWithUTF8String:_snap.covers[i]];
        if (!path.length) continue;
        ORPCardView *card = _cards[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.12 + 0.05 * i) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gen != self->_coverGen) return;   // the board was refreshed meanwhile
            UIImage *img = orp_cover_for_path(path);
            if (!img) return;
            card.coverImage = img;
            [card refresh];
            if (i == 0) {   // blurred cover of the best chart as the page background
                UIImage *bg = blurredCopy(img, 16);
                if (bg) { self->_bgImage.image = bg; [UIView animateWithDuration:0.4 animations:^{ self->_bgImage.alpha = 1; }]; }
            }
        });
    }
}

// ---- result card
- (void)onResult:(NSNotification *)n {
    orp_result r;
    [(NSValue *)n.userInfo[@"result"] getValue:&r];
    NSString *title = [NSString stringWithUTF8String:r.title] ?: @"?";
    NSString *label = [NSString stringWithUTF8String:r.cls] ?: @"";
    UIColor *dc = diffColor(label);
    _toastTitle.text = [NSString stringWithFormat:@"%@   %@", title, label];
    if (r.rating < 0) {
        _toastTag.text = @"UNRATED · 未定级";
        _toastTag.textColor = kDim();
        _toastBig.text = @"no chart constant";
        _toastBig.textColor = kDim();
        _toastBig.font = sys(14, UIFontWeightBold);
        _toastLow.text = @"tap for Best 20 · 点开查看，并在 constants.csv 里添加定数";
        _toastBar.backgroundColor = kDim();
    } else {
        int delta = r.overallAfter - r.overallBefore;
        _toastTag.text = r.isBest ? @"NEW BEST   ·   tap for Best 20" : @"RESULT   ·   tap for Best 20";
        _toastTag.textColor = r.isBest ? kGold() : kDim();
        NSString *d = delta > 0 ? [NSString stringWithFormat:@"   +%d", delta] : @"";
        _toastBig.font = mono(17, UIFontWeightHeavy);
        _toastBig.text = [NSString stringWithFormat:@"R %.0f   ›   %d%@", r.rating, r.overallAfter, d];
        _toastBig.textColor = r.isBest ? kGold() : kAccent();
        _toastLow.text = [NSString stringWithFormat:@"D %.2f  ·  acc %.2f%%  ·  P%d G%d M%d  ·  %d", r.constant, r.accuracy * 100.0, r.perfect, r.good, r.miss, r.score];
        _toastBar.backgroundColor = dc;
    }
    _toast.layer.borderColor = (r.rating >= 0 && r.isBest ? RGB(255, 204, 64, 0.8) : RGB(61, 214, 255, 0.4)).CGColor;
    [self setFabTotal:r.overallAfter];
    if (_panelOpen) { [self reloadSnapshot]; return; }
    _toast.hidden = NO;
    _toast.alpha = 0;
    _toast.transform = CGAffineTransformMakeTranslation(0, -16);
    [self.view bringSubviewToFront:_toast];
    [UIView animateWithDuration:0.28 animations:^{ self->_toast.alpha = 1; self->_toast.transform = CGAffineTransformIdentity; }];
    NSInteger gen = ++_toastGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != self->_toastGen) return;
        [UIView animateWithDuration:0.3 animations:^{ self->_toast.alpha = 0; } completion:^(BOOL f) { if (gen == self->_toastGen) self->_toast.hidden = YES; }];
    });
}
@end

// ------------------------------------------------------------------ start
static ORPWindow *gWindow;

static void makeWindow(void) {
    if (gWindow) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; if (s.activationState == UISceneActivationStateForegroundActive) break; }
    gWindow = scene ? [[ORPWindow alloc] initWithWindowScene:scene] : [[ORPWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    gWindow.windowLevel = UIWindowLevelAlert + 100;
    gWindow.backgroundColor = UIColor.clearColor;
    gWindow.rootViewController = [ORPRootVC new];
    gWindow.hidden = NO;  // visible, but never key: the game keeps keyboard/focus
    orp_log("ui: window created (scene %s)", scene ? "yes" : "no");
}

void orp_ui_start(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *n) { makeWindow(); }];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) makeWindow();
    });
}

// "Create local account" page, shown by the hooked Register button.
void orp_ui_prompt_account(NSString *name, NSString *pw, NSString *(^done)(NSString *, NSString *)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        makeWindow();
        [(ORPRootVC *)gWindow.rootViewController showRegisterName:name pw:pw error:nil done:done];
    });
}

// Test hooks (used by the simulator host app).
void orp_ui_open_panel(void) { [(ORPRootVC *)gWindow.rootViewController openPanel]; }
UIViewController *orp_ui_test_root(void) { return [ORPRootVC new]; }
void orp_ui_test_open(UIViewController *vc) { [(ORPRootVC *)vc openPanel]; }
void orp_ui_test_register(UIViewController *vc) { [(ORPRootVC *)vc showRegisterName:@"" pw:@"" error:nil done:^NSString *(NSString *n, NSString *p) { return nil; }]; }
void orp_ui_test_account(UIViewController *vc) { [(ORPRootVC *)vc showAccount]; }
