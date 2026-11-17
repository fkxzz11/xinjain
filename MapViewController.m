//
//  MapViewController.m
//  FakeGPS.dylib
//
//  由 IG5 / Ghidra 反编译重建。
//  方法顺序与二进制 __text 中的出现顺序一致（0x8ca8 .. 0x10594）。
//  UI 文案取自 __ustring / __cfstring（UTF-16 原文）。
//

#import "MapViewController.h"
#import "HistoryViewController.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

static NSString *const kLocationSpoofingEnabledKey = @"LocationSpoofingEnabled";
static NSString *const kAltitudeSpoofingEnabledKey = @"AltitudeSpoofingEnabled";
static NSString *const kLatitudeKey                = @"latitude";
static NSString *const kLongitudeKey               = @"longitude";
static NSString *const kAltitudeKey                = @"altitude";
static NSString *const kLocationHistoryKey         = @"LocationHistory";

static const double kSavedRegionDistance = 500.0;   // DAT_00012990

@interface MapViewController ()
- (void)applyReverseGeocode:(NSArray<CLPlacemark *> *)placemarks;
- (void)handleManualLocationInput:(UIAlertController *)alert;
- (void)handleManualAltitudeInput:(UIAlertController *)alert;
@end

@implementation MapViewController

#pragma mark - 生命周期

- (void)viewDidLoad
{
    [super viewDidLoad];

    [self setupNavigationBar];
    [self initializeData];
    [self setupUIComponents];
    [self setupConstraints];
    [self setupGestures];
    [self loadSavedLocations];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self checkLocationAuthorization];
    [self updateUIForCurrentInterfaceStyle];
}

- (void)updateUIForCurrentInterfaceStyle
{
    BOOL isDark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);

    self.view.backgroundColor = isDark ? [UIColor blackColor] : [UIColor whiteColor];
    self.suggestionTableView.backgroundColor =
        isDark ? [UIColor tertiarySystemBackgroundColor] : [UIColor secondarySystemBackgroundColor];
}

- (void)dismissKeyboard
{
    [self.view endEditing:YES];
}

#pragma mark - 界面搭建

- (void)setupNavigationBar
{
    self.navigationItem.title = @"位置模拟";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    UIBarButtonItem *closeItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self
                                                      action:@selector(closeButtonTapped:)];
    self.navigationItem.rightBarButtonItem = closeItem;
}

- (void)initializeData
{
    NSMutableArray *history =
        [[[NSUserDefaults standardUserDefaults] arrayForKey:kLocationHistoryKey] mutableCopy];
    self.locationHistory = history ?: [NSMutableArray array];

    self.geocoder = [[CLGeocoder alloc] init];
}

- (void)loadSavedLocations
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    float latitude  = [defaults floatForKey:kLatitudeKey];
    float longitude = [defaults floatForKey:kLongitudeKey];
    float altitude  = [defaults floatForKey:kAltitudeKey];

    self.locationLabel.text = [NSString stringWithFormat:@"位置: %.4f, %.4f", latitude, longitude];
    self.altitudeLabel.text = [NSString stringWithFormat:@"海拔: %.2f米", altitude];

    if (latitude != 0.0f && longitude != 0.0f) {
        [self addAnnotationAtCoordinate:CLLocationCoordinate2DMake(latitude, longitude)
                              withTitle:@"当前位置"];
    }
}

- (void)setupUIComponents
{
    [self setupSearchBar];
    [self setupMapView];
    [self setupActionControls];
    [self setupInfoCard];
    [self setupSwitchControls];
    [self setupConfirmButton];

    [self.view bringSubviewToFront:self.suggestionTableView];
}

- (void)setupSearchBar
{
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜索地址或地点";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.tintColor = [UIColor systemBlueColor];
    self.searchBar.searchTextField.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.searchBar];

    self.suggestionTableView = [[UITableView alloc] initWithFrame:CGRectZero
                                                            style:UITableViewStylePlain];
    self.suggestionTableView.delegate = self;
    self.suggestionTableView.dataSource = self;
    self.suggestionTableView.hidden = YES;
    self.suggestionTableView.layer.cornerRadius = 10.0;
    self.suggestionTableView.layer.maskedCorners =
        kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    self.suggestionTableView.separatorInset = UIEdgeInsetsZero;
    self.suggestionTableView.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    self.suggestionTableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.suggestionTableView];
}

