//
//  FakeGPSHooks.m
//  FakeGPS.dylib
//
//  由 IG5 / Ghidra 静态反编译结果重建（AArch64 Mach-O, __TEXT 0x0..0x28600）。
//  原始样本: D:\Desktop\FakeGPS.dylib
//  SHA-256 : cdf9c75032393c28f252b7643af73d083fc00e7700a33b74805f50f42bcb095d
//
//  说明:
//   * 本文件是“可读源码重建”，不是原始工程文件；函数/方法对应地址见 README.md。
//   * Ghidra 对返回结构体(CLLocationCoordinate2D, HFA)的钩子会退化成 "return 0"，
//     此处按调用约定还原为返回坐标。
//   * 常量池 (__const @0x12938) 中的 double 已逐个核对：1e-6 / 10000.0 / -500.0 / 500.0 / 90.0 / 180.0。
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import <substrate.h>   // MSHookMessageEx

#import "MapViewController.h"

// 新增功能：门店地址页自动用仓库地址覆盖设备位置（见 FakeGPSAutoAddress.m）
extern void FGAutoAddressInstall(void);

#pragma mark - 常量（__cstring / __ustring / __cfstring）

NSString *const kLocationSpoofingEnabled  = @"LocationSpoofingEnabled";   // cf @0x18500
NSString *const kAltitudeSpoofingEnabled  = @"AltitudeSpoofingEnabled";   // cf @0x185a0
NSString *const kLatitudeKey              = @"latitude";                  // cf @0x18520
NSString *const kLongitudeKey             = @"longitude";                 // cf @0x18540
NSString *const kAltitudeKey              = @"altitude";                  // cf @0x185c0
NSString *const kLocationHistoryKey       = @"LocationHistory";           // cf @0x18700

static const double kCoordinateEpsilon = 1e-6;   // DAT_00012938
static const double kAltitudeMax       = 10000.0; // DAT_00012940
static const double kAltitudeMin       = -500.0;  // DAT_00012948
static const double kAccuracy          = 5.0;     // 0x4014000000000000

#pragma mark - 原始实现指针（__DATA @0x1ef40..0x1ef80）

static CLLocationCoordinate2D (*orig_CLLocation_coordinate)(id, SEL);
static double (*orig_CLLocation_altitude)(id, SEL);
static double (*orig_CLLocation_verticalAccuracy)(id, SEL);

static void (*orig_CLLocationManager_setDelegate)(id, SEL, id);
static CLLocation *(*orig_CLLocationManager_location)(id, SEL);
static void (*orig_CLLocationManager_setDesiredAccuracy)(id, SEL, CLLocationAccuracy);
static void (*orig_CLLocationManager_startUpdatingLocation)(id, SEL);

static CLLocationCoordinate2D (*orig_MKUserLocation_coordinate)(id, SEL);

static void (*orig_UIViewController_viewDidLoad)(id, SEL);

#pragma mark - CLLocation.coordinate  (@0x7594)

static CLLocationCoordinate2D hooked_CLLocation_coordinate(id self, SEL _cmd)
{
    NSDictionary *defaults = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];

    if (![[defaults objectForKeyedSubscript:kLocationSpoofingEnabled] boolValue]) {
        return orig_CLLocation_coordinate(self, _cmd);
    }

    id latValue = [defaults objectForKeyedSubscript:kLatitudeKey];
    id lngValue = [defaults objectForKeyedSubscript:kLongitudeKey];

    if ([latValue isKindOfClass:[NSNumber class]] && [lngValue isKindOfClass:[NSNumber class]]) {
        double latitude  = [latValue doubleValue];
        double longitude = [lngValue doubleValue];

        // 两个分量都接近 0 视为“未设置”，回落原始坐标
        if (fabs(latitude) >= kCoordinateEpsilon || fabs(longitude) >= kCoordinateEpsilon) {
            return CLLocationCoordinate2DMake(latitude, longitude);
        }

        NSLog(@"[Spoofing] Invalid coordinates detected, returning original.");
        return orig_CLLocation_coordinate(self, _cmd);
    }

    NSLog(@"[Spoofing] Invalid coordinates type in UserDefaults.");
    return orig_CLLocation_coordinate(self, _cmd);
}

