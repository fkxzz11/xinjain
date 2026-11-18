//
//  FakeGPSAutoAddress.m
//  FakeGPS.dylib
//
//  门店地址页自动覆盖设备位置：
//    该 App 是 React Native + WebView 混合体，《门店地址》页由 H5 承载
//    （main.jsbundle 中「仓库」出现 0 次，主程序含 WKWebView/evaluateJavaScript）。
//    因此这里不改 UIKit 视图，而是读 WebView 的 DOM：
//
//      1. 首次打开页面时，抓取地址页 URL 与 App 注入的用户信息脚本并缓存
//      2. 之后登录完成/回前台，自动在后台创建 1x1 透明 WKWebView 重新加载该页
//      3. 注入 JS 取 document.body.innerText，定位「仓库地址」后的经纬度
//      4. 写入 NSUserDefaults 并开启位置模拟（CLLocation 钩子随即生效）
//
//  开关（NSUserDefaults）：
//    AutoAddressOverrideEnabled  默认 YES，置 NO 停用本模块
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 由 FakeGPSHooks.m 提供（基于 runtime 的实现，不链接 substrate）
void MSHookMessageEx(Class cls, SEL sel, IMP replacement, IMP *result);

#pragma mark - 常量

static NSString *const kLatitudeKey            = @"latitude";
static NSString *const kLongitudeKey           = @"longitude";
static NSString *const kLocationSpoofingEnabled = @"LocationSpoofingEnabled";
static NSString *const kAutoOverrideEnabled    = @"AutoAddressOverrideEnabled";

static NSString *const kFGLastH5URLKey      = @"FGLastH5URL";
static NSString *const kFGLastInjectJSKey   = @"FGLastInjectJS";
static NSString *const kFGLastUserScriptKey = @"FGLastUserScript";
static NSString *const kFGLastInjectTimeKey = @"FGLastInjectTime";

// 进程启动时间：用于判断 token 是不是本次会话（登录后）注入的
static NSTimeInterval gFGLaunchTime = 0;

// 实测日志：https://storeapp.ausnutria.com/dms2storeh5/#/?routerPath=/storeAddressUpdate&isNative=Y
static NSString *const kFGDefaultAddressURL =
    @"https://storeapp.ausnutria.com/dms2storeh5/#/?routerPath=/storeAddressUpdate&isNative=Y";

// 取页面纯文本 + 所有输入框的值。
// 关键：该页的省市区/详细地址/经纬度都在 <input> 里，innerText 不含 value，
// 实测后台页面 innerText 只有 66 个字符（提示语 + 店铺名 + 两个区块标题）。
static NSString *const kFGPageTextJavaScript =
    @"(function(){try{"
     "var t=document.body?document.body.innerText:'';"
     "var e=document.querySelectorAll('input,textarea');"
     "var s='\\n##INPUTS##\\n';"
     "for(var i=0;i<e.length;i++){"
     "var p=e[i].placeholder||'';"
     "var v=e[i].value||'';"
     "s+='['+i+'] '+p+' = '+v+'\\n';"
     "}"
     "return (t+s).substring(0,30000);"
     "}catch(x){return '';}})()";

static const NSTimeInterval kFGScanInterval        = 3.0;    // 轮询 DOM 间隔
static const NSTimeInterval kFGBackgroundThrottle  = 15.0;   // 两次后台拉取最小间隔
static const NSTimeInterval kFGSuccessCooldown     = 600.0;  // 成功后冷却
static const NSTimeInterval kFGBackgroundLifetime  = 25.0;   // 后台 WebView 存活时长

static BOOL gFGInternalJS = NO;   // 我们自己发起的 evaluateJavaScript，不参与抓取
static BOOL gFGWebHooked  = NO;

static void (*orig_loadRequest)(id, SEL, id);
static void (*orig_evaluateJS)(id, SEL, NSString *, id);
static void (*orig_addUserScript)(id, SEL, id);
static void (*orig_addMessageHandler)(id, SEL, id, NSString *);
static void (*orig_setCustomUserAgent)(id, SEL, NSString *);

static NSMutableDictionary<NSString *, id> *gFGMessageHandlers = nil;
static NSString *gFGCustomUserAgent = nil;

static void hooked_loadRequest(id self, SEL _cmd, NSURLRequest *request);
static void hooked_evaluateJS(id self, SEL _cmd, NSString *script, id completion);
static void hooked_addUserScript(id self, SEL _cmd, id userScript);
static void hooked_addMessageHandler(id self, SEL _cmd, id handler, NSString *name);
static void hooked_setCustomUserAgent(id self, SEL _cmd, NSString *userAgent);