- (void)setupMapView
{
    self.mapView = [[MKMapView alloc] init];
    self.mapView.delegate = self;
    self.mapView.layer.cornerRadius = 12.0;
    self.mapView.clipsToBounds = YES;
    self.mapView.mapType = MKMapTypeStandard;
    self.mapView.showsUserLocation = YES;
    self.mapView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.mapView];

    self.trackingButton = [MKUserTrackingButton userTrackingButtonWithMapView:self.mapView];
    self.trackingButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.trackingButton.layer.cornerRadius = 5.0;
    self.trackingButton.translatesAutoresizingMaskIntoConstraints = NO;

    self.mapTypeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.mapTypeButton setImage:[UIImage systemImageNamed:@"map"] forState:UIControlStateNormal];
    [self.mapTypeButton addTarget:self
                           action:@selector(toggleMapType)
                 forControlEvents:UIControlEventTouchUpInside];
    self.mapTypeButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.mapTypeButton.layer.cornerRadius = 5.0;
    self.mapTypeButton.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ self.trackingButton,
                                                                         self.mapTypeButton ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
}

- (void)setupActionControls
{
    self.actionControl =
        [[UISegmentedControl alloc] initWithItems:@[ @"历史记录", @"输入位置", @"输入海拔" ]];
    [self.actionControl addTarget:self
                           action:@selector(segmentAction:)
                 forControlEvents:UIControlEventValueChanged];
    self.actionControl.selectedSegmentIndex = UISegmentedControlNoSegment;
    self.actionControl.apportionsSegmentWidthsByContent = YES;
    self.actionControl.selectedSegmentTintColor = [UIColor systemBlueColor];
    self.actionControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.actionControl];
}

- (void)setupInfoCard
{
    self.infoCardView = [[UIView alloc] init];
    self.infoCardView.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    self.infoCardView.layer.cornerRadius = 10.0;
    self.infoCardView.layer.shadowRadius = 3.0;
    self.infoCardView.layer.shadowOpacity = 0.1f;
    self.infoCardView.translatesAutoresizingMaskIntoConstraints = NO;

    self.locationLabel = [[UILabel alloc] init];
    self.locationLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    self.locationLabel.textColor = [UIColor labelColor];
    self.locationLabel.numberOfLines = 2;

    self.altitudeLabel = [[UILabel alloc] init];
    self.altitudeLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    self.altitudeLabel.textColor = [UIColor labelColor];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ self.locationLabel,
                                                                         self.altitudeLabel ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.infoCardView addSubview:stack];
    [self.view addSubview:self.infoCardView];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor     constraintEqualToAnchor:self.infoCardView.topAnchor     constant:12.0],
        [stack.leadingAnchor constraintEqualToAnchor:self.infoCardView.leadingAnchor constant:12.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.infoCardView.trailingAnchor constant:-12.0],
        [stack.bottomAnchor  constraintEqualToAnchor:self.infoCardView.bottomAnchor  constant:-12.0],
    ]];
}

- (void)setupSwitchControls
{
    self.locationSwitch = [[UISwitch alloc] init];
    [self.locationSwitch addTarget:self
                            action:@selector(locationSwitchChanged:)
                  forControlEvents:UIControlEventValueChanged];

    self.altitudeSwitch = [[UISwitch alloc] init];
    [self.altitudeSwitch addTarget:self
                            action:@selector(altitudeSwitchChanged:)
                  forControlEvents:UIControlEventValueChanged];

    UIView *locationItem = [self createSwitchItemWithIcon:@"location.fill"
                                            switchControl:self.locationSwitch
                                                    text:@"位置模拟"];
    UIView *altitudeItem = [self createSwitchItemWithIcon:@"mountain.2.fill"
                                            switchControl:self.altitudeSwitch
                                                    text:@"海拔模拟"];

    self.switchStack = [[UIStackView alloc] initWithArrangedSubviews:@[ locationItem, altitudeItem ]];
    self.switchStack.axis = UILayoutConstraintAxisHorizontal;
    self.switchStack.spacing = 20.0;
    self.switchStack.distribution = UIStackViewDistributionFillEqually;
    self.switchStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.switchStack];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [self.locationSwitch setOn:[defaults boolForKey:kLocationSpoofingEnabledKey] animated:NO];
    [self.altitudeSwitch setOn:[defaults boolForKey:kAltitudeSpoofingEnabledKey] animated:NO];
}

