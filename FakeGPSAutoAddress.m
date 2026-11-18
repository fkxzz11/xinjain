//
//  FakeGPSAutoAddress.m
//  FakeGPS.dylib  —— 新增功能：门店地址页自动用「仓库地址」覆盖当前设备位置
//
//  背景：
//    业务 App 的《门店地址》页把「门店营业地址 / 仓库地址」两组地址以表单行渲染
//    （省市区街道 / 详细地址 / 经纬度），其中「经纬度」行的值形如
//       34.80860925664227,114.46282467208921
//    本模块在该页出现时：
//      1. 从「仓库地址」分组里解析出经纬度；
//      2. 把经纬度写入 NSUserDefaults（latitude/longitude）并打开
//         LocationSpoofingEnabled —— 即“把当前实际设备位置覆盖为仓库地址”；
//      3. 把「门店营业地址」分组的各字段改成仓库地址的值；
//      4. 找到页面自带的「定位/获取位置」控件并触发，让页面用新位置刷新；
//      5. 可选地点「保存/提交」，完成原本要手动做的整条 UI 流程。
//
//  设计约束：
//    * 目标 App 二进制未知，因此不依赖任何类名/方法名，全部通过视图树 + 文案定位；
//    * 只在检测到「仓库地址」+ 坐标文本的页面上动作，其余控制器立即返回；
//    * 每次页面出现只处理一次（按 仓库坐标 + 控制器类名 去重），避免死循环；
//    * 两个开关放在 NSUserDefaults：
//        AutoAddressOverrideEnabled  默认 YES，关掉即完全停用本模块
//        AutoAddressSubmitEnabled    默认 YES，关掉则只填不点保存
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 该符号由 FakeGPSHooks.m 提供（runtime 等价实现，不链接 substrate）
void MSHookMessageEx(Class cls, SEL sel, IMP replacement, IMP *result);

static NSString *const kLatitudeKey             = @"latitude";
static NSString *const kLongitudeKey            = @"longitude";
static NSString *const kLocationSpoofingEnabled = @"LocationSpoofingEnabled";

static NSString *const kAutoOverrideEnabled = @"AutoAddressOverrideEnabled";
static NSString *const kAutoSubmitEnabled   = @"AutoAddressSubmitEnabled";

#pragma mark - 视图树文本采集

// 一条可见文本：来源控件、文本、窗口坐标系中的中点 y 与左边界 x
static NSDictionary *FGTextItem(UIView *view, NSString *text, UIView *window)
{
    CGRect frame = [view convertRect:view.bounds toView:window];
    return @{
        @"view" : view,
        @"text" : text ?: @"",
        @"y"    : @(CGRectGetMidY(frame)),
        @"x"    : @(CGRectGetMinX(frame)),
    };
}

static void FGCollectTextItems(UIView *root, UIView *window, NSMutableArray *out)
{
    if (root.isHidden || root.alpha < 0.01 || root.frame.size.height <= 0) {
        return;
    }

    NSString *text = nil;
    if ([root isKindOfClass:[UILabel class]]) {
        text = ((UILabel *)root).text;
    } else if ([root isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)root;
        text = field.text.length ? field.text : field.placeholder;
    } else if ([root isKindOfClass:[UITextView class]]) {
        text = ((UITextView *)root).text;
    } else if ([root isKindOfClass:[UIButton class]]) {
        text = [((UIButton *)root) titleForState:UIControlStateNormal];
    }

    if (text.length != 0) {
        [out addObject:FGTextItem(root, text, window)];
    }

    for (UIView *subview in root.subviews) {
        FGCollectTextItems(subview, window, out);
    }
}

static NSArray<NSDictionary *> *FGCollectItems(UIView *root)
{
    NSMutableArray *items = [NSMutableArray array];
    FGCollectTextItems(root, root.window ?: root, items);
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        CGFloat ya = [a[@"y"] doubleValue], yb = [b[@"y"] doubleValue];
        if (fabs(ya - yb) > 8.0) {
            return ya < yb ? NSOrderedAscending : NSOrderedDescending;
        }
        CGFloat xa = [a[@"x"] doubleValue], xb = [b[@"x"] doubleValue];
        return xa < xb ? NSOrderedAscending : NSOrderedDescending;
    }];
    return items;
}

