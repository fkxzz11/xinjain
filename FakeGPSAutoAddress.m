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
static NSString *const kFGLastTokenKey      = @"FGLastToken";
static NSString *const kFGLastTokenTimeKey  = @"FGLastTokenTime";

// 进程启动时间：用于判断 token 是不是本次会话（登录后）注入的
static NSTimeInterval gFGLaunchTime = 0;

// 从 RN 接口请求头里抓到的鉴权 token（登录后即出现，不依赖打开 H5）
static NSString *gFGToken = nil;
static void (*orig_setValue)(id, SEL, NSString *, NSString *);
static void hooked_setValue(id self, SEL _cmd, NSString *value, NSString *field);

static void (*orig_initWithConfig)(id, SEL, CGRect, id);
static void hooked_initWithConfig(id self, SEL _cmd, CGRect frame, id configuration);

// 实测日志：https://storeapp.ausnutria.com/dms2storeh5/#/?routerPath=/storeAddressUpdate&isNative=Y
static NSString *const kFGDefaultAddressURL =
    @"https://storeapp.ausnutria.com/dms2storeh5/#/?routerPath=/storeAddressUpdate&isNative=Y";

// 只在 documentStart 安装的嗅探器（由 initWithFrame:configuration: 钩子注入，
// 保证页面发出的第一个 XHR/fetch 就被劫持，不会因为探针注入太晚而漏掉）
static NSString *const kFGSnifferJavaScript =
    @"(function(){try{"
     "if(window.__fgNet){return 'ok';}"
     "window.__fgNet=[];"
     "var push=function(u,s,b,h){try{window.__fgNet.push({u:u,s:s,b:(b||'').substring(0,20000),h:h||{}});"
     "if(window.__fgNet.length>30){window.__fgNet.shift();}}catch(e){}};"
     "var X=window.XMLHttpRequest;"
     "if(X&&X.prototype){var op=X.prototype.open,sd=X.prototype.send,sh=X.prototype.setRequestHeader;"
     "X.prototype.open=function(m,u){this.__fgUrl=u;this.__fgH={};return op.apply(this,arguments);};"
     "X.prototype.setRequestHeader=function(k,v){try{this.__fgH=this.__fgH||{};this.__fgH[k]=v;}catch(e){}"
     "return sh.apply(this,arguments);};"
     "X.prototype.send=function(){var self=this;"
     "this.addEventListener('load',function(){push(self.__fgUrl,self.status,self.responseText,self.__fgH);});"
     "return sd.apply(this,arguments);};}"
     "if(window.fetch){var f=window.fetch;window.fetch=function(){"
     "var u=(arguments[0]&&arguments[0].url)||arguments[0];"
     "return f.apply(this,arguments).then(function(r){var c=r.clone();"
     "c.text().then(function(t){push(u,r.status,t,{});});return r;});};}"
     "return 'ok';}catch(e){return '';}})()";