#pragma mark - CLLocation.altitude  (@0x780c)

static double hooked_CLLocation_altitude(id self, SEL _cmd)
{
    NSDictionary *defaults = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];

    if (![[defaults objectForKeyedSubscript:kAltitudeSpoofingEnabled] boolValue]) {
        return orig_CLLocation_altitude(self, _cmd);
    }

    id altitudeValue = [defaults objectForKeyedSubscript:kAltitudeKey];
    if (![altitudeValue isKindOfClass:[NSNumber class]]) {
        NSLog(@"[Spoofing] Invalid altitude type in UserDefaults.");
        return orig_CLLocation_altitude(self, _cmd);
    }

    double altitude = [altitudeValue doubleValue];
    if (isnan(altitude) || altitude > kAltitudeMax || altitude < kAltitudeMin) {
        NSLog(@"[Spoofing] Invalid altitude detected, returning original.");
        return orig_CLLocation_altitude(self, _cmd);
    }

    return altitude;
}

#pragma mark - CLLocation.verticalAccuracy  (@0x7a08)

static double hooked_CLLocation_verticalAccuracy(id self, SEL _cmd)
{
    NSDictionary *defaults = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];

    if (![[defaults objectForKeyedSubscript:kAltitudeSpoofingEnabled] boolValue]) {
        return orig_CLLocation_verticalAccuracy(self, _cmd);
    }

    // 反编译仅可见 arc4random_uniform(1000) 的调用；返回值经 d0 传出
    return (double)arc4random_uniform(1000);
}

#pragma mark - CLLocationManager.setDelegate:  (@0x7b3c)

static NSMutableSet *hookedDelegateClasses = nil;
static dispatch_once_t  hookedDelegateOnce;

// 被替换的 locationManager:didUpdateLocations: 实现体 (@0x8878)
static void hooked_didUpdateLocations(id self, SEL _cmd,
                                      CLLocationManager *manager,
                                      NSArray *locations,
                                      IMP originalIMP)
{
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kLocationSpoofingEnabled]) {
        double latitude  = [[NSUserDefaults standardUserDefaults] doubleForKey:kLatitudeKey];
        double longitude = [[NSUserDefaults standardUserDefaults] doubleForKey:kLongitudeKey];

        CLLocation *fake = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(latitude, longitude)
                                                         altitude:0
                                               horizontalAccuracy:kAccuracy
                                                 verticalAccuracy:kAccuracy
                                                        timestamp:[NSDate date]];
        locations = @[ fake ];
    }

    ((void (*)(id, SEL, id, id))originalIMP)(self, _cmd, manager, locations);
}

static void hooked_CLLocationManager_setDelegate(CLLocationManager *self, SEL _cmd, id delegate)
{
    orig_CLLocationManager_setDelegate(self, _cmd, delegate);

    if ([NSBundle mainBundle].bundleIdentifier == nil) {
        return;
    }

    dispatch_once(&hookedDelegateOnce, ^{
        hookedDelegateClasses = [NSMutableSet set];
    });

    Class delegateClass = object_getClass(delegate);
    NSString *className = NSStringFromClass(delegateClass);

    @synchronized (hookedDelegateClasses) {
        if ([hookedDelegateClasses containsObject:className]) {
            return;
        }
        [hookedDelegateClasses addObject:className];

        SEL selector = @selector(locationManager:didUpdateLocations:);
        Method method = class_getInstanceMethod(delegateClass, selector);
        if (method == NULL) {
            return;
        }

        IMP originalIMP = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^void (id blockSelf, CLLocationManager *manager, NSArray *locations) {
            hooked_didUpdateLocations(blockSelf, selector, manager, locations, originalIMP);
        });
        method_setImplementation(method, replacement);
    }
}

#pragma mark - CLLocationManager.location  (@0x7dcc)