#pragma mark - 坐标解析

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

    NSTextCheckingResult *match = [regex firstMatchInString:text
                                                   options:0
                                                     range:NSMakeRange(0, text.length)];
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

#pragma mark - 分组定位

static NSDictionary *FGHeaderItem(NSArray<NSDictionary *> *items, NSArray<NSString *> *keywords)
{
    for (NSDictionary *item in items) {
        NSString *text = item[@"text"];
        BOOL matched = YES;
        for (NSString *keyword in keywords) {
            if ([text rangeOfString:keyword].location == NSNotFound) {
                matched = NO;
                break;
            }
        }
        if (matched) {
            return item;
        }
    }
    return nil;
}

// 分组内的行：位于 header 之后、nextHeader 之前
static NSArray<NSDictionary *> *FGRowsInSection(NSArray<NSDictionary *> *items,
                                                NSDictionary *header,
                                                NSDictionary *nextHeader)
{
    if (header == nil) {
        return @[];
    }
    CGFloat top = [header[@"y"] doubleValue] + 2.0;
    CGFloat bottom = nextHeader ? [nextHeader[@"y"] doubleValue] - 2.0 : CGFLOAT_MAX;

    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *item in items) {
        CGFloat y = [item[@"y"] doubleValue];
        if (y > top && y < bottom) {
            [rows addObject:item];
        }
    }
    return rows;
}

// 在分组里按“标题文案”找到同一行的取值控件（标题右侧、同一 y 带内）
static NSDictionary *FGValueItemForTitle(NSArray<NSDictionary *> *rows, NSArray<NSString *> *titles)
{
    NSDictionary *titleItem = nil;
    for (NSDictionary *row in rows) {
        NSString *text = row[@"text"];
        for (NSString *title in titles) {
            if ([text isEqualToString:title] || [text hasPrefix:title]) {
                titleItem = row;
                break;
            }
        }
        if (titleItem) {
            break;
        }
    }
    if (titleItem == nil) {
        return nil;
    }

    CGFloat titleY = [titleItem[@"y"] doubleValue];
    CGFloat titleX = [titleItem[@"x"] doubleValue];

    NSDictionary *best = nil;
    CGFloat bestDelta = CGFLOAT_MAX;
    for (NSDictionary *row in rows) {
        if (row == titleItem) {
            continue;
        }
        if ([row[@"x"] doubleValue] <= titleX) {
            continue;
        }
        CGFloat delta = fabs([row[@"y"] doubleValue] - titleY);
        if (delta < 12.0 && delta < bestDelta) {
            bestDelta = delta;
            best = row;
        }
    }
    return best;
}

#pragma mark - 写值

static void FGSetItemText(NSDictionary *item, NSString *text)
{
    UIView *view = item[@"view"];
    if ([view isKindOfClass:[UILabel class]]) {
        ((UILabel *)view).text = text;
    } else if ([view isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)view;
        field.text = text;
        [field sendActionsForControlEvents:UIControlEventEditingChanged];
    } else if ([view isKindOfClass:[UITextView class]]) {
        ((UITextView *)view).text = text;
    }
}

static UIButton *FGFindButton(NSArray<NSDictionary *> *items, NSArray<NSString *> *titles)
{
    for (NSDictionary *item in items) {
        UIView *view = item[@"view"];
        if (![view isKindOfClass:[UIButton class]]) {
            continue;
        }
        NSString *text = item[@"text"];
        for (NSString *title in titles) {
            if ([text rangeOfString:title].location != NSNotFound) {
                return (UIButton *)view;
            }
        }
    }
    return nil;
}

