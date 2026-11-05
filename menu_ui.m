#import "vcam_menu.h"
#import "vcam_shared.h"
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <UIKit/UIKit.h>
#import <sys/stat.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface VCamMenuViewController : UIViewController <PHPickerViewControllerDelegate>
- (void)setMenuVisible:(BOOL)visible;
@end

@interface VCamPassThroughView : UIView
@property (nonatomic, weak) UIView *floatingControl;
@property (nonatomic, weak) UIView *floatingPanel;
@property (nonatomic) BOOL menuVisible;
- (UIView *)interactiveSubviewAtPoint:(CGPoint)point;
@end

@implementation VCamPassThroughView
- (UIView *)interactiveSubviewAtPoint:(CGPoint)point {
    if (self.floatingControl && !self.floatingControl.hidden) {
        CGPoint controlPoint = [self.floatingControl convertPoint:point fromView:self];
        if (CGRectContainsPoint(self.floatingControl.bounds, controlPoint)) return self.floatingControl;
    }

    if (self.floatingPanel && !self.floatingPanel.hidden) {
        CGPoint panelPoint = [self.floatingPanel convertPoint:point fromView:self];
        UIView *candidate = [self.floatingPanel hitTest:panelPoint withEvent:nil];
        for (UIView *view = candidate; view && view != self.floatingPanel; view = view.superview) {
            if ([view isKindOfClass:UIControl.class]) return view;
        }
    }
    return nil;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    if (self.menuVisible) return YES;
    return [self interactiveSubviewAtPoint:point] != nil;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.menuVisible) return [super hitTest:point withEvent:event];
    return [self interactiveSubviewAtPoint:point];
}
@end

@interface VCamOverlayWindow : UIWindow
@end

@implementation VCamOverlayWindow
- (BOOL)canBecomeKeyWindow { return YES; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    VCamPassThroughView *rootView = (VCamPassThroughView *)self.rootViewController.view;
    if (rootView && !rootView.menuVisible) {
        CGPoint rootPoint = [rootView convertPoint:point fromView:self];
        return [rootView hitTest:rootPoint withEvent:event];
    }
    return [super hitTest:point withEvent:event];
}
@end

static VCamOverlayWindow *sOverlayWindow = nil;
// Keep a weak reference to the SpringBoard window that was active before VCam
// temporarily presents its menu. The always-on pass-through overlay must not
// become the key window, otherwise its full-screen controller can participate
// in SpringBoard orientation decisions.
static __weak UIWindow *sPreviousKeyWindow = nil;
static BOOL sMenuVisible = NO;
static BOOL sPendingMenuPresentation = NO;
static NSUInteger sOverlayInstallAttempts = 0;
static NSString * const VCamMoveStepKey = @"MoveStep";
static NSString * const VCamZoomStepKey = @"ZoomStep";
static const CGFloat VCamMoveSteps[] = {0.005, 0.01, 0.02, 0.05, 0.10};
static const CGFloat VCamZoomSteps[] = {0.01, 0.02, 0.05, 0.10, 0.20, 0.50};
static const NSUInteger VCamMoveStepCount = sizeof(VCamMoveSteps) / sizeof(VCamMoveSteps[0]);
static const NSUInteger VCamZoomStepCount = sizeof(VCamZoomSteps) / sizeof(VCamZoomSteps[0]);

static CGFloat VCamSelectedStep(NSString *key, const CGFloat *steps, NSUInteger count, CGFloat fallback) {
    id stored = VCamCopySetting(key);
    if (![stored respondsToSelector:@selector(doubleValue)]) return fallback;

    CGFloat value = [stored doubleValue];
    NSUInteger bestIndex = 0;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (NSUInteger index = 0; index < count; index++) {
        CGFloat distance = fabs(value - steps[index]);
        if (distance < bestDistance) {
            bestDistance = distance;
            bestIndex = index;
        }
    }
    return steps[bestIndex];
}

static CGFloat VCamCurrentMoveStep(void) {
    return VCamSelectedStep(VCamMoveStepKey, VCamMoveSteps, VCamMoveStepCount, 0.05);
}

static CGFloat VCamCurrentZoomStep(void) {
    return VCamSelectedStep(VCamZoomStepKey, VCamZoomSteps, VCamZoomStepCount, 0.10);
}
static NSString * const VCamMovieTypeIdentifier = @"public.movie";
static NSString * const VCamImageTypeIdentifier = @"public.image";
static NSString * const VCamOffsetCoordinateVersionKey = @"OffsetCoordinateVersion";

// Older builds stored Y in Core Image's Y-up coordinate space. New builds
// store both offsets in screen coordinates (UIKit's Y-down space), so migrate
// the old Y value once to preserve the current on-screen position.
static void VCamMigrateOffsetCoordinatesIfNeeded(void) {
    NSInteger version = [VCamCopySetting(VCamOffsetCoordinateVersionKey) integerValue];
    if (version >= 1) return;

    id oldYValue = VCamCopySetting(VCamOffsetYKey);
    if ([oldYValue respondsToSelector:@selector(doubleValue)]) {
        VCamSetSetting(VCamOffsetYKey, @(-[oldYValue doubleValue]));
    }
    VCamSetSetting(VCamOffsetCoordinateVersionKey, @1);
}

static UIButton *VCamMakeButton(NSString *title, UIColor *background, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = background;
    button.layer.cornerRadius = 11.0;
    button.layer.masksToBounds = YES;
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.contentEdgeInsets = UIEdgeInsetsMake(9, 10, 9, 10);
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
    return button;
}