- (UIView *)createSwitchItemWithIcon:(NSString *)icon
                       switchControl:(UISwitch *)switchControl
                               text:(NSString *)text
{
    UIStackView *container = [[UIStackView alloc] init];
    container.axis = UILayoutConstraintAxisVertical;
    container.alignment = UIStackViewAlignmentLeading;
    container.spacing = 8.0;

    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8.0;
    row.alignment = UIStackViewAlignmentLeading;

    UIImageView *iconView =
        [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:icon]];
    iconView.tintColor = [UIColor secondaryLabelColor];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    [iconView setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];

    [row addArrangedSubview:iconView];
    [row addArrangedSubview:switchControl];

    [container addArrangedSubview:row];
    [container addArrangedSubview:label];

    return container;
}

- (void)setupConfirmButton
{
    self.confirmButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.confirmButton setTitle:@"确认位置" forState:UIControlStateNormal];
    [self.confirmButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.confirmButton.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    self.confirmButton.backgroundColor = [UIColor systemBlueColor];
    self.confirmButton.layer.cornerRadius = 10.0;
    self.confirmButton.layer.shadowRadius = 2.0;
    self.confirmButton.layer.shadowOpacity = 0.2f;
    [self.confirmButton addTarget:self
                           action:@selector(confirmLocation)
                 forControlEvents:UIControlEventTouchUpInside];
    self.confirmButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.confirmButton];

    [self.confirmButton addTarget:self
                           action:@selector(buttonTouchDown:)
                 forControlEvents:UIControlEventTouchDown];
    [self.confirmButton addTarget:self
                           action:@selector(buttonTouchUp:)
                 forControlEvents:UIControlEventTouchUpInside |
                                  UIControlEventTouchUpOutside |
                                  UIControlEventTouchCancel];
}