// 导航栏按钮常常是 UIBarButtonItem 而不是视图树里的 UIButton，单独兜底
static BOOL FGTriggerBarButtonItem(UIViewController *viewController, NSArray<NSString *> *titles)
{
    NSMutableArray<UIBarButtonItem *> *candidates = [NSMutableArray array];
    if (viewController.navigationItem.rightBarButtonItem) {
        [candidates addObject:viewController.navigationItem.rightBarButtonItem];
    }
    if (viewController.navigationItem.leftBarButtonItem) {
        [candidates addObject:viewController.navigationItem.leftBarButtonItem];
    }

    for (UIBarButtonItem *item in candidates) {
        NSString *title = item.title;
        if (title.length == 0) {
            continue;
        }
        for (NSString *keyword in titles) {
            if ([title rangeOfString:keyword].location == NSNotFound) {
                continue;
            }
            if (item.target != nil && [item.target respondsToSelector:item.action]) {
                // 不用 performSelector:（ARC 下会触发 -Warc-performSelector-leaks，Theos 视为 error）
                ((void (*)(id, SEL, id))objc_msgSend)(item.target, item.action, item);
                return YES;
            }
        }
    }
    return NO;
}

#pragma mark - 控制器

// 前置声明（实现在文件末尾）
static BOOL FGParseWarehouseCoordinate(NSString *text, double *latitude, double *longitude);

@interface FGAutoAddressController : NSObject
+ (instancetype)sharedController;
- (void)handleAppearanceOf:(UIViewController *)viewController;
- (NSArray<NSDictionary *> *)itemsForViewController:(UIViewController *)viewController;
- (void)processViewController:(UIViewController *)viewController;
- (void)overrideDeviceLocationWithLatitude:(double)latitude longitude:(double)longitude;
- (void)copyRowsFromWarehouse:(NSArray<NSDictionary *> *)warehouseRows
                      toStore:(NSArray<NSDictionary *> *)storeRows
               coordinateText:(NSString *)coordinateText;
- (void)startWebObservation;
- (void)scanWebViews;
- (void)readTextFromWKWebView:(UIView *)webView;
- (void)handlePageText:(NSString *)text source:(NSString *)source;
- (void)installWebKitHooksIfNeeded;
- (void)maybeStartBackgroundFetch;
- (void)teardownBackgroundWebView;
@end

@implementation FGAutoAddressController
{
    NSString *_lastHandledKey;
    NSString *_lastWebCoordinateKey;
    id _backgroundWebView;
    NSTimeInterval _lastBackgroundFetchTime;
    NSTimeInterval _lastCoordinateTime;
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

- (void)handleAppearanceOf:(UIViewController *)viewController
{
    if (![self isEnabled] || viewController.view.window == nil) {
        return;
    }

    // 等页面布局 / 数据回填完成后再处理，避免读到空行
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf processViewController:viewController];
    });

    // 每次页面切换都给后台拉取一个机会（登录完成 → 首页也会触发），内部有 60s 节流
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf maybeStartBackgroundFetch];
    });
}

- (NSArray<NSDictionary *> *)itemsForViewController:(UIViewController *)viewController
{
    NSMutableArray *items = [NSMutableArray arrayWithArray:FGCollectItems(viewController.view)];

    UINavigationBar *navigationBar = viewController.navigationController.navigationBar;
    if (navigationBar != nil) {
        [items addObjectsFromArray:FGCollectItems(navigationBar)];
    }
    return items;
}