static UIButton *VCamMakeIconButton(NSString *symbolName, NSString *accessibilityLabel, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *image = [UIImage systemImageNamed:symbolName];
    [button setImage:image forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    button.layer.cornerRadius = 9.0;
    button.layer.masksToBounds = YES;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:34.0].active = YES;
    [button.heightAnchor constraintEqualToConstant:34.0].active = YES;
    button.accessibilityLabel = accessibilityLabel;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

static UILabel *VCamMakeLabel(NSString *text, UIFont *font, UIColor *color) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

@implementation VCamMenuViewController {
    UILabel *_statusLabel;
    UILabel *_diagnosticLabel;
    UIButton *_toggleButton;
    UIButton *_controlVisibilityButton;
    UIButton *_videoButton;
    UIButton *_logsButton;
    UIButton *_settingsButton;
    UIStackView *_settingsContainer;
    UILabel *_movementStepLabel;
    UILabel *_zoomStepLabel;
    UISlider *_movementStepSlider;
    UISlider *_zoomStepSlider;
    UIButton *_backdrop;
    UIView *_panel;
    NSLayoutConstraint *_panelWidthConstraint;
    NSLayoutConstraint *_panelHeightConstraint;
    UIStackView *_logsContainer;
    VCamPassThroughView *_passThroughView;
    UIButton *_floatingControl;
    UIView *_floatingPanel;
    CGPoint _floatingStartCenter;
    NSTimer *_diagnosticTimer;
}

// The overlay is attached to SpringBoard's scene for its entire lifetime.
// UIKit otherwise treats this full-screen controller as an autorotating
// participant in the scene and may rotate the Home Screen when device
// orientation changes. SpringBoard on this iPhone should remain portrait;
// this controller must never request or advertise landscape support.
- (BOOL)shouldAutorotate {
    return NO;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return UIInterfaceOrientationPortrait;
}

- (void)loadView {
    _passThroughView = [[VCamPassThroughView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _passThroughView.backgroundColor = UIColor.clearColor;
    self.view = _passThroughView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    VCamMigrateOffsetCoordinatesIfNeeded();

    _backdrop = [UIButton buttonWithType:UIButtonTypeCustom];
    _backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    _backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.48];
    [_backdrop addTarget:self action:@selector(closeMenu) forControlEvents:UIControlEventTouchUpInside];
    _backdrop.hidden = YES;
    [self.view addSubview:_backdrop];
    [NSLayoutConstraint activateConstraints:@[
        [_backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    blur.layer.cornerRadius = 22;
    blur.layer.masksToBounds = YES;
    blur.layer.borderWidth = 1;
    blur.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    _panel = blur;
    _panel.hidden = YES;
    [self.view addSubview:blur];
    CGFloat panelWidth = MIN(UIScreen.mainScreen.bounds.size.width - 32.0, 350.0);
    CGFloat panelHeight = MIN(UIScreen.mainScreen.bounds.size.height - 72.0, 470.0);
    _panelWidthConstraint = [blur.widthAnchor constraintEqualToConstant:panelWidth];
    _panelHeightConstraint = [blur.heightAnchor constraintEqualToConstant:panelHeight];
    [NSLayoutConstraint activateConstraints:@[
        [blur.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [blur.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        _panelWidthConstraint,
        _panelHeightConstraint
    ]];

    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    [blur.contentView addSubview:scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:blur.contentView.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:blur.contentView.bottomAnchor]
    ]];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor constant:-32]
    ]];

    UIStackView *header = [[UIStackView alloc] init];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 8;
    UIStackView *titleGroup = [[UIStackView alloc] init];
    titleGroup.axis = UILayoutConstraintAxisVertical;
    titleGroup.alignment = UIStackViewAlignmentLeading;
    titleGroup.spacing = 1;
    UILabel *title = VCamMakeLabel(@"VCam", [UIFont systemFontOfSize:22 weight:UIFontWeightBold], UIColor.whiteColor);
    UILabel *byline = VCamMakeLabel(@"by tinysweet", [UIFont systemFontOfSize:11 weight:UIFontWeightMedium], [UIColor colorWithWhite:1 alpha:0.58]);
    [titleGroup addArrangedSubview:title];
    [titleGroup addArrangedSubview:byline];
    [header addArrangedSubview:titleGroup];
    [header addArrangedSubview:[[UIView alloc] init]];
    UIButton *close = VCamMakeButton(@"✕", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(closeMenu));
    [close.widthAnchor constraintEqualToConstant:42].active = YES;
    [header addArrangedSubview:close];
    [stack addArrangedSubview:header];

    _statusLabel = VCamMakeLabel(@"No replacement media selected", [UIFont systemFontOfSize:13], [UIColor colorWithWhite:1 alpha:0.72]);
    [stack addArrangedSubview:_statusLabel];

    UIButton *chooseButton = VCamMakeButton(@"Choose Photo / Video", [UIColor colorWithRed:0.20 green:0.42 blue:0.86 alpha:1], self, @selector(chooseMedia));
    [stack addArrangedSubview:chooseButton];

    _toggleButton = VCamMakeButton(@"Enable Replacement", [UIColor colorWithRed:0.13 green:0.52 blue:0.32 alpha:1], self, @selector(toggleReplacement));
    [stack addArrangedSubview:_toggleButton];

    _controlVisibilityButton = VCamMakeButton(@"Hide Control", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(toggleFloatingControlVisibility));
    [stack addArrangedSubview:_controlVisibilityButton];

    _settingsButton = VCamMakeButton(@"Settings", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(toggleSettings));
    [stack addArrangedSubview:_settingsButton];

    UIStackView *settingsStack = [[UIStackView alloc] init];
    settingsStack.axis = UILayoutConstraintAxisVertical;
    settingsStack.spacing = 8;
    settingsStack.translatesAutoresizingMaskIntoConstraints = NO;
    _settingsContainer = settingsStack;
    _settingsContainer.hidden = YES;
    _settingsContainer.layoutMargins = UIEdgeInsetsMake(10, 12, 10, 12);
    _settingsContainer.preservesSuperviewLayoutMargins = NO;
    _settingsContainer.backgroundColor = [UIColor colorWithWhite:0 alpha:0.20];
    _settingsContainer.layer.cornerRadius = 12;
    [_settingsContainer setLayoutMarginsRelativeArrangement:YES];
    [stack addArrangedSubview:_settingsContainer];

    UILabel *settingsTitle = VCamMakeLabel(@"Control sensitivity", [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold], UIColor.whiteColor);
    [_settingsContainer addArrangedSubview:settingsTitle];

    _movementStepLabel = VCamMakeLabel(@"Movement per tap", [UIFont systemFontOfSize:12 weight:UIFontWeightMedium], [UIColor colorWithWhite:1 alpha:0.82]);
    [_settingsContainer addArrangedSubview:_movementStepLabel];
    _movementStepSlider = [[UISlider alloc] init];
    _movementStepSlider.minimumValue = 0;
    _movementStepSlider.maximumValue = (float)(VCamMoveStepCount - 1);
    _movementStepSlider.value = 3;
    _movementStepSlider.continuous = NO;
    _movementStepSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [_movementStepSlider addTarget:self action:@selector(movementStepChanged:) forControlEvents:UIControlEventValueChanged];
    [_settingsContainer addArrangedSubview:_movementStepSlider];

    _zoomStepLabel = VCamMakeLabel(@"Zoom per tap", [UIFont systemFontOfSize:12 weight:UIFontWeightMedium], [UIColor colorWithWhite:1 alpha:0.82]);
    [_settingsContainer addArrangedSubview:_zoomStepLabel];
    _zoomStepSlider = [[UISlider alloc] init];
    _zoomStepSlider.minimumValue = 0;
    _zoomStepSlider.maximumValue = (float)(VCamZoomStepCount - 1);
    _zoomStepSlider.value = 3;
    _zoomStepSlider.continuous = NO;
    _zoomStepSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [_zoomStepSlider addTarget:self action:@selector(zoomStepChanged:) forControlEvents:UIControlEventValueChanged];
    [_settingsContainer addArrangedSubview:_zoomStepSlider];

    UILabel *settingsHint = VCamMakeLabel(@"Smaller steps give finer control. Larger steps move or zoom faster.", [UIFont systemFontOfSize:11], [UIColor colorWithWhite:1 alpha:0.58]);
    [_settingsContainer addArrangedSubview:settingsHint];
    [self refreshStepSettings];

    _logsButton = VCamMakeButton(@"View Logs", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(toggleLogs));
    [stack addArrangedSubview:_logsButton];

    UIStackView *logsStack = [[UIStackView alloc] init];
    logsStack.axis = UILayoutConstraintAxisVertical;
    logsStack.spacing = 8;
    logsStack.translatesAutoresizingMaskIntoConstraints = NO;
    _logsContainer = logsStack;
    _logsContainer.hidden = YES;
    [stack addArrangedSubview:_logsContainer];

    _diagnosticLabel = VCamMakeLabel(@"Checking camera service…", [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular], [UIColor colorWithWhite:1 alpha:0.84]);
    _diagnosticLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.20];
    _diagnosticLabel.layer.cornerRadius = 10;
    _diagnosticLabel.layer.masksToBounds = YES;
    _diagnosticLabel.text = @"Checking camera service…";
    [_logsContainer addArrangedSubview:_diagnosticLabel];

    UIButton *copyDiagnostics = VCamMakeButton(@"Copy Logs", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(copyDiagnostics));
    [_logsContainer addArrangedSubview:copyDiagnostics];

    UILabel *footer = VCamMakeLabel(@"Press Volume Up + Volume Down together to open or close VCam.",
                                    [UIFont systemFontOfSize:12], [UIColor colorWithWhite:1 alpha:0.60]);
    [stack addArrangedSubview:footer];

    [self setupFloatingControl];
    [self refreshStatus];

    // Keep the SpringBoard scene portrait-only (so Home Screen rotation is
    // unaffected), but rotate only the VCam menu panel to follow the physical
    // device orientation while the scene itself remains portrait.
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(deviceOrientationDidChange:)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    [self updatePanelForDeviceOrientation:UIDevice.currentDevice.orientation];
    [self setMenuVisible:NO];
}

- (UIStackView *)horizontalRow {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 7;
    row.distribution = UIStackViewDistributionFillEqually;
    return row;
}

- (UIView *)spacer {
    UIView *view = [[UIView alloc] init];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    return view;
}

- (void)setupFloatingControl {
    _floatingControl = [UIButton buttonWithType:UIButtonTypeSystem];
    [_floatingControl setImage:[UIImage systemImageNamed:@"slider.horizontal.3"] forState:UIControlStateNormal];
    _floatingControl.tintColor = UIColor.whiteColor;
    _floatingControl.accessibilityLabel = @"Open camera controls";
    _floatingControl.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    _floatingControl.layer.cornerRadius = 19.0;
    _floatingControl.layer.borderWidth = 1;
    _floatingControl.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.24].CGColor;
    _floatingControl.layer.shadowColor = UIColor.blackColor.CGColor;
    _floatingControl.layer.shadowOpacity = 0.28;
    _floatingControl.layer.shadowRadius = 7;
    _floatingControl.layer.shadowOffset = CGSizeMake(0, 2);
    _floatingControl.frame = CGRectMake(UIScreen.mainScreen.bounds.size.width - 52.0,
                                        UIScreen.mainScreen.bounds.size.height * 0.68,
                                        38.0, 38.0);
    // Keep the floating Control button hidden after startup. Users can show it
    // explicitly from the main VCam menu using the Show Control button.
    _floatingControl.hidden = YES;
    [_floatingControl addTarget:self action:@selector(toggleFloatingPanel) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *openMenuPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(openMainMenuFromControl:)];
    openMenuPress.minimumPressDuration = 0.65;
    openMenuPress.cancelsTouchesInView = YES;
    [_floatingControl addGestureRecognizer:openMenuPress];
    [self.view addSubview:_floatingControl];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragFloatingControl:)];
    pan.cancelsTouchesInView = NO;
    [_floatingControl addGestureRecognizer:pan];

    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    panel.frame = CGRectMake(0, 0, 140, 250);
    panel.layer.cornerRadius = 15;
    panel.layer.masksToBounds = YES;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    panel.hidden = YES;
    _floatingPanel = panel;
    [self.view addSubview:panel];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 5;
    stack.alignment = UIStackViewAlignmentFill;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [panel.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-8],
        [stack.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-8]
    ]];

    // Rotation row: keep the two rotation actions together.
    UIStackView *row1 = [self horizontalRow];
    [row1 addArrangedSubview:VCamMakeIconButton(@"rotate.left", @"Rotate left", self, @selector(rotateLeft))];
    [row1 addArrangedSubview:VCamMakeIconButton(@"rotate.right", @"Rotate right", self, @selector(rotateRight))];
    [row1 addArrangedSubview:[self spacer]];

    // Direction pad: up / left-reset-right / down, in their expected positions.
    UIStackView *row2 = [self horizontalRow];
    [row2 addArrangedSubview:[self spacer]];
    [row2 addArrangedSubview:VCamMakeIconButton(@"arrow.up", @"Move up", self, @selector(moveUp))];
    [row2 addArrangedSubview:[self spacer]];

    UIStackView *row3 = [self horizontalRow];
    [row3 addArrangedSubview:VCamMakeIconButton(@"arrow.left", @"Move left", self, @selector(moveLeft))];
    [row3 addArrangedSubview:VCamMakeIconButton(@"scope", @"Reset position", self, @selector(resetPosition))];
    [row3 addArrangedSubview:VCamMakeIconButton(@"arrow.right", @"Move right", self, @selector(moveRight))];

    UIStackView *row4 = [self horizontalRow];
    [row4 addArrangedSubview:[self spacer]];
    [row4 addArrangedSubview:VCamMakeIconButton(@"arrow.down", @"Move down", self, @selector(moveDown))];
    [row4 addArrangedSubview:[self spacer]];

    UIStackView *row5 = [self horizontalRow];
    [row5 addArrangedSubview:VCamMakeIconButton(@"minus.magnifyingglass", @"Zoom out", self, @selector(zoomOut))];
    [row5 addArrangedSubview:VCamMakeIconButton(@"plus.magnifyingglass", @"Zoom in", self, @selector(zoomIn))];
    _videoButton = VCamMakeIconButton(@"pause.fill", @"Pause video", self, @selector(toggleVideoPlayback));
    [row5 addArrangedSubview:_videoButton];

    UIStackView *row6 = [self horizontalRow];
    [row6 addArrangedSubview:VCamMakeIconButton(@"eye.slash", @"Hide floating control", self, @selector(hideFloatingControl))];
    [row6 addArrangedSubview:VCamMakeIconButton(@"xmark", @"Close controls", self, @selector(toggleFloatingPanel))];
    [row6 addArrangedSubview:[self spacer]];

    [stack addArrangedSubview:row1];
    [stack addArrangedSubview:row2];
    [stack addArrangedSubview:row3];
    [stack addArrangedSubview:row4];
    [stack addArrangedSubview:row5];
    [stack addArrangedSubview:row6];

    _passThroughView.floatingControl = _floatingControl;
    _passThroughView.floatingPanel = _floatingPanel;
    [self updateControlVisibilityButton];
    [self updateVideoButton];
    [self.view bringSubviewToFront:_floatingPanel];
    [self.view bringSubviewToFront:_floatingControl];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutFloatingPanel];
}