#pragma mark - 工具

// 只有《门店地址》页才算：App 里所有 H5 都走 /dms2storeh5 前缀，
// 必须靠 routerPath 区分（扫码页 kbrStoreReceiveScanOrInput 会覆盖记录）
static BOOL FGIsAddressPageURL(NSString *url)
{
    if (url.length == 0) {
        return NO;
    }
    return [url.lowercaseString containsString:@"storeaddress"];
}

// "34.80860925664227,114.46282467208921" → (lat, lng)
static BOOL FGParseCoordinate(NSString *text, double *latitude, double *longitude)
{
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:
                 @"(-?\\d{1,3}(?:\\.\\d+)?)\\s*[,，]\\s*(-?\\d{1,3}(?:\\.\\d+)?)"
                                                        options:0
                                                          error:nil];
    });

    NSTextCheckingResult *match =
        [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (match == nil) {
        return NO;
    }

    double lat = [[text substringWithRange:[match rangeAtIndex:1]] doubleValue];
    double lng = [[text substringWithRange:[match rangeAtIndex:2]] doubleValue];
    if (lat < -90.0 || lat > 90.0 || lng < -180.0 || lng > 180.0) {
        return NO;
    }

    *latitude  = lat;
    *longitude = lng;
    return YES;
}

// 取文本里最后一对合法经纬度（用于输入框顺序回落：门店在前、仓库在后）
static BOOL FGLastCoordinateInText(NSString *text, double *latitude, double *longitude)
{
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:
                 @"(-?\\d{1,3}(?:\\.\\d+)?)\\s*[,，]\\s*(-?\\d{1,3}(?:\\.\\d+)?)"
                                                        options:0
                                                          error:nil];
    });

    NSArray<NSTextCheckingResult *> *matches =
        [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        double lat = [[text substringWithRange:[match rangeAtIndex:1]] doubleValue];
        double lng = [[text substringWithRange:[match rangeAtIndex:2]] doubleValue];
        if (lat >= -90.0 && lat <= 90.0 && lng >= -180.0 && lng <= 180.0) {
            *latitude = lat;
            *longitude = lng;
            return YES;
        }
    }
    return NO;
}

// 定位「仓库地址」这一段，再从其后的文本里取第一对经纬度；
// 若文本段没有（值在输入框里），则在输入框区段里取最后一对经纬度
static BOOL FGParseWarehouseCoordinate(NSString *text, double *latitude, double *longitude)
{
    NSRange anchor = [text rangeOfString:@"仓库地址"];
    if (anchor.location != NSNotFound) {
        NSUInteger start = anchor.location + anchor.length;
        NSUInteger tailLength = MIN((NSUInteger)1200, text.length - start);
        NSString *tail = [text substringWithRange:NSMakeRange(start, tailLength)];

        NSRange inputs = [tail rangeOfString:@"##INPUTS##"];
        if (inputs.location != NSNotFound) {
            tail = [tail substringToIndex:inputs.location];
        }
        if (FGParseCoordinate(tail, latitude, longitude)) {
            return YES;
        }
    }

    NSRange inputs = [text rangeOfString:@"##INPUTS##"];
    if (inputs.location == NSNotFound) {
        return NO;
    }

    NSString *inputSection = [text substringFromIndex:inputs.location];
    return FGLastCoordinateInText(inputSection, latitude, longitude);
}

#pragma mark - 控制器

@interface FGAutoAddressController : NSObject
+ (instancetype)sharedController;
- (void)handleAppearanceOf:(UIViewController *)viewController;
- (void)startObservation;
- (void)scanWebViews;
- (void)readTextFromWebView:(UIView *)webView;
- (void)handlePageText:(NSString *)text source:(NSString *)source;
- (void)installWebKitHooksIfNeeded;
- (void)maybeStartBackgroundFetch;
- (void)requestImmediateBackgroundFetch;
- (void)teardownBackgroundWebView;
- (void)overrideDeviceLocationWithLatitude:(double)latitude longitude:(double)longitude;
@end

@implementation FGAutoAddressController
{
    id _backgroundWebView;
    NSTimeInterval _lastBackgroundFetchTime;
    NSTimeInterval _lastCoordinateTime;
    NSTimeInterval _lastDiagLogTime;
    int _bgFailCount;
    BOOL _done;   // 本次会话已成功拿到坐标 → 不再做任何拉取
    NSString *_lastCoordinateKey;
}