- (void)processViewController:(UIViewController *)viewController
{
    // 分组/行只从控制器自身的视图树读取，避免导航栏标题「门店地址」被误判为分组头
    NSArray<NSDictionary *> *items = FGCollectItems(viewController.view);
    NSArray<NSDictionary *> *allItems = [self itemsForViewController:viewController];

    NSDictionary *storeHeader = FGHeaderItem(items, @[ @"门店", @"地址" ]);
    NSDictionary *warehouseHeader = FGHeaderItem(items, @[ @"仓库地址" ]);
    if (warehouseHeader == nil) {
        return;   // 不是《门店地址》页
    }

    // 仓库分组：从「仓库地址」标题到下一个分组（或页面末尾）
    NSArray<NSDictionary *> *warehouseRows = FGRowsInSection(items, warehouseHeader, nil);

    // 在仓库分组内找坐标文本（优先「经纬度」行，其次任意可解析文本）
    NSDictionary *warehouseCoordinateItem = nil;
    NSString *coordinateText = nil;
    double latitude = 0, longitude = 0;

    NSDictionary *coordinateValue =
        FGValueItemForTitle(warehouseRows, @[ @"经纬度", @"坐标" ]);
    if (coordinateValue != nil &&
        FGParseCoordinate(coordinateValue[@"text"], &latitude, &longitude)) {
        warehouseCoordinateItem = coordinateValue;
        coordinateText = coordinateValue[@"text"];
    } else {
        for (NSDictionary *row in warehouseRows) {
            if (FGParseCoordinate(row[@"text"], &latitude, &longitude)) {
                warehouseCoordinateItem = row;
                coordinateText = row[@"text"];
                break;
            }
        }
    }

    if (warehouseCoordinateItem == nil) {
        return;   // 页面还没渲染出仓库坐标
    }

    NSString *key = [NSString stringWithFormat:@"%@|%@|%@",
                     NSStringFromClass(viewController.class),
                     @(latitude).stringValue,
                     @(longitude).stringValue];
    if ([key isEqualToString:_lastHandledKey]) {
        return;   // 同一页面同一坐标只处理一次
    }
    _lastHandledKey = key;

    NSLog(@"[FakeGPS] 门店地址页：捕获仓库坐标 (%f, %f)", latitude, longitude);

    // 1) 覆盖当前设备位置：写入 defaults 并打开位置模拟
    [self overrideDeviceLocationWithLatitude:latitude longitude:longitude];

    // 2) 把「门店营业地址」各字段替换为仓库地址的值
    NSArray<NSDictionary *> *storeRows = FGRowsInSection(items, storeHeader, warehouseHeader);
    [self copyRowsFromWarehouse:warehouseRows toStore:storeRows coordinateText:coordinateText];

    // 3) 触发页面自带的定位/获取位置控件，让其用新位置刷新
    UIButton *locateButton = FGFindButton(allItems, @[ @"定位", @"获取位置", @"获取当前位置",
                                                       @"重新定位", @"自动获取", @"刷新位置" ]);
    if (locateButton != nil) {
        [locateButton sendActionsForControlEvents:UIControlEventTouchUpInside];
    }

    // 4) 可选：点保存，完成整条流程
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id submitValue = [defaults objectForKey:kAutoSubmitEnabled];
    BOOL shouldSubmit = submitValue == nil ? YES : [defaults boolForKey:kAutoSubmitEnabled];

    if (shouldSubmit) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSArray<NSDictionary *> *refreshed = [weakSelf itemsForViewController:viewController];
            NSArray<NSString *> *saveTitles = @[ @"保存", @"提交", @"确定", @"确认修改" ];

            UIButton *saveButton = FGFindButton(refreshed, saveTitles);
            if (saveButton != nil) {
                NSLog(@"[FakeGPS] 门店地址页：自动提交按钮 %@", saveButton);
                [saveButton sendActionsForControlEvents:UIControlEventTouchUpInside];
            } else if (FGTriggerBarButtonItem(viewController, saveTitles)) {
                NSLog(@"[FakeGPS] 门店地址页：自动触发导航栏保存项");
            }
        });
    }
}

- (void)overrideDeviceLocationWithLatitude:(double)latitude longitude:(double)longitude
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setDouble:latitude  forKey:kLatitudeKey];
    [defaults setDouble:longitude forKey:kLongitudeKey];
    [defaults setBool:YES forKey:kLocationSpoofingEnabled];
    [defaults synchronize];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"LocationSpoofingChanged" object:nil];

    // 已存在的位置模拟管理器立即吃新坐标（下一次 -location 返回即为仓库位置）
    NSLog(@"[FakeGPS] 设备位置已覆盖为仓库坐标 (%f, %f)", latitude, longitude);
}