- (void)layoutFloatingPanel {
    if (!_floatingPanel || !_floatingControl) return;
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat height = CGRectGetHeight(self.view.bounds);
    CGRect buttonFrame = _floatingControl.frame;
    CGFloat panelWidth = CGRectGetWidth(_floatingPanel.bounds);
    CGFloat panelHeight = CGRectGetHeight(_floatingPanel.bounds);
    CGFloat x = CGRectGetMidX(buttonFrame) > width * 0.5 ? 12.0 : width - panelWidth - 12.0;
    CGFloat y = CGRectGetMinY(buttonFrame) > height * 0.55
        ? CGRectGetMinY(buttonFrame) - panelHeight - 10.0
        : CGRectGetMaxY(buttonFrame) + 10.0;
    x = MAX(8.0, MIN(width - panelWidth - 8.0, x));
    y = MAX(8.0, MIN(height - panelHeight - 8.0, y));
    _floatingPanel.frame = CGRectMake(x, y, panelWidth, panelHeight);
}

- (void)openMainMenuFromControl:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [VCamMenuPresenter showMenu];
    }
}

- (void)toggleFloatingPanel {
    _floatingPanel.hidden = !_floatingPanel.hidden;
    [self layoutFloatingPanel];
    if (!_floatingPanel.hidden) [self.view bringSubviewToFront:_floatingPanel];
    [self.view bringSubviewToFront:_floatingControl];
}