+ (instancetype)sharedController
{
    static FGAutoAddressController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[FGAutoAddressController alloc] init];
    });
    return shared;
}

- (BOOL)isEnabled
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id value = [defaults objectForKey:kAutoOverrideEnabled];
    return value == nil ? YES : [defaults boolForKey:kAutoOverrideEnabled];
}

- (void)startObservation
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSTimer *timer = [NSTimer timerWithTimeInterval:kFGScanInterval
                                                repeats:YES
                                                  block:^(NSTimer *t) {
            [[FGAutoAddressController sharedController] scanWebViews];
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onAppDidBecomeActive)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];

        NSLog(@"[FakeGPS] observation started");
    });
}

- (void)onAppDidBecomeActive
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self scanWebViews];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self maybeStartBackgroundFetch];
    });
}

// 每次页面出现都给后台拉取一个机会（登录完成 → 首页也会触发），内部有节流
- (void)handleAppearanceOf:(UIViewController *)viewController
{
    if (![self isEnabled]) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf maybeStartBackgroundFetch];
    });
}

#pragma mark 扫描 / 读 DOM

- (void)scanWebViews
{
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        return;
    }
    if (![self isEnabled]) {
        return;
    }

    [self installWebKitHooksIfNeeded];

    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (window == nil) {
        return;
    }

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if ([view isKindOfClass:NSClassFromString(@"WKWebView")] ||
            [view isKindOfClass:NSClassFromString(@"UIWebView")]) {
            [self readTextFromWebView:view];
        }
        if (view.subviews.count > 0) {
            [stack addObjectsFromArray:view.subviews];
        }
    }

    // 每 3 秒给后台拉取一次机会（内部 15 秒节流）：
    // App 冷启动时可能还在登录页，登录完成后靠这里自动补拉
    [self maybeStartBackgroundFetch];
}

- (void)readTextFromWebView:(UIView *)webView
{
    __weak typeof(self) weakSelf = self;
    Class wk = NSClassFromString(@"WKWebView");

    if (wk != Nil && [webView isKindOfClass:wk]) {
        id handler = ^(id result, NSError *error) {
            if (error == nil && [result isKindOfClass:[NSString class]]) {
                [weakSelf handlePageText:(NSString *)result source:@"WKWebView"];
            }
        };
        gFGInternalJS = YES;
        ((void (*)(id, SEL, id, id))objc_msgSend)(webView,
                                                  @selector(evaluateJavaScript:completionHandler:),
                                                  kFGPageTextJavaScript,
                                                  handler);
        gFGInternalJS = NO;
        return;
    }

    // 老式 UIWebView
    NSString *text = ((NSString * (*)(id, SEL, id))objc_msgSend)(
        webView, @selector(stringByEvaluatingJavaScriptFromString:), kFGPageTextJavaScript);
    if (text.length > 0) {
        [self handlePageText:text source:@"UIWebView"];
    }
}

- (void)handlePageText:(NSString *)text source:(NSString *)source
{
    if (text.length == 0) {
        return;
    }

    double latitude = 0, longitude = 0;
    if (!FGParseWarehouseCoordinate(text, &latitude, &longitude)) {
        // 后台页面没抓到：打印开头内容，用于判断是否被踢到登录页
        if (_backgroundWebView != nil) {
            NSTimeInterval now = [NSDate date].timeIntervalSince1970;
            if (now - _lastDiagLogTime > 10.0) {
                _lastDiagLogTime = now;
                NSString *head = text.length > 160 ? [text substringToIndex:160] : text;
                NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
                NSMutableString *hex = [NSMutableString stringWithCapacity:headData.length * 2];
                const unsigned char *bytes = headData.bytes;
                for (NSUInteger i = 0; i < headData.length; i++) {
                    [hex appendFormat:@"%02x", bytes[i]];
                }
                NSLog(@"[FakeGPS] bg page has no warehouse anchor, len=%lu, head_hex=%@",
                      (unsigned long)text.length, hex);
            }
        }
        return;
    }

    NSString *key = [NSString stringWithFormat:@"%.7f,%.7f", latitude, longitude];
    if ([key isEqualToString:_lastCoordinateKey]) {
        return;
    }
    _lastCoordinateKey = key;
    _lastCoordinateTime = [NSDate date].timeIntervalSince1970;
    _done = YES;   // 成功即停

    NSLog(@"[FakeGPS] coords captured by %@ (%f, %f)", source, latitude, longitude);
    [self overrideDeviceLocationWithLatitude:latitude longitude:longitude];
}