- (void)copyRowsFromWarehouse:(NSArray<NSDictionary *> *)warehouseRows
                      toStore:(NSArray<NSDictionary *> *)storeRows
               coordinateText:(NSString *)coordinateText
{
    if (storeRows.count == 0) {
        return;
    }

    NSArray<NSArray<NSString *> *> *rowTitles = @[
        @[ @"省市区街道", @"省市区" ],
        @[ @"详细地址" ],
        @[ @"经纬度", @"门店经纬度", @"坐标" ],
    ];

    for (NSArray<NSString *> *titles in rowTitles) {
        NSDictionary *storeValue = FGValueItemForTitle(storeRows, titles);
        if (storeValue == nil) {
            continue;
        }

        NSString *newText = nil;
        if ([titles containsObject:@"经纬度"] || [titles containsObject:@"坐标"]) {
            newText = coordinateText;
        } else {
            NSDictionary *warehouseValue = FGValueItemForTitle(warehouseRows, titles);
            newText = warehouseValue[@"text"];
        }

        if (newText.length != 0) {
            FGSetItemText(storeValue, newText);
            NSLog(@"[FakeGPS] 门店字段「%@」→ %@", titles.firstObject, newText);
        }
    }
}

#pragma mark - H5 / WebView 观测
//
// 该 App 是 React Native + WebView 混合体：《门店地址》页是 H5 页面
// （main.jsbundle 中「仓库」「省市区街道」出现 0 次，主程序含 WKWebView/evaluateJavaScript），
// 文字在 WebView 的 DOM 里，UILabel 扫描抓不到，因此注入 JS 读 innerText。

static NSString *const kFGPageTextJavaScript =
    @"(function(){try{"
     "var b=document.body?document.body.innerText:'';"
     "return b.substring(0,20000);"
     "}catch(e){return '';}})()";

// —— WKWebView 抓取 / 后台重放所需的全局状态 ——
static NSString *const kFGLastH5URLKey      = @"FGLastH5URL";
static NSString *const kFGLastH5InjectJSKey = @"FGLastH5InjectJS";
static NSString *const kFGLastUserScriptKey = @"FGLastUserScript";

// 门店地址页的固定路由（实测日志：/dms2storeh5/#/?routerPath=/storeAddressUpdate&isNative=Y）
static NSString *const kFGDefaultAddressURL =
    @"https://storeapp.ausnutria.com/dms2storeh5/#/?routerPath=/storeAddressUpdate&isNative=Y";

static BOOL gFGInternalJS = NO;          // 我们自己发起的 evaluateJavaScript，不参与抓取
static BOOL gFGWebHooked  = NO;

static void (*orig_WKWebView_loadRequest)(id, SEL, id);
static void (*orig_WKWebView_evaluateJS)(id, SEL, NSString *, id);
static void (*orig_WKUserContentController_addUserScript)(id, SEL, id);

static void hooked_WKWebView_loadRequest(id self, SEL _cmd, NSURLRequest *request);
static void hooked_WKWebView_evaluateJS(id self, SEL _cmd, NSString *script, id completion);
static void hooked_WKUserContentController_addUserScript(id self, SEL _cmd, id userScript);

- (void)startWebObservation
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSTimer *timer = [NSTimer timerWithTimeInterval:3.0
                                                repeats:YES
                                                  block:^(NSTimer *t) {
            [[FGAutoAddressController sharedController] scanWebViews];
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onAppDidBecomeActive)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        NSLog(@"[FakeGPS] WebView 观测已启动");
    });
}

- (void)onAppDidBecomeActive
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self scanWebViews];
    });
    // 登录/回前台后尝试后台静默拉取（不依赖用户点开页面）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self maybeStartBackgroundFetch];
    });
}

- (void)scanWebViews
{
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        return;
    }
    if (![self isEnabled]) {
        return;
    }

    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
    if (keyWindow == nil) {
        return;
    }

    [self installWebKitHooksIfNeeded];

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:keyWindow];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        NSString *className = NSStringFromClass(view.class);
        if ([className isEqualToString:@"WKWebView"]) {
            [self readTextFromWKWebView:view];
        } else if ([className isEqualToString:@"UIWebView"]) {
            NSString *text = ((NSString * (*)(id, SEL, id))objc_msgSend)(view,
                    @selector(stringByEvaluatingJavaScriptFromString:),
                    kFGPageTextJavaScript);
            if (text.length > 0) {
                [self handlePageText:text source:@"UIWebView"];
            }
        }

        if (view.subviews.count > 0) {
            [stack addObjectsFromArray:view.subviews];
        }
    }
}