- (void)updateControlVisibilityButton {
    BOOL hidden = _floatingControl.hidden;
    [_controlVisibilityButton setTitle:(hidden ? @"Show Control" : @"Hide Control") forState:UIControlStateNormal];
}

- (void)toggleFloatingControlVisibility {
    if (!_floatingControl) return;
    _floatingControl.hidden = !_floatingControl.hidden;
    _floatingPanel.hidden = YES;
    [self updateControlVisibilityButton];
}

- (void)hideFloatingControl {
    _floatingControl.hidden = YES;
    _floatingPanel.hidden = YES;
    [self updateControlVisibilityButton];
}

- (void)updateVideoButton {
    if (!_videoButton) return;
    NSString *mediaType = VCamCopySetting(VCamMediaTypeKey);
    BOOL isVideo = [mediaType isKindOfClass:NSString.class] && [mediaType isEqualToString:@"video"];
    BOOL paused = [VCamCopySetting(VCamVideoPausedKey) boolValue];
    NSString *symbol = paused ? @"play.fill" : @"pause.fill";
    [_videoButton setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    _videoButton.enabled = isVideo;
    _videoButton.alpha = isVideo ? 1.0 : 0.35;
    _videoButton.accessibilityLabel = paused ? @"Resume video" : @"Pause video";
}

- (void)toggleVideoPlayback {
    NSString *mediaType = VCamCopySetting(VCamMediaTypeKey);
    if (![mediaType isKindOfClass:NSString.class] || ![mediaType isEqualToString:@"video"]) return;
    BOOL paused = [VCamCopySetting(VCamVideoPausedKey) boolValue];
    VCamSetSetting(VCamVideoPausedKey, @(!paused));
    [self updateVideoButton];
}

- (void)dragFloatingControl:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        _floatingStartCenter = _floatingControl.center;
        [self.view bringSubviewToFront:_floatingControl];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [gesture translationInView:self.view];
        CGPoint center = CGPointMake(_floatingStartCenter.x + translation.x, _floatingStartCenter.y + translation.y);
        CGFloat halfWidth = CGRectGetWidth(_floatingControl.bounds) * 0.5;
        CGFloat halfHeight = CGRectGetHeight(_floatingControl.bounds) * 0.5;
        center.x = MAX(halfWidth + 6.0, MIN(CGRectGetWidth(self.view.bounds) - halfWidth - 6.0, center.x));
        center.y = MAX(halfHeight + 8.0, MIN(CGRectGetHeight(self.view.bounds) - halfHeight - 8.0, center.y));
        _floatingControl.center = center;
        [self layoutFloatingPanel];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self setMenuVisible:YES];
}

- (void)deviceOrientationDidChange:(NSNotification *)notification {
    (void)notification;
    UIDeviceOrientation orientation = UIDevice.currentDevice.orientation;
    if (orientation != UIDeviceOrientationPortrait &&
        orientation != UIDeviceOrientationLandscapeLeft &&
        orientation != UIDeviceOrientationLandscapeRight) {
        // Ignore face-up/face-down/unknown transitions to avoid snapping the
        // panel back to portrait while the device is being moved.
        return;
    }

    if ([NSThread isMainThread]) {
        [self updatePanelForDeviceOrientation:orientation];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updatePanelForDeviceOrientation:orientation];
        });
    }
}

- (void)updatePanelForDeviceOrientation:(UIDeviceOrientation)orientation {
    if (!_panel || !_panelWidthConstraint || !_panelHeightConstraint) return;

    BOOL landscape = (orientation == UIDeviceOrientationLandscapeLeft ||
                      orientation == UIDeviceOrientationLandscapeRight);
    CGSize bounds = self.view.bounds.size;
    CGFloat shortEdge = MIN(bounds.width, bounds.height);
    CGFloat longEdge = MAX(bounds.width, bounds.height);

    if (landscape) {
        // The controller/window stays portrait. Use a landscape-sized panel
        // in its own coordinate space and rotate just this panel, keeping its
        // transformed bounds inside the portrait SpringBoard scene.
        _panelWidthConstraint.constant = MIN(longEdge - 72.0, 470.0);
        _panelHeightConstraint.constant = MIN(shortEdge - 32.0, 350.0);
        CGFloat angle = (orientation == UIDeviceOrientationLandscapeLeft) ? (CGFloat)-M_PI_2 : (CGFloat)M_PI_2;
        _panel.transform = CGAffineTransformMakeRotation(angle);
    } else {
        _panelWidthConstraint.constant = MIN(shortEdge - 32.0, 350.0);
        _panelHeightConstraint.constant = MIN(longEdge - 72.0, 470.0);
        _panel.transform = CGAffineTransformIdentity;
    }

    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
    [_diagnosticTimer invalidate];
}