// 说明：@0xb5c8 的原始实现是约 4.7 KB 的全手写 Auto Layout 约束链，
// 此处按已确认的 ivar 关系与常量（12/16/20/220/500 等）重建为等价布局。
- (void)setupConstraints
{
    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;

    [NSLayoutConstraint activateConstraints:@[
        // 搜索框
        [self.searchBar.topAnchor      constraintEqualToAnchor:safeArea.topAnchor constant:8.0],
        [self.searchBar.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:16.0],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
        [self.searchBar.heightAnchor   constraintEqualToConstant:50.0],

        // 搜索建议表
        [self.suggestionTableView.topAnchor      constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.suggestionTableView.leadingAnchor  constraintEqualToAnchor:self.searchBar.leadingAnchor],
        [self.suggestionTableView.trailingAnchor constraintEqualToAnchor:self.searchBar.trailingAnchor],
        [self.suggestionTableView.heightAnchor   constraintEqualToConstant:220.0],

        // 地图
        [self.mapView.topAnchor      constraintEqualToAnchor:self.searchBar.bottomAnchor constant:8.0],
        [self.mapView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:16.0],
        [self.mapView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
        [self.mapView.bottomAnchor   constraintEqualToAnchor:self.switchStack.topAnchor constant:-12.0],

        // 地图右下角控件
        [self.trackingButton.widthAnchor  constraintEqualToConstant:44.0],
        [self.trackingButton.heightAnchor constraintEqualToConstant:44.0],

        // 信息卡片
        [self.infoCardView.leadingAnchor  constraintEqualToAnchor:self.mapView.leadingAnchor],
        [self.infoCardView.trailingAnchor constraintEqualToAnchor:self.mapView.trailingAnchor],
        [self.infoCardView.bottomAnchor   constraintEqualToAnchor:self.switchStack.topAnchor constant:-12.0],

        // 开关组
        [self.switchStack.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:16.0],
        [self.switchStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
        [self.switchStack.bottomAnchor   constraintEqualToAnchor:self.actionControl.topAnchor constant:-12.0],

        // 分段控件
        [self.actionControl.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:16.0],
        [self.actionControl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
        [self.actionControl.heightAnchor   constraintEqualToConstant:36.0],
        [self.actionControl.bottomAnchor   constraintEqualToAnchor:self.confirmButton.topAnchor constant:-12.0],

        // 确认按钮
        [self.confirmButton.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:16.0],
        [self.confirmButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
        [self.confirmButton.heightAnchor   constraintEqualToConstant:50.0],
        [self.confirmButton.bottomAnchor   constraintEqualToAnchor:safeArea.bottomAnchor constant:-16.0],
    ]];
}

- (void)setupGestures
{
    self.longPressRecognizer =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    [self.mapView addGestureRecognizer:self.longPressRecognizer];
}

#pragma mark - 交互

- (void)segmentAction:(UISegmentedControl *)sender
{
    self.suggestionTableView.hidden = YES;

    NSInteger index = sender.selectedSegmentIndex;
    if (index < 3) {
        SEL actions[3] = { @selector(showHistory),
                           @selector(showManualInput),
                           @selector(showManualAltitudeInput) };
        ((void (*)(id, SEL))objc_msgSend)(self, actions[index]);
    }

    sender.selectedSegmentIndex = UISegmentedControlNoSegment;
}

- (void)toggleMapType
{
    self.mapView.mapType = (self.mapView.mapType == MKMapTypeStandard) ? MKMapTypeSatellite
                                                                       : MKMapTypeStandard;
    NSString *icon = (self.mapView.mapType == MKMapTypeStandard) ? @"map" : @"globe";
    [self.mapTypeButton setImage:[UIImage systemImageNamed:icon] forState:UIControlStateNormal];
}

- (void)buttonTouchDown:(UIButton *)sender
{
    [UIView animateWithDuration:0.1 animations:^{
        sender.transform = CGAffineTransformMakeScale(0.96, 0.96);
    }];
}

- (void)buttonTouchUp:(UIButton *)sender
{
    [UIView animateWithDuration:0.2 animations:^{
        sender.transform = CGAffineTransformIdentity;
    }];
}

- (void)confirmLocation
{
    if (self.locationSwitch.isOn) {
        [self showAlertWithTitle:@"无法确认位置" message:@"请先关闭「位置模拟」开关再确认位置"];
        return;
    }

    for (id<MKAnnotation> annotation in self.mapView.annotations) {
        if (![annotation isKindOfClass:[MKPointAnnotation class]]) {
            continue;
        }
        if ([annotation isKindOfClass:[MKUserLocation class]]) {
            continue;
        }

        NSString *title = annotation.title;
        if (title == nil) {
            title = [NSString stringWithFormat:@"自定义位置 (%.4f, %.4f)",
                                               annotation.coordinate.latitude,
                                               annotation.coordinate.longitude];
        }

        NSDictionary *item = @{
            @"address"   : title,
            @"latitude"  : @(annotation.coordinate.latitude),
            @"longitude" : @(annotation.coordinate.longitude),
        };
        [self.locationHistory addObject:item];

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:self.locationHistory forKey:kLocationHistoryKey];
        [defaults setDouble:annotation.coordinate.latitude  forKey:kLatitudeKey];
        [defaults setDouble:annotation.coordinate.longitude forKey:kLongitudeKey];
        [defaults synchronize];

        self.locationLabel.text = [NSString stringWithFormat:@"位置: %.4f, %.4f",
                                                             annotation.coordinate.latitude,
                                                             annotation.coordinate.longitude];
        [self showAlertWithTitle:@"位置已保存" message:@"已成功保存当前位置，开启位置模拟开关即可使用"];
        return;
    }

    [self showAlertWithTitle:@"未选择位置" message:@"请在地图上长按选择位置或通过搜索选择位置"];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer
{
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }

    CGPoint point = [recognizer locationInView:self.mapView];
    CLLocationCoordinate2D coordinate = [self.mapView convertPoint:point
                                             toCoordinateFromView:self.mapView];

    NSPredicate *predicate = [NSPredicate predicateWithFormat:
                              @"self isKindOfClass: %@ AND NOT self isKindOfClass: %@",
                              [MKPointAnnotation class], [MKUserLocation class]];
    [self.mapView removeAnnotations:[self.mapView.annotations filteredArrayUsingPredicate:predicate]];

    MKPointAnnotation *annotation = [[MKPointAnnotation alloc] init];
    annotation.coordinate = coordinate;
    annotation.title = [NSString stringWithFormat:@"自定义位置 (%.4f, %.4f)",
                                                  coordinate.latitude, coordinate.longitude];
    [self.mapView addAnnotation:annotation];

    __weak typeof(self) weakSelf = self;
    CLLocation *location = [[CLLocation alloc] initWithLatitude:coordinate.latitude
                                                      longitude:coordinate.longitude];
    [self.geocoder reverseGeocodeLocation:location completionHandler:^(NSArray<CLPlacemark *> *placemarks,
                                                                       NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf applyReverseGeocode:placemarks];
        });
    }];
}