- (void)overrideDeviceLocationWithLatitude:(double)latitude longitude:(double)longitude
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setDouble:latitude forKey:kLatitudeKey];
    [defaults setDouble:longitude forKey:kLongitudeKey];
    [defaults setBool:YES forKey:kLocationSpoofingEnabled];
    [defaults synchronize];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"LocationSpoofingChanged" object:nil];
    NSLog(@"[FakeGPS] device location overridden (%f, %f)", latitude, longitude);
}

#pragma mark 后台静默加载

- (void)maybeStartBackgroundFetch
{
    if (_done) {
        return;   // 本次会话已成功，停止一切拉取
    }
    if (![self isEnabled] || _backgroundWebView != nil) {
        return;
    }

    // 只允许用「本次会话（登录之后）」注入的 token；登录界面阶段一律不动作
    NSTimeInterval injectTime =
        [[NSUserDefaults standardUserDefaults] doubleForKey:kFGLastInjectTimeKey];
    if (injectTime <= 0 || injectTime < gFGLaunchTime) {
        return;
    }
    if (_lastCoordinateTime > 0 &&
        ([NSDate date].timeIntervalSince1970 - _lastCoordinateTime) < kFGSuccessCooldown) {
        return;
    }
    NSTimeInterval throttle = MIN(kFGBackgroundThrottle + 15.0 * (double)_bgFailCount, 120.0);
    if (([NSDate date].timeIntervalSince1970 - _lastBackgroundFetchTime) < throttle) {
        return;
    }
    NSString *urlString = [[NSUserDefaults standardUserDefaults] stringForKey:kFGLastH5URLKey];
    if (!FGIsAddressPageURL(urlString)) {
        urlString = kFGDefaultAddressURL;
        NSLog(@"[FakeGPS] use builtin address URL");
    }

    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    Class wvClass   = NSClassFromString(@"WKWebView");
    Class cfgClass  = NSClassFromString(@"WKWebViewConfiguration");
    Class storeClass = NSClassFromString(@"WKWebsiteDataStore");
    if (window == nil || wvClass == Nil || cfgClass == Nil) {
        return;
    }

    id config = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(cfgClass, @selector(alloc)), @selector(init));
    if (storeClass != Nil) {
        id store = ((id (*)(id, SEL))objc_msgSend)(storeClass, @selector(defaultDataStore));
        ((void (*)(id, SEL, id))objc_msgSend)(config, @selector(setWebsiteDataStore:), store);
    }

    // 重放 App 用 WKUserScript 注入的用户信息
    NSString *userScriptSource =
        [[NSUserDefaults standardUserDefaults] stringForKey:kFGLastUserScriptKey];
    Class usClass = NSClassFromString(@"WKUserScript");
    if (userScriptSource.length > 0 && usClass != Nil) {
        id script = ((id (*)(id, SEL, NSString *, NSInteger, BOOL))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)(usClass, @selector(alloc)),
            @selector(initWithSource:injectionTime:forMainFrameOnly:),
            userScriptSource, 0, YES);
        id ucc = ((id (*)(id, SEL))objc_msgSend)(config, @selector(userContentController));
        ((void (*)(id, SEL, id))objc_msgSend)(ucc, @selector(addUserScript:), script);
        NSLog(@"[FakeGPS] replay WKUserScript (%lu bytes)", (unsigned long)userScriptSource.length);
    }

    // 重放 App 用 evaluateJavaScript 注入的用户信息（改为 documentStart，避免页面先跑起来）
    NSString *injectJSAtStart = [[NSUserDefaults standardUserDefaults] stringForKey:kFGLastInjectJSKey];
    if (injectJSAtStart.length > 0 && usClass != Nil) {
        id script = ((id (*)(id, SEL, NSString *, NSInteger, BOOL))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)(usClass, @selector(alloc)),
            @selector(initWithSource:injectionTime:forMainFrameOnly:),
            injectJSAtStart, 0, YES);
        id ucc = ((id (*)(id, SEL))objc_msgSend)(config, @selector(userContentController));
        ((void (*)(id, SEL, id))objc_msgSend)(ucc, @selector(addUserScript:), script);
        NSLog(@"[FakeGPS] replay injected JS at documentStart (%lu bytes)",
              (unsigned long)injectJSAtStart.length);
    }

    // 重放 App 注册的 JS 桥 handler（H5 靠它向原生要用户信息）
    if (gFGMessageHandlers.count > 0) {
        id ucc = ((id (*)(id, SEL))objc_msgSend)(config, @selector(userContentController));
        NSArray *names = gFGMessageHandlers.allKeys;
        for (NSString *name in names) {
            ((void (*)(id, SEL, id, NSString *))objc_msgSend)(
                ucc, @selector(addScriptMessageHandler:name:), gFGMessageHandlers[name], name);
        }
        NSLog(@"[FakeGPS] replay %lu message handlers", (unsigned long)names.count);
    }

    id webView = ((id (*)(id, SEL, CGRect, id))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(wvClass, @selector(alloc)),
        @selector(initWithFrame:configuration:),
        CGRectMake(0, -10, 1, 1),
        config);

    if (gFGCustomUserAgent.length > 0) {
        ((void (*)(id, SEL, id))objc_msgSend)(webView, @selector(setCustomUserAgent:),
                                              gFGCustomUserAgent);
    }

    _backgroundWebView = webView;
    _lastBackgroundFetchTime = [NSDate date].timeIntervalSince1970;

    UIView *container = (UIView *)webView;
    container.alpha = 0.01;
    container.userInteractionEnabled = NO;
    [window addSubview:container];

    NSURL *url = [NSURL URLWithString:urlString];
    ((void (*)(id, SEL, id))objc_msgSend)(webView, @selector(loadRequest:),
                                          [NSURLRequest requestWithURL:url]);
    NSLog(@"[FakeGPS] bg load address page: %@", urlString);

    // 重放 App 用 evaluateJavaScript 注入的用户信息
    NSString *injectJS = [[NSUserDefaults standardUserDefaults] stringForKey:kFGLastInjectJSKey];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (injectJS.length > 0 && self->_backgroundWebView != nil) {
            gFGInternalJS = YES;
            ((void (*)(id, SEL, id, id))objc_msgSend)(self->_backgroundWebView,
                                                      @selector(evaluateJavaScript:completionHandler:),
                                                      injectJS, nil);
            gFGInternalJS = NO;
            NSLog(@"[FakeGPS] replay inject JS after 2s (%lu bytes)", (unsigned long)injectJS.length);
        }
    });

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFGBackgroundLifetime * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf teardownBackgroundWebView];
    });
}