- (NSString *)diagnosticText {
    NSDictionary *combined = VCamCopyRuntimeStatus();
    NSDictionary *daemonStatuses = [combined[@"daemonStatuses"] isKindOfClass:[NSDictionary class]] ? combined[@"daemonStatuses"] : @{};
    NSDictionary *mediaDaemon = [daemonStatuses[@"mediaserverd"] isKindOfClass:[NSDictionary class]] ? daemonStatuses[@"mediaserverd"] : @{};
    BOOL mediaLoaded = [mediaDaemon[@"runtimeVersion"] isEqualToString:VCamRuntimeVersion] && [mediaDaemon[@"daemonLoaded"] boolValue];
    NSDictionary *runtime = mediaDaemon.count ? mediaDaemon : combined;

    NSString *processName = [runtime[@"daemonProcess"] isKindOfClass:[NSString class]] ? runtime[@"daemonProcess"] : @"mediaserverd";
    NSString *hookState = [runtime[@"hookState"] isKindOfClass:[NSString class]] ? runtime[@"hookState"] : @"unknown";
    BOOL framesSeen = [runtime[@"cameraFramesSeen"] boolValue];
    BOOL rendered = [runtime[@"replacementRendered"] boolValue];
    NSString *mediaState = [runtime[@"mediaState"] isKindOfClass:[NSString class]] ? runtime[@"mediaState"] : @"not-checked";
    NSString *mediaDetail = [runtime[@"mediaDetail"] isKindOfClass:[NSString class]] ? runtime[@"mediaDetail"] : @"";
    NSString *hookDetail = [runtime[@"hookDetail"] isKindOfClass:[NSString class]] ? runtime[@"hookDetail"] : @"";
    NSString *renderError = [runtime[@"renderError"] isKindOfClass:[NSString class]] ? runtime[@"renderError"] : @"";
    NSInteger heartbeatAge = [runtime[@"heartbeatAgeSeconds"] respondsToSelector:@selector(integerValue)] ? [runtime[@"heartbeatAgeSeconds"] integerValue] : -1;

    NSString *daemonLine = mediaLoaded ? [NSString stringWithFormat:@"Camera daemon injection: YES (%@)", processName] : @"Camera daemon injection: NO HEARTBEAT from mediaserverd";
    NSString *heartbeatLine = heartbeatAge >= 0 ? [NSString stringWithFormat:@"mediaserverd heartbeat: %@ (%lds ago)", mediaLoaded ? @"ALIVE" : @"STALE", (long)heartbeatAge] : @"mediaserverd heartbeat: NOT RECEIVED";
    NSString *frameLine = framesSeen ? [NSString stringWithFormat:@"Camera frames: RECEIVED (%@)", runtime[@"cameraFrameSize"] ?: @"size unknown"] : @"Camera frames: WAITING (open Camera and start preview)";
    NSString *mediaLine = [NSString stringWithFormat:@"Media: %@%@", mediaState.uppercaseString, mediaDetail.length ? [@" — " stringByAppendingString:mediaDetail] : @""];
    NSString *enabledLine = [runtime[@"replacementEnabled"] respondsToSelector:@selector(boolValue)]
        ? [NSString stringWithFormat:@"Replacement state (mediaserverd): %@", [runtime[@"replacementEnabled"] boolValue] ? @"ON" : @"OFF"]
        : @"Replacement state (mediaserverd): WAITING";
    NSString *outputLine = rendered ? [NSString stringWithFormat:@"Buffer render call: SENT (%@)", runtime[@"renderedFrameSize"] ?: @"size unknown"] : @"Buffer render call: NOT SENT YET";
    BOOL selectionReceived = [runtime[@"mediaSelectionReceived"] boolValue];
    NSString *selectionName = [runtime[@"mediaSelectionFilename"] isKindOfClass:NSString.class] ? runtime[@"mediaSelectionFilename"] : @"";
    NSString *selectionLine = selectionReceived
        ? [NSString stringWithFormat:@"Media selection (daemon): RECEIVED (%@)", selectionName.length ? selectionName : @"filename unavailable"]
        : @"Media selection (daemon): NOT RECEIVED";

    NSString *daemonVersion = [runtime[@"runtimeVersion"] isKindOfClass:NSString.class] ? runtime[@"runtimeVersion"] : @"unknown";
    NSString *fileAccess = [runtime[@"mediaFileAccess"] isKindOfClass:NSString.class] ? [runtime[@"mediaFileAccess"] uppercaseString] : @"WAITING";
    NSString *videoPump = [runtime[@"videoFramePump"] isKindOfClass:NSString.class] ? runtime[@"videoFramePump"] : @"not-active";
    NSString *videoFrameSize = [runtime[@"videoFrameSize"] isKindOfClass:NSString.class] ? runtime[@"videoFrameSize"] : @"waiting";
    NSString *videoPlayerError = [runtime[@"videoPlayerError"] isKindOfClass:NSString.class] ? runtime[@"videoPlayerError"] : @"";
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithArray:@[
        daemonLine,
        [NSString stringWithFormat:@"Camera daemon version: %@", daemonVersion],
        heartbeatLine,
        [NSString stringWithFormat:@"BWNodeOutput hook: %@", hookState.uppercaseString],
        frameLine,
        enabledLine,
        selectionLine,
        [NSString stringWithFormat:@"Media file access: %@", fileAccess],
        [NSString stringWithFormat:@"Video frame pump: %@ (%@)", videoPump.uppercaseString, videoFrameSize],
        mediaLine,
        outputLine,
        [NSString stringWithFormat:@"Hook frames observed: %@", runtime[@"cameraHookFrameCount"] ?: @0],
        [NSString stringWithFormat:@"Replacement renders completed: %@", runtime[@"replacementRenderCount"] ?: @0],
        [NSString stringWithFormat:@"Last render size: %@", runtime[@"replacementRenderLastSize"] ?: @"not recorded"],
        [NSString stringWithFormat:@"Render skip reason: %@", runtime[@"renderSkipReason"] ?: @"none — render path reached"],
        @"Camera coverage: front and rear live preview streams"
    ]];
    if (hookDetail.length) [lines addObject:[@"Hook detail: " stringByAppendingString:hookDetail]];
    if (renderError.length) [lines addObject:[@"Render error: " stringByAppendingString:renderError]];
    if (videoPlayerError.length) [lines addObject:[@"Video player error: " stringByAppendingString:videoPlayerError]];
    if ([runtime[@"mediaRetryCount"] respondsToSelector:@selector(integerValue)] && [runtime[@"mediaRetryCount"] integerValue] > 0) {
        [lines addObject:[NSString stringWithFormat:@"Media load retries: %@ (next retry in %@s)", runtime[@"mediaRetryCount"], runtime[@"mediaRetryAfterSeconds"] ?: @"?"]];
    }

    if (!mediaLoaded) {
        [lines addObject:@"Action: enable Tweak Injection in Relaxin and run a Userspace Reboot."];
    } else if (![hookState isEqualToString:@"installed"]) {
        [lines addObject:@"Action: the camera hook is not installed. Check Hook detail."];
    } else if (!framesSeen) {
        [lines addObject:@"Action: open the built-in Camera app and start a live preview."];
    } else if ([mediaState isEqualToString:@"disabled"]) {
        [lines addObject:@"Action: enable Replacement."];
    } else if ([mediaState isEqualToString:@"no-selection"]) {
        [lines addObject:@"Action: choose a photo or video."];
    } else if ([mediaState isEqualToString:@"file-not-readable"]) {
        [lines addObject:@"Action: check Media file access and errno; confirm the camera daemon can open the file under /tmp/VCamMedia."];
    } else if ([mediaState isEqualToString:@"video-player-failed"]) {
        [lines addObject:@"Action: video playback was stopped safely. Re-import a compatible video; check Video player error for details."];
    } else if ([mediaState containsString:@"failed"] || [mediaState containsString:@"not-found"] || [mediaState containsString:@"missing"]) {
        [lines addObject:@"Action: choose the media again and check Media file access."];
    } else if (!rendered) {
        [lines addObject:@"Action: wait for the camera frame to be replaced, then check Media above."];
    } else {
        [lines addObject:@"Status: at least one replacement render completed; use the counters above to confirm continuous rendering."];
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (void)refreshStatusTimer:(NSTimer *)timer {
    (void)timer;
    [self refreshStatus];
}

- (void)refreshStatus {
    NSString *path = VCamCopySetting(VCamMediaPathKey);
    BOOL enabled = [VCamCopySetting(VCamEnabledKey) boolValue];
    if ([path isKindOfClass:[NSString class]] && path.length > 0) {
        _statusLabel.text = [NSString stringWithFormat:@"Selected: %@ · %@", path.lastPathComponent, enabled ? @"Enabled" : @"Disabled"];
    } else {
        _statusLabel.text = @"No replacement media selected";
    }
    [_toggleButton setTitle:(enabled ? @"Disable Replacement" : @"Enable Replacement") forState:UIControlStateNormal];
    _toggleButton.backgroundColor = enabled ? [UIColor colorWithRed:0.66 green:0.25 blue:0.22 alpha:1]
                                            : [UIColor colorWithRed:0.13 green:0.52 blue:0.32 alpha:1];
    _diagnosticLabel.text = [self diagnosticText];
    [self updateControlVisibilityButton];
    [self updateVideoButton];
}

- (void)toggleLogs {
    _logsContainer.hidden = !_logsContainer.hidden;
    [_logsButton setTitle:(_logsContainer.hidden ? @"View Logs" : @"Hide Logs") forState:UIControlStateNormal];
    if (!_logsContainer.hidden) _diagnosticLabel.text = [self diagnosticText];
}

- (void)copyDiagnostics {
    UIPasteboard.generalPasteboard.string = [self diagnosticText];
    _logsContainer.hidden = NO;
    [_logsButton setTitle:@"Hide Logs" forState:UIControlStateNormal];
    _diagnosticLabel.text = [[self diagnosticText] stringByAppendingString:@"\n\nCopied to clipboard."];
}

- (void)setMenuVisible:(BOOL)visible {
    if (!self.isViewLoaded) return;
    sMenuVisible = visible;
    [self updatePanelForDeviceOrientation:UIDevice.currentDevice.orientation];
    _passThroughView.menuVisible = visible;
    _backdrop.hidden = !visible;
    _panel.hidden = !visible;
    if (visible) {
        [self refreshStatus];
        if (!_diagnosticTimer) {
            _diagnosticTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                               target:self
                                                             selector:@selector(refreshStatusTimer:)
                                                             userInfo:nil
                                                              repeats:YES];
        }
    } else {
        [_diagnosticTimer invalidate];
        _diagnosticTimer = nil;
    }
    if (!_floatingPanel.hidden) [self.view bringSubviewToFront:_floatingPanel];
    if (!_floatingControl.hidden) [self.view bringSubviewToFront:_floatingControl];
}