// 反向地理编码回调体（@0xd774），主队列执行
- (void)applyReverseGeocode:(NSArray<CLPlacemark *> *)placemarks
{
    for (id<MKAnnotation> annotation in self.mapView.annotations) {
        if (![annotation isKindOfClass:[MKPointAnnotation class]]) {
            continue;
        }
        if ([annotation.title hasPrefix:@"当前位置"]) {
            continue;
        }

        CLPlacemark *placemark = placemarks.firstObject;
        if (placemark != nil) {
            // id<MKAnnotation> 的 title 只读，MKPointAnnotation 才是可写的
            MKPointAnnotation *point = (MKPointAnnotation *)annotation;
            point.title = [NSString stringWithFormat:@"%@, %@",
                                                         placemark.name ?: @"",
                                                         placemark.locality ?: @""];
        }
        self.locationLabel.text = [NSString stringWithFormat:@"位置: %.4f, %.4f",
                                                             annotation.coordinate.latitude,
                                                             annotation.coordinate.longitude];
        break;
    }
}

- (void)addAnnotationAtCoordinate:(CLLocationCoordinate2D)coordinate withTitle:(NSString *)title
{
    MKPointAnnotation *annotation = [[MKPointAnnotation alloc] init];
    annotation.coordinate = coordinate;
    annotation.title = title;
    [self.mapView addAnnotation:annotation];

    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(coordinate,
                                                                  kSavedRegionDistance,
                                                                  kSavedRegionDistance);
    [self.mapView setRegion:region animated:YES];
}

#pragma mark - 手动输入

