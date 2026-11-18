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

// 实测日志：https://storeapp.ausnutria.com/dms2storeh5/#/?routerPath=/storeAddressUpdate&isNative=Y
static NSString *const kFGDefaultAddressURL =
    @"https://storeapp.ausnutria.com/dms2storeh5/#/?routerPath=/storeAddressUpdate&isNative=Y";

// 取页面纯文本（DOM 里就是「门店营业地址 / 仓库地址 / 经纬度」这些行）
static NSString *const kFGPageTextJavaScript =
    @"(function(){try{var b=document.body?document.body.innerText:'';"
     "return b.substring(0,20000);}catch(e){return '';}})()";

static const NSTimeInterval kFGScanInterval        = 3.0;    // 轮询 DOM 间隔
static const NSTimeInterval kFGBackgroundThrottle  = 60.0;   // 两次后台拉取最小间隔
static const NSTimeInterval kFGSuccessCooldown     = 600.0;  // 成功后冷却
static const NSTimeInterval kFGBackgroundLifetime  = 25.0;   // 后台 WebView 存活时长

static BOOL gFGInternalJS = NO;   // 我们自己发起的 evaluateJavaScript，不参与抓取
static BOOL gFGWebHooked  = NO;

static void (*orig_loadRequest)(id, SEL, id);
static void (*orig_evaluateJS)(id, SEL, NSString *, id);
static void (*orig_addUserScript)(id, SEL, id);

static void hooked_loadRequest(id self, SEL _cmd, NSURLRequest *request);
static void hooked_evaluateJS(id self, SEL _cmd, NSString *script, id completion);
static void hooked_addUserScript(id self, SEL _cmd, id userScript);

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

// 定位「仓库地址」这一段，再从其后的文本里取第一对经纬度
static BOOL FGParseWarehouseCoordinate(NSString *text, double *latitude, double *longitude)
{
    NSRange anchor = [text rangeOfString:@"仓库地址"];
    if (anchor.location == NSNotFound) {
        return NO;
    }

    NSUInteger start = anchor.location + anchor.length;
    NSUInteger tailLength = MIN((NSUInteger)1200, text.length - start);
    NSString *tail = [text substringWithRange:NSMakeRange(start, tailLength)];

    return FGParseCoordinate(tail, latitude, longitude);
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
- (void)teardownBackgroundWebView;
- (void)overrideDeviceLocationWithLatitude:(double)latitude longitude:(double)longitude;
@end

@implementation FGAutoAddressController
{
    id _backgroundWebView;
    NSTimeInterval _lastBackgroundFetchTime;
    NSTimeInterval _lastCoordinateTime;
    NSTimeInterval _lastDiagLogTime;
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

        NSLog(@"[FakeGPS] 观测已启动");
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
                NSString *head = text.length > 200 ? [text substringToIndex:200] : text;
                head = [head stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
                NSLog(@"[FakeGPS] 后台页面未见仓库地址(len=%lu): %@",
                      (unsigned long)text.length, head);
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

    NSLog(@"[FakeGPS] %@ 捕获仓库坐标 (%f, %f)", source, latitude, longitude);
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
    NSLog(@"[FakeGPS] 设备位置已覆盖为仓库坐标 (%f, %f)", latitude, longitude);
}

#pragma mark 后台静默加载

- (void)maybeStartBackgroundFetch
{
    if (![self isEnabled] || _backgroundWebView != nil) {
        return;
    }
    if (_lastCoordinateTime > 0 &&
        ([NSDate date].timeIntervalSince1970 - _lastCoordinateTime) < kFGSuccessCooldown) {
        return;
    }
    if (([NSDate date].timeIntervalSince1970 - _lastBackgroundFetchTime) < kFGBackgroundThrottle) {
        return;
    }

    NSString *urlString = [[NSUserDefaults standardUserDefaults] stringForKey:kFGLastH5URLKey];
    if (!FGIsAddressPageURL(urlString)) {
        urlString = kFGDefaultAddressURL;
        NSLog(@"[FakeGPS] 使用内置地址页 URL");
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
        NSLog(@"[FakeGPS] 重放 WKUserScript(%lu 字节)", (unsigned long)userScriptSource.length);
    }

    id webView = ((id (*)(id, SEL, CGRect, id))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(wvClass, @selector(alloc)),
        @selector(initWithFrame:configuration:),
        CGRectMake(0, -10, 1, 1),
        config);

    _backgroundWebView = webView;
    _lastBackgroundFetchTime = [NSDate date].timeIntervalSince1970;

    UIView *container = (UIView *)webView;
    container.alpha = 0.01;
    container.userInteractionEnabled = NO;
    [window addSubview:container];

    NSURL *url = [NSURL URLWithString:urlString];
    ((void (*)(id, SEL, id))objc_msgSend)(webView, @selector(loadRequest:),
                                          [NSURLRequest requestWithURL:url]);
    NSLog(@"[FakeGPS] 后台加载地址页: %@", urlString);

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
            NSLog(@"[FakeGPS] 重放注入脚本(%lu 字节)", (unsigned long)injectJS.length);
        }
    });

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFGBackgroundLifetime * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf teardownBackgroundWebView];
    });
}

- (void)teardownBackgroundWebView
{
    if (_backgroundWebView == nil) {
        return;
    }
    [(UIView *)_backgroundWebView removeFromSuperview];
    _backgroundWebView = nil;
    NSLog(@"[FakeGPS] 后台页面已回收");
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
    }

    gFGWebHooked = YES;
    NSLog(@"[FakeGPS] WebKit 钩子已安装");
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
        NSLog(@"[FakeGPS] 记录地址页 URL: %@", url);
    }
}

static void hooked_evaluateJS(id self, SEL _cmd, NSString *script, id completion)
{
    if (!gFGInternalJS && script.length > 0 && script.length < 30000 &&
        ([script containsString:@"userInfo"] ||
         [script containsString:@"localStorage"] ||
         [script containsString:@"sessionStorage"])) {

        NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:kFGLastInjectJSKey];
        if (![script isEqualToString:last]) {
            [[NSUserDefaults standardUserDefaults] setObject:script forKey:kFGLastInjectJSKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
            NSLog(@"[FakeGPS] 记录注入脚本(%lu 字节)", (unsigned long)script.length);
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
                NSLog(@"[FakeGPS] 记录 WKUserScript(%lu 字节)", (unsigned long)source.length);
            }
        }
    }

    orig_addUserScript(self, _cmd, userScript);
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
    MSHookMessageEx(objc_getClass("UIViewController"), @selector(viewDidAppear:),
                    (IMP)hooked_viewDidAppear, (IMP *)&orig_viewDidAppear);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[FGAutoAddressController sharedController] startObservation];
    });
}