// 探针：补装嗅探器（幂等）并一次性返回 { t: 页面文本, n: [ {u,s,b,h} ] }
static NSString *const kFGPageTextJavaScript =
    @"(function(){try{"
     "if(!window.__fgNet){window.__fgNet=[];"
     "var push=function(u,s,b,h){try{window.__fgNet.push({u:u,s:s,b:(b||'').substring(0,20000),h:h||{}});"
     "if(window.__fgNet.length>30){window.__fgNet.shift();}}catch(e){}};"
     "var X=window.XMLHttpRequest;"
     "if(X&&X.prototype){var op=X.prototype.open,sd=X.prototype.send,sh=X.prototype.setRequestHeader;"
     "X.prototype.open=function(m,u){this.__fgUrl=u;this.__fgH={};return op.apply(this,arguments);};"
     "X.prototype.setRequestHeader=function(k,v){try{this.__fgH=this.__fgH||{};this.__fgH[k]=v;}catch(e){}"
     "return sh.apply(this,arguments);};"
     "X.prototype.send=function(){var self=this;"
     "this.addEventListener('load',function(){push(self.__fgUrl,self.status,self.responseText,self.__fgH);});"
     "return sd.apply(this,arguments);};}"
     "if(window.fetch){var f=window.fetch;window.fetch=function(){"
     "var u=(arguments[0]&&arguments[0].url)||arguments[0];"
     "return f.apply(this,arguments).then(function(r){var c=r.clone();"
     "c.text().then(function(t){push(u,r.status,t);});return r;});};}}"
     "var t=document.body?document.body.innerText:'';"
     "var e=document.querySelectorAll('input,textarea');"
     "var s='\\n##INPUTS##\\n';"
     "for(var i=0;i<e.length;i++){s+='['+i+'] '+(e[i].placeholder||'')+' = '+(e[i].value||'')+'\\n';}"
     "return JSON.stringify({t:(t+s).substring(0,30000),n:window.__fgNet||[]});"
     "}catch(e){return '';}})()";

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
// 把缓存的注入脚本里的旧 token 换成本次会话抓到的新 token
static NSString *FGPatchedInjectJS(NSString *js, NSString *token)
{
    if (js.length == 0 || token.length == 0) {
        return js;
    }

    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:
                 @"((?:token|Token|TOKEN|authorization|Authorization|ticket|Ticket|jsessionid|JSESSIONID)"
                 @"\\s*[:=]\\s*[\"'])[^\"']+([\"'])"
                                                        options:0
                                                          error:nil];
    });

    NSString *replacement = [NSString stringWithFormat:@"$1%@$2", token];
    return [regex stringByReplacingMatchesInString:js
                                           options:0
                                             range:NSMakeRange(0, js.length)
                                      withTemplate:replacement];
}

// 把 JS 里的 \uXXXX 转义还原成中文（数据桥回写的 JSON 常被转义）—— 前置声明
static NSString *FGUnescapeUnicode(NSString *text);

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
- (void)handleProbeResult:(NSString *)json;
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
    NSTimeInterval _lastNetLogTime;
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
                [weakSelf handleProbeResult:(NSString *)result];
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
        [self handleProbeResult:text];
    }
}