- (void)closeMenu {
    [VCamMenuPresenter hideMenu];
}

- (void)chooseMedia {
    PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
    configuration.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[[PHPickerFilter imagesFilter], [PHPickerFilter videosFilter]]];
    configuration.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    PHPickerResult *result = results.firstObject;
    [picker dismissViewControllerAnimated:YES completion:^{
        if (result) [self importProvider:result.itemProvider];
    }];
}

- (void)finishImportAtPath:(NSString *)path mediaType:(NSString *)mediaType filename:(NSString *)filename {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    VCamSetSetting(VCamMediaTypeKey, mediaType);
    VCamSetSetting(VCamVideoPausedKey, @NO);
    VCamSetSetting(VCamMediaPathKey, path);
    VCamSetSetting(VCamEnabledKey, @YES);

    NSString *directory = VCamMediaDirectory();
    for (NSString *existingName in [fileManager contentsOfDirectoryAtPath:directory error:nil]) {
        if (![existingName hasPrefix:@"media-"] || [existingName isEqualToString:filename]) continue;
        NSString *existingPath = [directory stringByAppendingPathComponent:existingName];
        [fileManager removeItemAtPath:existingPath error:nil];
    }
    if (!VCamCopySetting(VCamZoomKey)) VCamSetSetting(VCamZoomKey, @1.0);
    if (!VCamCopySetting(VCamOffsetXKey)) VCamSetSetting(VCamOffsetXKey, @0.0);
    if (!VCamCopySetting(VCamOffsetYKey)) VCamSetSetting(VCamOffsetYKey, @0.0);
    if (!VCamCopySetting(VCamRotationKey)) VCamSetSetting(VCamRotationKey, @0);

    dispatch_async(dispatch_get_main_queue(), ^{
        self->_statusLabel.text = [mediaType isEqualToString:@"video"]
            ? @"Video optimized · Ready for camera"
            : @"Media imported · Ready for camera";
        [self refreshStatus];
        [self updateVideoButton];
    });
}

- (void)optimizeVideoAtPath:(NSString *)sourcePath
                 outputPath:(NSString *)outputPath
                   filename:(NSString *)filename {
    NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:sourceURL options:@{ AVURLAssetPreferPreciseDurationAndTimingKey: @NO }];
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    AVAssetTrack *videoTrack = tracks.firstObject;
    NSArray<NSString *> *compatiblePresets = [AVAssetExportSession exportPresetsCompatibleWithAsset:asset];

    NSString *preset = nil;
    if ([compatiblePresets containsObject:AVAssetExportPreset1920x1080]) {
        preset = AVAssetExportPreset1920x1080;
    } else if ([compatiblePresets containsObject:AVAssetExportPreset1280x720]) {
        preset = AVAssetExportPreset1280x720;
    }

    if (!videoTrack || !preset || !CMTIME_IS_NUMERIC(asset.duration) || CMTimeGetSeconds(asset.duration) <= 0.0) {
        [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_statusLabel.text = @"Video format cannot be optimized for camera";
            [self refreshStatus];
        });
        return;
    }

    AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:preset];
    if (!session) {
        [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_statusLabel.text = @"Could not prepare video optimizer";
            [self refreshStatus];
        });
        return;
    }

    // Normalize rotation and cap the exported stream at 30 fps. This keeps
    // large/high-frame-rate source clips from making mediaserverd decode and
    // transform oversized frames on every camera callback.
    CGRect sourceRect = CGRectApplyAffineTransform(
        CGRectMake(0.0, 0.0, videoTrack.naturalSize.width, videoTrack.naturalSize.height),
        videoTrack.preferredTransform);
    CGFloat renderWidth = fabs(sourceRect.size.width);
    CGFloat renderHeight = fabs(sourceRect.size.height);
    if (renderWidth < 2.0 || renderHeight < 2.0) {
        [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_statusLabel.text = @"Video dimensions are invalid";
            [self refreshStatus];
        });
        return;
    }

    CGFloat maxDimension = [preset isEqualToString:AVAssetExportPreset1920x1080] ? 1920.0 : 1280.0;
    CGFloat downscale = MIN(1.0, maxDimension / MAX(renderWidth, renderHeight));
    CGFloat outputWidth = floor(renderWidth * downscale / 2.0) * 2.0;
    CGFloat outputHeight = floor(renderHeight * downscale / 2.0) * 2.0;
    if (outputWidth < 2.0 || outputHeight < 2.0) {
        [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_statusLabel.text = @"Video dimensions are too small to optimize";
            [self refreshStatus];
        });
        return;
    }

    AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
    videoComposition.renderSize = CGSizeMake(outputWidth, outputHeight);
    videoComposition.frameDuration = CMTimeMake(1, 30);
    AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
    AVMutableVideoCompositionLayerInstruction *layerInstruction =
        [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:videoTrack];
    CGAffineTransform preferred = videoTrack.preferredTransform;
    CGAffineTransform normalizedTransform = CGAffineTransformMake(
        preferred.a * downscale,
        preferred.b * downscale,
        preferred.c * downscale,
        preferred.d * downscale,
        (preferred.tx - CGRectGetMinX(sourceRect)) * downscale,
        (preferred.ty - CGRectGetMinY(sourceRect)) * downscale);
    [layerInstruction setTransform:normalizedTransform atTime:kCMTimeZero];
    instruction.layerInstructions = @[layerInstruction];
    videoComposition.instructions = @[instruction];
    session.videoComposition = videoComposition;

    AVFileType selectedOutputType = nil;
    if ([session.supportedFileTypes containsObject:AVFileTypeMPEG4]) {
        selectedOutputType = AVFileTypeMPEG4;
        outputPath = [[outputPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"mp4"];
    } else if ([session.supportedFileTypes containsObject:AVFileTypeQuickTimeMovie]) {
        selectedOutputType = AVFileTypeQuickTimeMovie;
        outputPath = [[outputPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"mov"];
        filename = outputPath.lastPathComponent;
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_statusLabel.text = @"No compatible video output format is available";
            [self refreshStatus];
        });
        return;
    }

    NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    session.outputURL = outputURL;
    session.outputFileType = selectedOutputType;
    session.shouldOptimizeForNetworkUse = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_statusLabel.text = [preset isEqualToString:AVAssetExportPreset1920x1080]
            ? @"Optimizing video · 1080p / 30 FPS…"
            : @"Optimizing video · 720p / 30 FPS…";
    });

    [session exportAsynchronouslyWithCompletionHandler:^{
        NSDictionary *outputAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:outputPath error:nil];
        BOOL exported = session.status == AVAssetExportSessionStatusCompleted &&
            [outputAttributes[NSFileType] isEqualToString:NSFileTypeRegular] &&
            [outputAttributes[NSFileSize] unsignedLongLongValue] > 0;
        if (exported) {
            chmod(outputPath.fileSystemRepresentation, 0644);
            [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
            [self finishImportAtPath:outputPath mediaType:@"video" filename:filename];
        } else {
            NSString *reason = session.error.localizedDescription ?: @"Unknown export error";
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_statusLabel.text = [NSString stringWithFormat:@"Video optimization failed: %@", reason];
                [self refreshStatus];
            });
        }
    }];
}