- (void)requestImmediateBackgroundFetch
{
    _lastBackgroundFetchTime = 0;   // 绕过节流：登录后拿到新 token 应立刻重试
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf maybeStartBackgroundFetch];
    });
}

- (void)teardownBackgroundWebView
{
    if (_backgroundWebView == nil) {
        return;
    }
    [(UIView *)_backgroundWebView removeFromSuperview];
    _backgroundWebView = nil;

    BOOL gotRecently = (_lastCoordinateTime > 0) &&
                       ([NSDate date].timeIntervalSince1970 - _lastCoordinateTime < 30.0);
    _bgFailCount = gotRecently ? 0 : (_bgFailCount + 1);
    NSLog(@"[FakeGPS] bg page recycled (consecutive fails=%d)", _bgFailCount);
}

#pragma mark 钩子安装

- (void)installWebKitHooksIfNeeded
{
    if (gFGWebHooked) {
        return;
    }
    Class wk = NSClassFromString(@"WKWebView");
    if (wk == Nil) {
        return;
    }

    MSHookMessageEx(wk, @selector(loadRequest:),
                    (IMP)hooked_loadRequest, (IMP *)&orig_loadRequest);
    MSHookMessageEx(wk, @selector(evaluateJavaScript:completionHandler:),
                    (IMP)hooked_evaluateJS, (IMP *)&orig_evaluateJS);

    Class ucc = NSClassFromString(@"WKUserContentController");
    if (ucc != Nil) {
        MSHookMessageEx(ucc, @selector(addUserScript:),
                        (IMP)hooked_addUserScript, (IMP *)&orig_addUserScript);
        MSHookMessageEx(ucc, @selector(addScriptMessageHandler:name:),
                        (IMP)hooked_addMessageHandler, (IMP *)&orig_addMessageHandler);
    }

    Class wv = NSClassFromString(@"WKWebView");
    if (wv != Nil) {
        MSHookMessageEx(wv, @selector(setCustomUserAgent:),
                        (IMP)hooked_setCustomUserAgent, (IMP *)&orig_setCustomUserAgent);
    }

    gFGWebHooked = YES;
    NSLog(@"[FakeGPS] WebKit hooks installed");
}