- (void)readTextFromWKWebView:(UIView *)webView
{
    __weak typeof(self) weakSelf = self;
    id handler = ^(id result, NSError *error) {
        if (error != nil || ![result isKindOfClass:[NSString class]]) {
            return;
        }
        [weakSelf handlePageText:(NSString *)result source:@"WKWebView"];
    };

    gFGInternalJS = YES;
    ((void (*)(id, SEL, id, id))objc_msgSend)(webView,
                                              @selector(evaluateJavaScript:completionHandler:),
                                              kFGPageTextJavaScript,
                                              handler);
    gFGInternalJS = NO;
}

- (void)handlePageText:(NSString *)text source:(NSString *)source
{
    if (text.length == 0) {
        return;
    }

    double latitude = 0, longitude = 0;
    if (!FGParseWarehouseCoordinate(text, &latitude, &longitude)) {
        return;
    }

    NSString *key = [NSString stringWithFormat:@"%.7f,%.7f", latitude, longitude];
    if ([key isEqualToString:_lastWebCoordinateKey]) {
        return;   // 同一坐标不重复处理
    }
    _lastWebCoordinateKey = key;
    _lastCoordinateTime = [NSDate date].timeIntervalSince1970;

    NSLog(@"[FakeGPS] %@ 捕获仓库坐标 (%f, %f)", source, latitude, longitude);
    [self overrideDeviceLocationWithLatitude:latitude longitude:longitude];
}

#pragma mark - WKWebView 钩子：记录地址页 URL 与注入脚本

- (void)installWebKitHooksIfNeeded
{
    if (gFGWebHooked) {
        return;
    }
    Class wk = NSClassFromString(@"WKWebView");
    if (wk == Nil) {
        return;   // WebKit 尚未加载，等下一次扫描
    }

    MSHookMessageEx(wk, @selector(loadRequest:),
                    (IMP)hooked_WKWebView_loadRequest, (IMP *)&orig_WKWebView_loadRequest);
    MSHookMessageEx(wk, @selector(evaluateJavaScript:completionHandler:),
                    (IMP)hooked_WKWebView_evaluateJS, (IMP *)&orig_WKWebView_evaluateJS);

    Class ucc = NSClassFromString(@"WKUserContentController");
    if (ucc != Nil) {
        MSHookMessageEx(ucc, @selector(addUserScript:),
                        (IMP)hooked_WKUserContentController_addUserScript,
                        (IMP *)&orig_WKUserContentController_addUserScript);
    }

    gFGWebHooked = YES;
    NSLog(@"[FakeGPS] WKWebView 钩子已安装");
}