- (void)importProvider:(NSItemProvider *)provider {
    NSString *typeIdentifier = nil;
    if ([provider hasItemConformingToTypeIdentifier:VCamMovieTypeIdentifier]) typeIdentifier = VCamMovieTypeIdentifier;
    else if ([provider hasItemConformingToTypeIdentifier:VCamImageTypeIdentifier]) typeIdentifier = VCamImageTypeIdentifier;
    if (!typeIdentifier) {
        _statusLabel.text = @"Unsupported media type";
        return;
    }

    _statusLabel.text = @"Importing media…";
    [provider loadFileRepresentationForTypeIdentifier:typeIdentifier completionHandler:^(NSURL *temporaryURL, NSError *error) {
        if (!temporaryURL || error) {
            dispatch_async(dispatch_get_main_queue(), ^{ self->_statusLabel.text = @"Could not import the selected media"; });
            return;
        }

        NSString *directory = VCamMediaDirectory();
        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSError *directoryError = nil;
        BOOL directoryCreated = [fileManager createDirectoryAtPath:directory
                                       withIntermediateDirectories:YES
                                                        attributes:@{ NSFilePosixPermissions: @0777 }
                                                             error:&directoryError];
        if (!directoryCreated || directoryError) {
            NSString *reason = directoryError.localizedDescription ?: @"createDirectory returned NO";
            NSLog(@"[VCam] media directory creation failed at %@: %@", directory, reason);
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_statusLabel.text = [NSString stringWithFormat:@"Media folder failed: %@", reason];
            });
            return;
        }
        chmod(directory.fileSystemRepresentation, 0777);

        NSString *extension = temporaryURL.pathExtension.lowercaseString;
        if (extension.length == 0) extension = [typeIdentifier isEqualToString:VCamMovieTypeIdentifier] ? @"mov" : @"jpg";
        NSString *filename = [NSString stringWithFormat:@"media-%@.%@", [[NSUUID UUID] UUIDString], extension];
        NSString *destination = [directory stringByAppendingPathComponent:filename];
        NSError *copyError = nil;
        BOOL copied = [fileManager copyItemAtURL:temporaryURL toURL:[NSURL fileURLWithPath:destination] error:&copyError];
        if (!copied || copyError) {
            NSString *reason = copyError.localizedDescription ?: @"copyItemAtURL returned NO";
            NSLog(@"[VCam] media copy failed from %@ to %@: %@", temporaryURL.path, destination, reason);
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_statusLabel.text = [NSString stringWithFormat:@"Media copy failed: %@", reason];
            });
            return;
        }

        chmod(destination.fileSystemRepresentation, 0644);
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:destination error:&copyError];
        unsigned long long fileSize = [attributes[NSFileSize] unsignedLongLongValue];
        if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular] || fileSize == 0) {
            NSString *reason = copyError.localizedDescription ?: @"saved file is missing, empty, or not regular";
            NSLog(@"[VCam] media verification failed at %@: %@", destination, reason);
            [fileManager removeItemAtPath:destination error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_statusLabel.text = [NSString stringWithFormat:@"Media verification failed: %@", reason];
            });
            return;
        }
        NSLog(@"[VCam] media saved and verified: %@ (%llu bytes)", destination, fileSize);

        if ([typeIdentifier isEqualToString:VCamMovieTypeIdentifier]) {
            NSString *optimizedFilename = [[filename stringByDeletingPathExtension] stringByAppendingString:@"-optimized.mp4"];
            NSString *optimizedPath = [directory stringByAppendingPathComponent:optimizedFilename];
            [self optimizeVideoAtPath:destination outputPath:optimizedPath filename:optimizedFilename];
        } else {
            [self finishImportAtPath:destination mediaType:@"image" filename:filename];
        }
    }];
}

- (void)toggleReplacement {
    BOOL enabled = [VCamCopySetting(VCamEnabledKey) boolValue];
    VCamSetSetting(VCamEnabledKey, @(!enabled));
    [self refreshStatus];
}

- (void)toggleSettings {
    _settingsContainer.hidden = !_settingsContainer.hidden;
    [_settingsButton setTitle:(_settingsContainer.hidden ? @"Settings" : @"Hide Settings") forState:UIControlStateNormal];
    if (!_settingsContainer.hidden) [self refreshStepSettings];
}

- (void)refreshStepSettings {
    CGFloat moveStep = VCamCurrentMoveStep();
    CGFloat zoomStep = VCamCurrentZoomStep();
    NSUInteger moveIndex = 0;
    NSUInteger zoomIndex = 0;
    for (NSUInteger index = 0; index < VCamMoveStepCount; index++) if (fabs(moveStep - VCamMoveSteps[index]) < 0.000001) moveIndex = index;
    for (NSUInteger index = 0; index < VCamZoomStepCount; index++) if (fabs(zoomStep - VCamZoomSteps[index]) < 0.000001) zoomIndex = index;
    _movementStepSlider.value = (float)moveIndex;
    _zoomStepSlider.value = (float)zoomIndex;
    _movementStepLabel.text = [NSString stringWithFormat:@"Movement per tap: %.1f%%", moveStep * 100.0];
    _zoomStepLabel.text = [NSString stringWithFormat:@"Zoom per tap: %.2f×", zoomStep];
}

- (void)movementStepChanged:(UISlider *)slider {
    NSInteger index = (NSInteger)lrintf(slider.value);
    index = MAX(0, MIN((NSInteger)VCamMoveStepCount - 1, index));
    slider.value = (float)index;
    VCamSetSetting(VCamMoveStepKey, @(VCamMoveSteps[index]));
    _movementStepLabel.text = [NSString stringWithFormat:@"Movement per tap: %.1f%%", VCamMoveSteps[index] * 100.0];
}