@end

#pragma mark - 钩子实现

static void hooked_loadRequest(id self, SEL _cmd, NSURLRequest *request)
{
    orig_loadRequest(self, _cmd, request);

    if (gFGInternalJS) {
        return;
    }

    NSString *url = request.URL.absoluteString;
    if (!FGIsAddressPageURL(url)) {
        return;   // 非《门店地址》页（扫码、反馈等）一律忽略
    }

    NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:kFGLastH5URLKey];
    if (![url isEqualToString:last]) {
        [[NSUserDefaults standardUserDefaults] setObject:url forKey:kFGLastH5URLKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        NSLog(@"[FakeGPS] captured address URL: %@", url);
    }

    // 用户已打开《门店地址》页 → 也给后台拉取一次机会（成功即停）
    [[FGAutoAddressController sharedController] requestImmediateBackgroundFetch];
}

static void hooked_evaluateJS(id self, SEL _cmd, NSString *script, id completion)
{
    if (!gFGInternalJS && script.length > 0 && script.length < 30000 &&
        ([script containsString:@"userInfo"] ||
         [script containsString:@"localStorage"] ||
         [script containsString:@"sessionStorage"])) {

        NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:kFGLastInjectJSKey];
        if (![script isEqualToString:last]) {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            [defaults setObject:script forKey:kFGLastInjectJSKey];
            [defaults setDouble:[NSDate date].timeIntervalSince1970 forKey:kFGLastInjectTimeKey];
            [defaults synchronize];
            NSLog(@"[FakeGPS] captured inject JS (%lu bytes), token is fresh for this session",
                  (unsigned long)script.length);

            // 新 token 到手 → 立刻重试后台拉取（绕过节流）
            [[FGAutoAddressController sharedController] requestImmediateBackgroundFetch];
        }
    }

    orig_evaluateJS(self, _cmd, script, completion);
}

static void hooked_addUserScript(id self, SEL _cmd, id userScript)
{
    if (!gFGInternalJS && userScript != nil) {
        NSString *source = ((NSString * (*)(id, SEL))objc_msgSend)(userScript, @selector(source));
        if (source.length > 0 && source.length < 30000 &&
            ([source containsString:@"userInfo"] ||
             [source containsString:@"localStorage"] ||
             [source containsString:@"sessionStorage"])) {

            NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:kFGLastUserScriptKey];
            if (![source isEqualToString:last]) {
                [[NSUserDefaults standardUserDefaults] setObject:source forKey:kFGLastUserScriptKey];
                [[NSUserDefaults standardUserDefaults] synchronize];
                NSLog(@"[FakeGPS] captured WKUserScript (%lu bytes)", (unsigned long)source.length);
            }
        }
    }

    orig_addUserScript(self, _cmd, userScript);
}

static void hooked_addMessageHandler(id self, SEL _cmd, id handler, NSString *name)
{
    if (name.length > 0 && handler != nil && ![name isEqualToString:@"fakegps"]) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            gFGMessageHandlers = [NSMutableDictionary dictionary];
        });
        if (gFGMessageHandlers[name] == nil) {
            gFGMessageHandlers[name] = handler;
            NSLog(@"[FakeGPS] captured message handler: %@", name);
        }
    }
    orig_addMessageHandler(self, _cmd, handler, name);
}

static void hooked_setCustomUserAgent(id self, SEL _cmd, NSString *userAgent)
{
    if (userAgent.length > 0 && userAgent.length < 2000 &&
        ![userAgent isEqualToString:gFGCustomUserAgent]) {
        gFGCustomUserAgent = [userAgent copy];
        NSLog(@"[FakeGPS] captured UA: %@", userAgent);
    }
    orig_setCustomUserAgent(self, _cmd, userAgent);
}

#pragma mark - 安装

static void (*orig_viewDidAppear)(id, SEL, BOOL);

static void hooked_viewDidAppear(id self, SEL _cmd, BOOL animated)
{
    orig_viewDidAppear(self, _cmd, animated);
    [[FGAutoAddressController sharedController] handleAppearanceOf:self];
}

void FGAutoAddressInstall(void)
{
    gFGLaunchTime = [NSDate date].timeIntervalSince1970;

    MSHookMessageEx(objc_getClass("UIViewController"), @selector(viewDidAppear:),
                    (IMP)hooked_viewDidAppear, (IMP *)&orig_viewDidAppear);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[FGAutoAddressController sharedController] startObservation];
    });
}