- (void)maybeStartBackgroundFetch
{
    if (![self isEnabled] || _backgroundWebView != nil) {
        return;
    }

    // 10 分钟内已成功拿到过坐标，不必反复拉
    if (_lastCoordinateTime > 0 &&
        ([NSDate date].timeIntervalSince1970 - _lastCoordinateTime) < 600.0) {
        return;
    }
    // 两次尝试至少间隔 60 秒
    if (([NSDate date].timeIntervalSince1970 - _lastBackgroundFetchTime) < 60.0) {
        return;
    }

    NSString *urlString = [[NSUserDefaults standardUserDefaults] stringForKey:kFGLastH5URLKey];
    if (urlString.length == 0) {
        urlString = kFGDefaultAddressURL;   // 路由固定，内置兜底
        NSLog(@"[FakeGPS] 尚无记录 URL，使用内置默认地址页 URL");
    }

    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    Class wvClass = NSClassFromString(@"WKWebView");
    Class cfgClass = NSClassFromString(@"WKWebViewConfiguration");
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

    // 若 App 用 WKUserScript 在文档开始注入用户信息，这里原样重放
    NSString *userScriptSource = [[NSUserDefaults standardUserDefaults] stringForKey:kFGLastUserScriptKey];
    Class usClass = NSClassFromString(@"WKUserScript");
    if (userScriptSource.length > 0 && usClass != Nil) {
        id script = ((id (*)(id, SEL, NSString *, NSInteger, BOOL))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)(usClass, @selector(alloc)),
            @selector(initWithSource:injectionTime:forMainFrameOnly:),
            userScriptSource, 0, YES);
        id ucc = ((id (*)(id, SEL))objc_msgSend)(config, @selector(userContentController));
        ((void (*)(id, SEL, id))objc_msgSend)(ucc, @selector(addUserScript:), script);
        NSLog(@"[FakeGPS] 已重放 WKUserScript(%lu 字节)", (unsigned long)userScriptSource.length);
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
    NSLog(@"[FakeGPS] 后台加载 H5: %@", urlString);

    NSString *injectJS = [[NSUserDefaults standardUserDefaults] stringForKey:kFGLastH5InjectJSKey];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (injectJS.length > 0 && self->_backgroundWebView != nil) {
            gFGInternalJS = YES;
            ((void (*)(id, SEL, id, id))objc_msgSend)(self->_backgroundWebView,
                                                      @selector(evaluateJavaScript:completionHandler:),
                                                      injectJS, nil);
            gFGInternalJS = NO;
            NSLog(@"[FakeGPS] 已重放 H5 注入脚本(%lu 字节)", (unsigned long)injectJS.length);
        }
    });

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
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
    NSLog(@"[FakeGPS] 后台 H5 已回收");
}

@end

#pragma mark - WKWebView 钩子实现

static void hooked_WKWebView_loadRequest(id self, SEL _cmd, NSURLRequest *request)
{
    orig_WKWebView_loadRequest(self, _cmd, request);

    if (gFGInternalJS) {
        return;
    }

    NSString *url = request.URL.absoluteString;
    if (url.length == 0 ||
        (![url containsString:@"dms2storeh5"] && ![url containsString:@"storeapp.ausnutria.com"])) {
        return;
    }

    NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:kFGLastH5URLKey];
    if (![url isEqualToString:last]) {
        [[NSUserDefaults standardUserDefaults] setObject:url forKey:kFGLastH5URLKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        NSLog(@"[FakeGPS] 记录 H5 URL: %@", url);
    }
}

static void hooked_WKWebView_evaluateJS(id self, SEL _cmd, NSString *script, id completion)
{
    if (!gFGInternalJS && script.length > 0 && script.length < 30000 &&
        ([script containsString:@"userInfo"] ||
         [script containsString:@"localStorage"] ||
         [script containsString:@"sessionStorage"])) {

        NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:kFGLastH5InjectJSKey];
        if (![script isEqualToString:last]) {
            [[NSUserDefaults standardUserDefaults] setObject:script forKey:kFGLastH5InjectJSKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
            NSLog(@"[FakeGPS] 记录 H5 注入脚本(%lu 字节)", (unsigned long)script.length);
        }
    }

    orig_WKWebView_evaluateJS(self, _cmd, script, completion);
}

static void hooked_WKUserContentController_addUserScript(id self, SEL _cmd, id userScript)
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

    orig_WKUserContentController_addUserScript(self, _cmd, userScript);
}

#pragma mark - 从页面文本里解析「仓库地址」的经纬度

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

#pragma mark - 安装（挂在 UIViewController viewDidAppear: 上）

static void (*orig_UIViewController_viewDidAppear)(id, SEL, BOOL);

static void hooked_UIViewController_viewDidAppear(id self, SEL _cmd, BOOL animated)
{
    orig_UIViewController_viewDidAppear(self, _cmd, animated);
    [[FGAutoAddressController sharedController] handleAppearanceOf:self];
}

void FGAutoAddressInstall(void)
{
    MSHookMessageEx(objc_getClass("UIViewController"), @selector(viewDidAppear:),
                    (IMP)hooked_UIViewController_viewDidAppear,
                    (IMP *)&orig_UIViewController_viewDidAppear);

    // 《门店地址》页是 WebView 承载的 H5：启动 DOM 轮询
    dispatch_async(dispatch_get_main_queue(), ^{
        [[FGAutoAddressController sharedController] startWebObservation];
    });
}