- (void)zoomStepChanged:(UISlider *)slider {
    NSInteger index = (NSInteger)lrintf(slider.value);
    index = MAX(0, MIN((NSInteger)VCamZoomStepCount - 1, index));
    slider.value = (float)index;
    VCamSetSetting(VCamZoomStepKey, @(VCamZoomSteps[index]));
    _zoomStepLabel.text = [NSString stringWithFormat:@"Zoom per tap: %.2f×", VCamZoomSteps[index]];
}

- (void)adjustOffsetX:(CGFloat)delta {
    CGFloat value = [VCamCopySetting(VCamOffsetXKey) respondsToSelector:@selector(doubleValue)] ? [VCamCopySetting(VCamOffsetXKey) doubleValue] : 0.0;
    VCamSetSetting(VCamOffsetXKey, @(MAX(-1.0, MIN(1.0, value + delta))));
}
- (void)adjustOffsetY:(CGFloat)delta {
    CGFloat value = [VCamCopySetting(VCamOffsetYKey) respondsToSelector:@selector(doubleValue)] ? [VCamCopySetting(VCamOffsetYKey) doubleValue] : 0.0;
    VCamSetSetting(VCamOffsetYKey, @(MAX(-1.0, MIN(1.0, value + delta))));
}
// The camera pixel buffer is oriented 90 degrees relative to the portrait
// preview on this device. Map screen-space D-pad directions onto buffer axes
// so each arrow moves the replacement in the direction shown by the UI.
- (void)moveLeft { [self adjustOffsetY:-VCamCurrentMoveStep()]; }
- (void)moveRight { [self adjustOffsetY:VCamCurrentMoveStep()]; }
- (void)moveUp { [self adjustOffsetX:VCamCurrentMoveStep()]; }
- (void)moveDown { [self adjustOffsetX:-VCamCurrentMoveStep()]; }
- (void)resetPosition { VCamSetSetting(VCamOffsetXKey, @0.0); VCamSetSetting(VCamOffsetYKey, @0.0); }
// Core Image uses a y-up coordinate system: positive angles rotate
// counter-clockwise on screen. Keep the button labels aligned with that
// visual direction (left = CCW, right = CW).
- (void)rotateLeft {
    NSInteger value = [VCamCopySetting(VCamRotationKey) integerValue];
    VCamSetSetting(VCamRotationKey, @((value + 90) % 360));
}
- (void)rotateRight {
    NSInteger value = [VCamCopySetting(VCamRotationKey) integerValue];
    VCamSetSetting(VCamRotationKey, @((value - 90 + 360) % 360));
}
- (void)zoomIn { CGFloat value = [VCamCopySetting(VCamZoomKey) respondsToSelector:@selector(doubleValue)] ? [VCamCopySetting(VCamZoomKey) doubleValue] : 1.0; VCamSetSetting(VCamZoomKey, @(MIN(10.0, value + VCamCurrentZoomStep()))); }
- (void)zoomOut { CGFloat value = [VCamCopySetting(VCamZoomKey) respondsToSelector:@selector(doubleValue)] ? [VCamCopySetting(VCamZoomKey) doubleValue] : 1.0; VCamSetSetting(VCamZoomKey, @(MAX(0.1, value - VCamCurrentZoomStep()))); }
@end

@implementation VCamMenuPresenter
+ (void)toggleMenu {
    if (sMenuVisible || sPendingMenuPresentation) [self hideMenu];
    else [self showMenu];
}

+ (UIWindowScene *)springBoardWindowScene {
    Class controllerClass = objc_getClass("SBUIController");
    if (controllerClass && [controllerClass respondsToSelector:sel_registerName("sharedInstance")]) {
        id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, sel_registerName("sharedInstance"));
        if ([controller respondsToSelector:sel_registerName("windowScene")]) {
            id springBoardScene = ((id (*)(id, SEL))objc_msgSend)(controller, sel_registerName("windowScene"));
            if ([springBoardScene isKindOfClass:UIWindowScene.class]) return springBoardScene;
        }
    }

    UIWindowScene *fallback = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)candidate;
        if (windowScene.activationState == UISceneActivationStateForegroundActive) return windowScene;
        if (!fallback) fallback = windowScene;
    }
    return fallback;
}

+ (BOOL)ensureOverlayWindow {
    if (sOverlayWindow && sOverlayWindow.windowScene) return YES;

    UIWindowScene *scene = [self springBoardWindowScene];
    if (!scene) return NO;

    VCamOverlayWindow *window = [[VCamOverlayWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds;
    window.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    window.windowLevel = UIWindowLevelAlert - 1.0;
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.rootViewController = [[VCamMenuViewController alloc] init];
    sOverlayWindow = window;
    NSLog(@"[VCam] Overlay window attached to SpringBoard scene %@", scene);
    return YES;
}

+ (void)presentOverlayIfReady {
    if (![self ensureOverlayWindow]) return;

    VCamMenuViewController *controller = (VCamMenuViewController *)sOverlayWindow.rootViewController;
    (void)controller.view;
    sOverlayWindow.hidden = NO;

    if (sPendingMenuPresentation) {
        // Only take key-window status while the interactive VCam menu is open.
        // Save SpringBoard's current key window so orientation and app-level
        // event routing return to the original window when the menu closes.
        UIWindowScene *scene = sOverlayWindow.windowScene;
        for (UIWindow *candidate in scene.windows) {
            if (candidate != sOverlayWindow && candidate.isKeyWindow) {
                sPreviousKeyWindow = candidate;
                break;
            }
        }
        [sOverlayWindow makeKeyAndVisible];
        sOverlayWindow.hidden = NO;
    }

    [controller setMenuVisible:sPendingMenuPresentation];
    sPendingMenuPresentation = NO;
}

+ (void)installOverlay {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self ensureOverlayWindow]) {
            if (sOverlayInstallAttempts < 120) {
                sOverlayInstallAttempts++;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 2)),
                               dispatch_get_main_queue(), ^{
                    [self installOverlay];
                });
            } else {
                NSLog(@"[VCam] Could not create overlay: SpringBoard window scene unavailable");
            }
            return;
        }
        sOverlayInstallAttempts = 0;
        [self presentOverlayIfReady];
    });
}

+ (void)showMenu {
    dispatch_async(dispatch_get_main_queue(), ^{
        sPendingMenuPresentation = YES;
        if (![self ensureOverlayWindow]) {
            [self installOverlay];
            return;
        }
        [self presentOverlayIfReady];
    });
}

+ (void)hideMenu {
    dispatch_async(dispatch_get_main_queue(), ^{
        sPendingMenuPresentation = NO;
        if (!sOverlayWindow) return;
        [(VCamMenuViewController *)sOverlayWindow.rootViewController setMenuVisible:NO];
        if (sOverlayWindow.isKeyWindow) {
            [sOverlayWindow resignKeyWindow];
            UIWindow *previousWindow = sPreviousKeyWindow;
            if (previousWindow && !previousWindow.hidden && previousWindow.windowScene == sOverlayWindow.windowScene) {
                [previousWindow makeKeyWindow];
            }
        }
        sPreviousKeyWindow = nil;
    });
}
@end