static CLLocation *hooked_CLLocationManager_location(id self, SEL _cmd)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if (![defaults boolForKey:kLocationSpoofingEnabled]) {
        return orig_CLLocationManager_location(self, _cmd);
    }

    double latitude  = [defaults doubleForKey:kLatitudeKey];
    double longitude = [defaults doubleForKey:kLongitudeKey];

    return [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(latitude, longitude)
                                         altitude:0
                               horizontalAccuracy:kAccuracy
                                 verticalAccuracy:kAccuracy
                                        timestamp:[NSDate date]];
}

#pragma mark - CLLocationManager.setDesiredAccuracy:  (@0x7f44)

static void hooked_CLLocationManager_setDesiredAccuracy(CLLocationManager *self, SEL _cmd,
                                                        CLLocationAccuracy accuracy)
{
    BOOL inBundle      = ([NSBundle mainBundle].bundleIdentifier != nil);
    BOOL spoofing      = [[NSUserDefaults standardUserDefaults] boolForKey:kLocationSpoofingEnabled];

    if (inBundle && spoofing) {
        orig_CLLocationManager_setDesiredAccuracy(self, _cmd, kCLLocationAccuracyBest);
        return;
    }

    orig_CLLocationManager_setDesiredAccuracy(self, _cmd, accuracy);
}

#pragma mark - CLLocationManager.startUpdatingLocation  (@0x80d0)

static NSArray *excludedProcessNames = nil;      // __DATA @0x1ef98
static dispatch_once_t excludedOnce;

// 需要“放行/不伪造”的宿主进程名 (@0x8af0)
static void buildExcludedProcessNames(void)
{
    excludedProcessNames = @[ @"WeChat", @"滴滴代驾司机" ];
}

static void hooked_CLLocationManager_startUpdatingLocation(CLLocationManager *self, SEL _cmd)
{
    dispatch_once(&excludedOnce, ^{
        buildExcludedProcessNames();
    });

    NSString *processName = [NSProcessInfo processInfo].processName;
    if ([excludedProcessNames containsObject:processName]) {
        orig_CLLocationManager_startUpdatingLocation(self, _cmd);
        return;
    }

    NSDictionary *defaults = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];

    if (![[defaults objectForKeyedSubscript:kLocationSpoofingEnabled] boolValue]) {
        orig_CLLocationManager_startUpdatingLocation(self, _cmd);
        return;
    }

    id latValue = [defaults objectForKeyedSubscript:kLatitudeKey];
    id lngValue = [defaults objectForKeyedSubscript:kLongitudeKey];

    if ([latValue isKindOfClass:[NSNumber class]] && [lngValue isKindOfClass:[NSNumber class]]) {
        double latitude  = [latValue doubleValue];
        double longitude = [lngValue doubleValue];

        if (fabs(latitude) >= kCoordinateEpsilon || fabs(longitude) >= kCoordinateEpsilon) {
            CLLocation *fake = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(latitude, longitude)
                                                             altitude:0
                                                   horizontalAccuracy:kAccuracy
                                                     verticalAccuracy:kAccuracy
                                                            timestamp:[NSDate date]];
            NSArray *locations = @[ fake ];

            dispatch_async(dispatch_get_main_queue(), ^{
                id<CLLocationManagerDelegate> delegate = self.delegate;
                if (delegate &&
                    [delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
                    [delegate locationManager:self didUpdateLocations:locations];
                }
            });
        } else {
            NSLog(@"[LocationSpoofing] Invalid coordinates detected, skipping spoofing.");
        }
        return;
    }

    NSLog(@"[LocationSpoofing] Invalid coordinates type in UserDefaults.");
}

#pragma mark - MKUserLocation.coordinate  (@0x8518)

static CLLocationCoordinate2D hooked_MKUserLocation_coordinate(id self, SEL _cmd)
{
    CLLocationCoordinate2D origin = orig_MKUserLocation_coordinate(self, _cmd);

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:kLocationSpoofingEnabled]) {
        double latitude  = [defaults doubleForKey:kLatitudeKey];
        double longitude = [defaults doubleForKey:kLongitudeKey];
        if (latitude != 0.0 || longitude != 0.0) {
            return CLLocationCoordinate2DMake(latitude, longitude);
        }
    }

    return origin;
}