- (void)showManualInput
{
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"手动输入位置"
                                            message:@"请输入纬度和经度\n（例如：39.9042, 116.4074）"
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"纬度（-90 ~ 90）";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"经度（-180 ~ 180）";
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确认"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [weakSelf handleManualLocationInput:alert];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleManualLocationInput:(UIAlertController *)alert
{
    NSString *latitudeText  = alert.textFields[0].text;
    NSString *longitudeText = alert.textFields[1].text;

    if (![self isValidCoordinate:latitudeText lng:longitudeText]) {
        [self showAlertWithTitle:@"输入无效"
                         message:@"请输入有效的经纬度数值\n纬度范围：-90 ~ 90\n经度范围：-180 ~ 180"];
        return;
    }

    CLLocationCoordinate2D coordinate =
        CLLocationCoordinate2DMake(latitudeText.doubleValue, longitudeText.doubleValue);

    [self.mapView removeAnnotations:self.mapView.annotations];
    [self addAnnotationAtCoordinate:coordinate withTitle:@"手动输入的位置"];

    self.locationLabel.text = [NSString stringWithFormat:@"位置: %.4f, %.4f",
                                                         coordinate.latitude, coordinate.longitude];
}

- (void)showManualAltitudeInput
{
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"手动输入海拔"
                                            message:@"请输入海拔高度（单位：米）"
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"海拔（单位：米）";
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确认"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [weakSelf handleManualAltitudeInput:alert];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleManualAltitudeInput:(UIAlertController *)alert
{
    NSString *text = alert.textFields.firstObject.text;

    if (![self isValidAltitude:text]) {
        [self showAlertWithTitle:@"输入无效" message:@"请输入正确的海拔高度（可以是负值）"];
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setDouble:text.doubleValue forKey:kAltitudeKey];
    [defaults synchronize];

    self.altitudeLabel.text = [NSString stringWithFormat:@"海拔: %.2f米", text.doubleValue];
    [self showAlertWithTitle:@"海拔已保存" message:@"已成功保存海拔高度，开启海拔模拟开关即可使用"];
}

#pragma mark - 历史记录

- (void)showHistory
{
    HistoryViewController *historyController =
        [[HistoryViewController alloc] initWithStyle:UITableViewStylePlain];
    historyController.historyItems = self.locationHistory;
    historyController.delegate = (id<HistorySelectionDelegate>)self;

    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:historyController];
    [self presentViewController:navigationController animated:YES completion:nil];
}

- (void)didSelectHistoryItem:(NSDictionary *)item
{
    double latitude  = [item[@"latitude"] doubleValue];
    double longitude = [item[@"longitude"] doubleValue];
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(latitude, longitude);

    [self.mapView removeAnnotations:self.mapView.annotations];

    MKPointAnnotation *annotation = [[MKPointAnnotation alloc] init];
    annotation.coordinate = coordinate;
    annotation.title = item[@"address"];
    [self.mapView addAnnotation:annotation];

    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(coordinate,
                                                                  kSavedRegionDistance,
                                                                  kSavedRegionDistance);
    [self.mapView setRegion:region animated:YES];

    self.locationLabel.text = [NSString stringWithFormat:@"位置: %.4f, %.4f", latitude, longitude];

    NSString *note = item[@"note"];
    if (note != nil && note.length != 0) {
        self.altitudeLabel.text = [NSString stringWithFormat:@"备注: %@", note];
    } else {
        self.altitudeLabel.text = @"备注: 无";
    }
}

#pragma mark - 搜索

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
    self.suggestionTableView.hidden = YES;

    if (searchBar.text.length == 0) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self.geocoder geocodeAddressString:searchBar.text
                      completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        if (error != nil || placemarks.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf showAlertWithTitle:@"搜索失败" message:@"未能找到匹配的位置"];
            });
            return;
        }

        CLLocationCoordinate2D coordinate = placemarks.firstObject.location.coordinate;
        NSString *title = searchBar.text;

        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.mapView removeAnnotations:weakSelf.mapView.annotations];
            [weakSelf addAnnotationAtCoordinate:coordinate withTitle:title];
        });
    }];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    if (searchText.length == 0) {
        self.suggestionTableView.hidden = YES;
        return;
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(performGeocodeWithText:)
                                               object:searchText];
    [self performSelector:@selector(performGeocodeWithText:)
               withObject:searchText
               afterDelay:0.5];
}

- (void)performGeocodeWithText:(NSString *)text
{
    __weak typeof(self) weakSelf = self;
    [self.geocoder geocodeAddressString:text
                      completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        NSMutableArray *suggestions = [NSMutableArray array];

        if (error == nil && placemarks.count != 0) {
            for (CLPlacemark *placemark in placemarks) {
                [suggestions addObject:placemark.name ?: @""];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.addressSuggestions = [suggestions copy];
            weakSelf.suggestionTableView.hidden = (weakSelf.addressSuggestions.count == 0);
            [weakSelf.suggestionTableView reloadData];
        });
    }];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar
{
    self.suggestionTableView.hidden = (self.addressSuggestions.count == 0);
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar
{
    searchBar.text = @"";
    [searchBar resignFirstResponder];
    self.addressSuggestions = @[];
    self.suggestionTableView.hidden = YES;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSString *text = self.addressSuggestions[indexPath.row];
    self.searchBar.text = text;
    self.suggestionTableView.hidden = YES;
    [self.searchBar resignFirstResponder];

    __weak typeof(self) weakSelf = self;
    [self.geocoder geocodeAddressString:text
                      completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        if (error == nil && placemarks.count != 0) {
            CLLocationCoordinate2D coordinate = placemarks.firstObject.location.coordinate;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.mapView removeAnnotations:weakSelf.mapView.annotations];
                [weakSelf addAnnotationAtCoordinate:coordinate withTitle:text];
            });
        }
    }];
}