// 解析探针返回的 {t:页面文本, n:[{u,s,b}]}
- (void)handleProbeResult:(NSString *)json
{
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;

    if (![obj isKindOfClass:[NSDictionary class]]) {
        [self handlePageText:json source:@"WKWebView"];
        return;
    }

    NSString *text = ((NSDictionary *)obj)[@"t"];
    NSArray *nets = ((NSDictionary *)obj)[@"n"];

    // 先看接口（即使文本已解析成功也打印一次，便于确认真实 API 与请求头）
    if ([nets isKindOfClass:[NSArray class]] && nets.count > 0) {
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (now - _lastNetLogTime > 30.0) {
            _lastNetLogTime = now;
            NSMutableString *brief = [NSMutableString string];
            for (NSDictionary *item in nets) {
                if (![item isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                NSString *u = item[@"u"];
                NSString *b = item[@"b"];
                NSDictionary *h = item[@"h"];
                NSString *hkeys = @"";
                if ([h isKindOfClass:[NSDictionary class]] && h.count > 0) {
                    hkeys = [[h allKeys] componentsJoinedByString:@","];
                }
                if ([u isKindOfClass:[NSString class]]) {
                    [brief appendFormat:@"%@(b=%lu,h=%@) ",
                     u,
                     (unsigned long)([b isKindOfClass:[NSString class]] ? b.length : 0),
                     hkeys];
                }
            }
            NSLog(@"[FakeGPS] xhr count=%lu %@", (unsigned long)nets.count, brief);
        }
    }

    if ([text isKindOfClass:[NSString class]] && text.length > 0) {
        [self handlePageText:text source:@"WKWebView"];
    }

    if (_done) {
        return;
    }

    if (![nets isKindOfClass:[NSArray class]] || nets.count == 0) {
        return;
    }

    for (NSDictionary *item in nets) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *body = item[@"b"];
        NSString *url = item[@"u"];
        if (![body isKindOfClass:[NSString class]] || body.length == 0) {
            continue;
        }

        double lat = 0, lng = 0;
        NSString *decoded = FGUnescapeUnicode(body);
        if (FGParseWarehouseCoordinate(decoded, &lat, &lng)) {
            NSLog(@"[FakeGPS] coords found in xhr: %@", url);
            NSString *synthetic = [NSString stringWithFormat:@"仓库地址 %f,%f", lat, lng];
            [self handlePageText:synthetic source:@"xhr"];
            break;
        }
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

    // 本次会话是否已具备条件：要么抓到新注入脚本，要么抓到接口 token
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSTimeInterval injectTime = [defaults doubleForKey:kFGLastInjectTimeKey];
    NSTimeInterval tokenTime  = [defaults doubleForKey:kFGLastTokenTimeKey];
    BOOL freshInject = (injectTime >= gFGLaunchTime && injectTime > 0);
    BOOL freshToken  = (tokenTime >= gFGLaunchTime && tokenTime > 0);
    if (!freshInject && !freshToken) {
        return;   // 登录界面阶段：不动作
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
    NSString *token = gFGToken;
    if (token.length == 0) {
        token = [defaults stringForKey:kFGLastTokenKey];
    }
    NSString *injectJSAtStart =
        FGPatchedInjectJS([defaults stringForKey:kFGLastInjectJSKey], token);
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
    NSString *injectJS = injectJSAtStart;
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
        MSHookMessageEx(wv, @selector(initWithFrame:configuration:),
                        (IMP)hooked_initWithConfig, (IMP *)&orig_initWithConfig);
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

// 把 JS 里的 \uXXXX 转义还原成中文（数据桥回写的 JSON 常被转义）
static NSString *FGUnescapeUnicode(NSString *text)
{
    if (text.length == 0 || [text rangeOfString:@"\\u"].location == NSNotFound) {
        return text;
    }

    NSMutableString *out = [NSMutableString stringWithCapacity:text.length];
    NSUInteger i = 0, n = text.length;
    while (i < n) {
        unichar c = [text characterAtIndex:i];
        if (c == '\\' && i + 5 < n && [text characterAtIndex:i + 1] == 'u') {
            NSString *hex = [text substringWithRange:NSMakeRange(i + 2, 4)];
            unsigned int code = 0;
            if ([[NSScanner scannerWithString:hex] scanHexInt:&code] && code > 0) {
                [out appendFormat:@"%C", (unichar)code];
                i += 6;
                continue;
            }
        }
        [out appendFormat:@"%C", c];
        i++;
    }
    return out;
}

static void hooked_evaluateJS(id self, SEL _cmd, NSString *script, id completion)
{
    if (!gFGInternalJS && script.length > 0 && script.length < 200000) {

        // ① 用户信息类脚本：缓存下来供后台重放
        if (script.length < 30000 &&
            ([script containsString:@"userInfo"] ||
             [script containsString:@"localStorage"] ||
             [script containsString:@"sessionStorage"])) {

            NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:kFGLastInjectJSKey];
            if (![script isEqualToString:last]) {
                NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                [defaults setObject:script forKey:kFGLastInjectJSKey];
                [defaults setDouble:[NSDate date].timeIntervalSince1970 forKey:kFGLastInjectTimeKey];
                [defaults synchronize];
                NSLog(@"[FakeGPS] captured inject JS (%lu bytes)", (unsigned long)script.length);

                [[FGAutoAddressController sharedController] requestImmediateBackgroundFetch];
            }
        }

        // ② 数据桥嗅探：原生把接口 JSON 注入页面时，这里能直接抓到坐标
        //    中文可能是原文，也可能是 \uXXXX 转义
        BOOL hasAnchor = [script containsString:@"仓库地址"] ||
                         [script containsString:@"\\u4ed3\\u5e93"] ||
                         ([script containsString:@"lat"] && [script containsString:@"lng"]);
        if (hasAnchor) {
            NSString *decoded = FGUnescapeUnicode(script);
            double lat = 0, lng = 0;
            if (FGParseWarehouseCoordinate(decoded, &lat, &lng)) {
                NSLog(@"[FakeGPS] coords found in injected script (%f, %f)", lat, lng);
                [[FGAutoAddressController sharedController]
                    handlePageText:[NSString stringWithFormat:@"仓库地址 %f,%f", lat, lng]
                            source:@"bridge"];
            } else {
                NSUInteger n = MIN((NSUInteger)300, script.length);
                NSData *d = [[script substringToIndex:n] dataUsingEncoding:NSUTF8StringEncoding];
                NSMutableString *hex = [NSMutableString stringWithCapacity:d.length * 2];
                const unsigned char *bytes = d.bytes;
                for (NSUInteger i = 0; i < d.length; i++) {
                    [hex appendFormat:@"%02x", bytes[i]];
                }
                NSLog(@"[FakeGPS] bridge script has anchor but no coords, len=%lu, hex=%@",
                      (unsigned long)script.length, hex);
            }
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

// WebView 创建时就把嗅探器塞进 documentStart，避免漏掉页面首个请求
static void hooked_initWithConfig(id self, SEL _cmd, CGRect frame, id configuration)
{
    if (configuration != nil) {
        Class usClass = NSClassFromString(@"WKUserScript");
        if (usClass != Nil) {
            id ucc = ((id (*)(id, SEL))objc_msgSend)(configuration,
                                                     @selector(userContentController));
            if (ucc != nil) {
                id script = ((id (*)(id, SEL, NSString *, NSInteger, BOOL))objc_msgSend)(
                    ((id (*)(id, SEL))objc_msgSend)(usClass, @selector(alloc)),
                    @selector(initWithSource:injectionTime:forMainFrameOnly:),
                    kFGSnifferJavaScript, 0, YES);
                ((void (*)(id, SEL, id))objc_msgSend)(ucc, @selector(addUserScript:), script);
            }
        }
    }

    orig_initWithConfig(self, _cmd, frame, configuration);
}

#pragma mark - 安装

static void (*orig_viewDidAppear)(id, SEL, BOOL);

static void hooked_viewDidAppear(id self, SEL _cmd, BOOL animated)
{
    orig_viewDidAppear(self, _cmd, animated);
    [[FGAutoAddressController sharedController] handleAppearanceOf:self];
}

static void hooked_setValue(id self, SEL _cmd, NSString *value, NSString *field)
{
    if (value.length > 8 && value.length < 4096 && field.length > 0) {
        NSString *lower = field.lowercaseString;
        if ([lower containsString:@"token"] || [lower containsString:@"auth"] ||
            [lower containsString:@"ticket"] || [lower containsString:@"session"]) {

            if (![value isEqualToString:gFGToken]) {
                gFGToken = [value copy];
                NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                [defaults setObject:value forKey:kFGLastTokenKey];
                [defaults setDouble:[NSDate date].timeIntervalSince1970 forKey:kFGLastTokenTimeKey];
                [defaults synchronize];

                NSLog(@"[FakeGPS] captured auth header %@ (len=%lu)",
                      field, (unsigned long)value.length);
                [[FGAutoAddressController sharedController] requestImmediateBackgroundFetch];
            }
        }
    }

    orig_setValue(self, _cmd, value, field);
}

void FGAutoAddressInstall(void)
{
    gFGLaunchTime = [NSDate date].timeIntervalSince1970;

    // 抓 RN 接口请求头里的鉴权 token（登录后立刻就有，不依赖打开 H5）
    Class requestClass = NSClassFromString(@"NSMutableURLRequest");
    if (requestClass != Nil) {
        MSHookMessageEx(requestClass, @selector(setValue:forHTTPHeaderField:),
                        (IMP)hooked_setValue, (IMP *)&orig_setValue);
    }

    MSHookMessageEx(objc_getClass("UIViewController"), @selector(viewDidAppear:),
                    (IMP)hooked_viewDidAppear, (IMP *)&orig_viewDidAppear);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[FGAutoAddressController sharedController] startObservation];
    });
}