#pragma mark - UIViewController 隐藏入口  (@0x863c / @0x8670 / @0x873c)

static void hooked_UIViewController_viewDidLoad(id self, SEL _cmd)
{
    orig_UIViewController_viewDidLoad(self, _cmd);
    ((void (*)(id, SEL))objc_msgSend)(self, @selector(initTapGess));
}

// -[UIViewController initTapGess]  (class_addMethod, "v@:")
static void UIViewController_initTapGess(id self, SEL _cmd)
{
    UIViewController *controller = (UIViewController *)self;

    UITapGestureRecognizer *recognizer =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTaps:)];
    recognizer.numberOfTapsRequired    = 2;
    recognizer.numberOfTouchesRequired = 3;
    [controller.view addGestureRecognizer:recognizer];
}

// -[UIViewController handleDoubleTaps:]  (class_addMethod, "v@:@")
static void UIViewController_handleDoubleTaps(id self, SEL _cmd, UITapGestureRecognizer *recognizer)
{
    NSLog(@"[DEBUG] 双指双击检测到");

    MapViewController *mapViewController = [[MapViewController alloc] init];
    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:mapViewController];
    navigationController.modalPresentationStyle = UIModalPresentationFullScreen;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:navigationController animated:YES completion:nil];
    });
}

#pragma mark - 安装  (@0x73a0)

static void InstallFakeGPSHooks(void)
{
    Class CLLocationClass = objc_getClass("CLLocation");
    MSHookMessageEx(CLLocationClass, @selector(coordinate),
                    (IMP)hooked_CLLocation_coordinate, (IMP *)&orig_CLLocation_coordinate);
    MSHookMessageEx(CLLocationClass, @selector(altitude),
                    (IMP)hooked_CLLocation_altitude, (IMP *)&orig_CLLocation_altitude);
    MSHookMessageEx(CLLocationClass, @selector(verticalAccuracy),
                    (IMP)hooked_CLLocation_verticalAccuracy, (IMP *)&orig_CLLocation_verticalAccuracy);

    Class CLLocationManagerClass = objc_getClass("CLLocationManager");
    MSHookMessageEx(CLLocationManagerClass, @selector(setDelegate:),
                    (IMP)hooked_CLLocationManager_setDelegate, (IMP *)&orig_CLLocationManager_setDelegate);
    MSHookMessageEx(CLLocationManagerClass, @selector(location),
                    (IMP)hooked_CLLocationManager_location, (IMP *)&orig_CLLocationManager_location);
    MSHookMessageEx(CLLocationManagerClass, @selector(setDesiredAccuracy:),
                    (IMP)hooked_CLLocationManager_setDesiredAccuracy, (IMP *)&orig_CLLocationManager_setDesiredAccuracy);
    MSHookMessageEx(CLLocationManagerClass, @selector(startUpdatingLocation),
                    (IMP)hooked_CLLocationManager_startUpdatingLocation, (IMP *)&orig_CLLocationManager_startUpdatingLocation);

    Class MKUserLocationClass = objc_getClass("MKUserLocation");
    MSHookMessageEx(MKUserLocationClass, @selector(coordinate),
                    (IMP)hooked_MKUserLocation_coordinate, (IMP *)&orig_MKUserLocation_coordinate);

    Class UIViewControllerClass = objc_getClass("UIViewController");
    MSHookMessageEx(UIViewControllerClass, @selector(viewDidLoad),
                    (IMP)hooked_UIViewController_viewDidLoad, (IMP *)&orig_UIViewController_viewDidLoad);

    class_addMethod(UIViewControllerClass, @selector(initTapGess),
                    (IMP)UIViewController_initTapGess, "v@:");
    class_addMethod(UIViewControllerClass, @selector(handleDoubleTaps:),
                    (IMP)UIViewController_handleDoubleTaps, "v@:@");

    // 新增：门店地址页 → 仓库地址自动覆盖
    FGAutoAddressInstall();
}

// @0x736c: 延迟 1s 在主队列安装
__attribute__((constructor))
static void FakeGPSInitialize(void)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        InstallFakeGPSHooks();
    });
}