#pragma mark - UITableViewDataSource / Delegate（搜索建议）

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.addressSuggestions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"suggestionCell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                     reuseIdentifier:@"suggestionCell"];
        cell.imageView.tintColor = [UIColor systemBlueColor];
    }

    cell.imageView.image = [UIImage systemImageNamed:@"mappin.and.ellipse"];
    cell.textLabel.text = self.addressSuggestions[indexPath.row];
    cell.detailTextLabel.text = @"点击选择位置";
    cell.backgroundColor = [UIColor clearColor];

    return cell;
}

#pragma mark - MKMapViewDelegate

- (void)mapView:(MKMapView *)mapView didAddAnnotationViews:(NSArray<MKAnnotationView *> *)views
{
    for (MKAnnotationView *view in views) {
        if (![view.annotation isKindOfClass:[MKPointAnnotation class]]) {
            continue;
        }

        view.transform = CGAffineTransformMakeScale(0.5, 0.5);
        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.5
              initialSpringVelocity:0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            view.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

#pragma mark - 定位权限

- (void)checkLocationAuthorization
{
    if (![CLLocationManager locationServicesEnabled]) {
        [self showAlertWithTitle:@"位置服务已禁用" message:@"请在设置中启用位置服务以使用完整功能"];
        return;
    }

    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.delegate = self;

    CLAuthorizationStatus status = self.locationManager.authorizationStatus;
    if (status == kCLAuthorizationStatusDenied) {
        [self showAlertWithTitle:@"位置权限被拒绝" message:@"请在设置中启用位置权限以使用完整功能"];
    } else if (status == kCLAuthorizationStatusNotDetermined) {
        [self.locationManager requestWhenInUseAuthorization];
    } else {
        [self.locationManager startUpdatingLocation];
    }
}

- (void)locationManager:(CLLocationManager *)manager
didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
    if (status == kCLAuthorizationStatusAuthorizedWhenInUse ||
        status == kCLAuthorizationStatusAuthorizedAlways) {
        [manager startUpdatingLocation];
    }
}

- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray<CLLocation *> *)locations
{
    // 空实现（@0xff3c，96 字节）：位置伪造由 CLLocationManager 钩子完成
}

#pragma mark - 开关

- (void)locationSwitchChanged:(UISwitch *)sender
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    double latitude  = [defaults doubleForKey:kLatitudeKey];
    double longitude = [defaults doubleForKey:kLongitudeKey];

    if (!sender.isOn || latitude != 0.0 || longitude != 0.0) {
        [defaults setBool:sender.isOn forKey:kLocationSpoofingEnabledKey];
        [defaults synchronize];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LocationSpoofingChanged" object:nil];
    } else {
        [sender setOn:NO animated:YES];
        [self showAlertWithTitle:@"未设置位置" message:@"请先在地图上选择位置或手动输入坐标"];
    }
}

- (void)altitudeSwitchChanged:(UISwitch *)sender
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if (!sender.isOn || [defaults objectForKey:kAltitudeKey] != nil) {
        [defaults setBool:sender.isOn forKey:kAltitudeSpoofingEnabledKey];
        [defaults synchronize];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"AltitudeSpoofingChanged" object:nil];
    } else {
        [sender setOn:NO animated:YES];
        [self showAlertWithTitle:@"未设置海拔" message:@"请先设置海拔高度"];
    }
}

#pragma mark - 校验

- (BOOL)isValidCoordinate:(NSString *)latitudeText lng:(NSString *)longitudeText
{
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    NSNumber *latitude  = [formatter numberFromString:latitudeText];
    NSNumber *longitude = [formatter numberFromString:longitudeText];

    if (latitude == nil || longitude == nil) {
        return NO;
    }

    double lat = latitude.doubleValue;
    double lng = longitude.doubleValue;

    return (lat >= -90.0 && lat <= 90.0 && lng >= -180.0 && lng <= 180.0);
}

- (BOOL)isValidAltitude:(NSString *)text
{
    if (text.length == 0) {
        return NO;
    }

    NSScanner *scanner = [NSScanner scannerWithString:text];
    double value = 0;
    if (![scanner scanDouble:&value]) {
        return NO;
    }

    return scanner.isAtEnd;
}

#pragma mark - 提示 / 关闭

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message
{
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好的"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)closeButtonTapped:(id)sender
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
    [super traitCollectionDidChange:previousTraitCollection];
    [self updateUIForCurrentInterfaceStyle];
}

@end
