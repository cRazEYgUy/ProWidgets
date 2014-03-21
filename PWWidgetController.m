//
//  ProWidgets
//
//  1.0.0
//
//  Created by Alan Yip on 18 Jan 2014
//  Copyright 2014 Alan Yip. All rights reserved.
//

#import "tgmath.h"

#import "PWWidgetController.h"
#import "PWWidgetNavigationController.h"
#import "PWController.h"
#import "PWWidget.h"
#import "PWWidgetJS.h"
#import "PWTheme.h"
#import "PWView.h"
#import "PWBackgroundView.h"
#import "PWMiniView.h"
#import "PWAlertView.h"

#define IDLETIMER_DISABLED_REASON @"PW_IDLETIMER_DISABLED_REASON"

static BOOL _isDragging = NO;
static NSUInteger _lockCount = 0;
static PWWidgetController *_activeController = nil;
static NSMutableSet *_controllers = nil;

static inline ReferencePoint ReferencePointMake(ReferenceLine refLine, CGFloat refValue) {
	ReferencePoint point;
	point.referenceLine = refLine;
	point.referenceValue = refValue;
	return point;
}

static inline ReferenceLocation ReferenceLocationMake(ReferencePoint x, ReferencePoint y) {
	ReferenceLocation location;
	location.x = x;
	location.y = y;
	return location;
}

static inline ReferencePoint ReferencePointFromMagnitude(CGFloat magnitude, CGFloat containerMagnitude, CGFloat center) {
	
	CGFloat containerMid = containerMagnitude / 2.0;
	
	CGFloat leftDelta = center - magnitude / 2.0;
	CGFloat middleDelta = center - containerMid;
	CGFloat rightDelta = -(containerMagnitude - center - magnitude / 2.0);
	
	CGFloat leftDeltaAbs = fabs(leftDelta);
	CGFloat middleDeltaAbs = fabs(middleDelta);
	CGFloat rightDeltaAbs = fabs(rightDelta);
	
	ReferenceLine refLine;
	CGFloat refValue;
	
	if (leftDeltaAbs < middleDeltaAbs && leftDeltaAbs < rightDeltaAbs) {
		refLine = ReferenceLineLeft;
		refValue = leftDelta / containerMid;
	} else if (rightDeltaAbs < leftDeltaAbs && rightDeltaAbs < middleDeltaAbs) {
		refLine = ReferenceLineRight;
		refValue = rightDelta / containerMid;
	} else {
		refLine = ReferenceLineMiddle;
		refValue = middleDelta / containerMid;
	}
	
	return ReferencePointMake(refLine, refValue);
}

static inline ReferenceLocation ReferenceLocationFromSizeAndCenter(CGSize size, CGPoint center, CGSize containerSize) {
	
	ReferencePoint x = ReferencePointFromMagnitude(size.width, containerSize.width, center.x);
	ReferencePoint y = ReferencePointFromMagnitude(size.height, containerSize.height, center.y);
	
	return ReferenceLocationMake(x, y);
}

static inline CGFloat CenterPointFromReferencePoint(ReferencePoint point, CGFloat magnitude, CGFloat containerMagnitude) {
	
	CGFloat containerMid = containerMagnitude / 2.0;
	
	ReferenceLine refLine = point.referenceLine;
	CGFloat refValue = point.referenceValue;
	CGFloat refMagnitude = refValue * containerMid;
	
	if (refLine == ReferenceLineLeft) {
		return refMagnitude + magnitude / 2.0;
	} else if (refLine == ReferenceLineMiddle) {
		return containerMid + refMagnitude;
	} else {
		return containerMagnitude + refMagnitude - magnitude / 2.0;
	}
}

static inline CGPoint CenterFromReferenceLocation(ReferenceLocation location, CGSize size, CGSize containerSize) {
	CGFloat x = CenterPointFromReferencePoint(location.x, size.width, containerSize.width);
	CGFloat y = CenterPointFromReferencePoint(location.y, size.height, containerSize.height);
	return CGPointMake(x, y);
}

@implementation PWWidgetController

+ (void)load {
	_controllers = [NSMutableSet new];
}

+ (BOOL)shouldDisableNotificationCenterPresentation {
	
	if (YES) return NO;
	
	CGFloat thresholdY = 30.0;
	for (PWWidgetController *controller in _controllers) {
		if (controller.isPresented) {
			
			CGFloat originY;
			
			if (controller.isMinimized) {
				originY = controller.miniView.frame.origin.y;
			} else if ([PWController supportsDragging]) {
				originY = controller.containerView.frame.origin.y;
			} else {
				continue;
			}
			
			LOG(@"originY: %f", originY);
			
			// check if the container view falls into the region above threshold Y
			if (originY <= thresholdY) {
				return YES;
			}
		}
	}
	
	return NO;
}

+ (BOOL)isDragging {
	return _isDragging;
}

+ (BOOL)isPresentingWidget {
	if (_controllers == nil || [_controllers count] == 0) return NO;
	for (PWWidgetController *controller in _controllers) {
		if (controller.isPresented) return YES;
	}
	return NO;
}

+ (BOOL)isPresentingMaximizedWidget {
	if (_controllers == nil || [_controllers count] == 0) return NO;
	for (PWWidgetController *controller in _controllers) {
		if (controller.isPresented && !controller.isMinimized) return YES;
	}
	return NO;
}

+ (void)hideCenter {
	[[objc_getClass("SBNotificationCenterController") sharedInstance] dismissAnimated:NO];
	[[objc_getClass("SBControlCenterController") sharedInstance] dismissAnimated:NO];
}

+ (BOOL)isLocked {
	return _lockCount > 0;
}

+ (void)lock {
	
	if (++_lockCount == 1) {
		
		// block orientation change on non-iPad devices
		if (![PWController isIPad]) {
			PWController *controller = [PWController sharedInstance];
			controller.interfaceOrientationIsLocked = NO;
			[[objc_getClass("SBUIController") sharedInstance] _lockOrientationForTransition];
			controller.lockedInterfaceOrientation = [controller currentInterfaceOrientation];
			controller.interfaceOrientationIsLocked = YES;
		}
		
		// lock auto dim timer
		SBBacklightController *backlightController = [objc_getClass("SBBacklightController") sharedInstance];
		[backlightController setIdleTimerDisabled:YES forReason:IDLETIMER_DISABLED_REASON];
	}
}

+ (void)releaseLock {
	
	if (_lockCount == 0 || --_lockCount == 0) {
		
		if (![PWController isIPad]) {
			PWController *controller = [PWController sharedInstance];
			[[objc_getClass("SBUIController") sharedInstance] _releaseTransitionOrientationLock];
			controller.interfaceOrientationIsLocked = NO;
		}
		
		// reset auto dim timer
		[[objc_getClass("SBBacklightController") sharedInstance] resetLockScreenIdleTimer];
		
		// unlock auto dim timer
		SBBacklightController *backlightController = [objc_getClass("SBBacklightController") sharedInstance];
		[backlightController setIdleTimerDisabled:NO forReason:IDLETIMER_DISABLED_REASON];
	}
}

+ (PWWidget *)_createWidgetFromBundle:(NSBundle *)bundle {
	
	PWWidget *widget = nil;
	NSString *widgetName = [[[bundle bundlePath] lastPathComponent] stringByDeletingPathExtension]; // get "*.bundle", then remove ".bundle"
	
	// try to load the bundle
	[bundle load];
	
	// get the principal class
	Class principalClass = [bundle principalClass];
	if (principalClass == nil || ![principalClass isSubclassOfClass:[PWWidget class]]) {
		
		// try to locate the JS file
		NSString *JSPath = [NSString stringWithFormat:@"%@/%@.js", [bundle bundlePath], widgetName];
		if ([[NSFileManager defaultManager] fileExistsAtPath:JSPath]) {
			LOG(@"PWController: Loaded widget JavaScript file at '%@'.", JSPath);
			widget = [[[PWWidgetJS alloc] initWithJSFile:[NSString stringWithFormat:@"%@.js", widgetName] withName:widgetName inBundle:bundle] autorelease];
		} else if (principalClass != nil) {
			LOG(@"PWController: Unable to create widget instance for bundle (%@). Reason: Principal class is not a subclass of PWWidget", [bundle bundleIdentifier]);
			return nil;
		}
	}
	
	if (widget == nil) {
		widget = [[principalClass new] autorelease];
		widget.name = widgetName;
		widget.bundle = bundle;
	}
	
	// set the info of the widget
	NSDictionary *info = [[PWController sharedInstance] infoOfWidgetInBundle:widget.bundle];
	widget.info = info;
	
	LOG(@"PWController: Created widget instance for bundle (%@). Widget named (%@): %@", [bundle bundleIdentifier], widgetName, widget);
	return widget;
}

+ (PWWidget *)_createWidgetNamed:(NSString *)name {
	
	NSBundle *bundle = [PWController widgetBundleNamed:name];
	
	if (bundle != nil) {
		return [self _createWidgetFromBundle:bundle];
	}
	
	return nil;
}

+ (BOOL)presentWidget:(PWWidget *)widget userInfo:(NSDictionary *)userInfo {
	
	NSString *name = widget.name;
	if (name == nil) return NO;
	
	PWWidgetController *existingController = [self controllerForPresentedWidgetNamed:name];
	if (existingController != nil && existingController.isPresented) {
		if (existingController.isMinimized) {
			// maximize the existing widget
			[existingController maximize];
			// notify the widget that user info has changed
			PWWidget *widget = existingController.widget;
			NSDictionary *oldUserInfo = widget.userInfo;
			if ((oldUserInfo == nil && userInfo != nil) || (oldUserInfo != nil && userInfo == nil) || ![oldUserInfo isEqual:userInfo]) {
				widget.userInfo = userInfo;
				[widget userInfoChanged:userInfo];
			}
		}
		return NO;
	}
	
	PWWidgetController *controller = [[[self alloc] initWithWidget:widget] autorelease];
	[_controllers addObject:controller];
	
	// update its user info
	widget.userInfo = userInfo;
	
	__block BOOL success;
	if (![NSThread isMainThread]) {
		dispatch_sync(dispatch_get_main_queue(), ^{
			success = [controller _present];
		});
	} else {
		success = [controller _present];
	}
	
	return success;
}

+ (BOOL)presentWidgetNamed:(NSString *)name userInfo:(NSDictionary *)userInfo {
	PWWidget *widget = [self _createWidgetNamed:name];
	if (widget == nil) return NO;
	return [self presentWidget:widget userInfo:userInfo];
}

+ (BOOL)presentWidgetFromBundle:(NSBundle *)bundle userInfo:(NSDictionary *)userInfo {
	PWWidget *widget = [self _createWidgetFromBundle:bundle];
	if (widget == nil) return NO;
	return [self presentWidget:widget userInfo:userInfo];
}

+ (NSSet *)allControllers {
	return [[_controllers copy] autorelease];
}

+ (instancetype)activeController {
	return _activeController;
}

+ (instancetype)controllerForPresentedWidget:(PWWidget *)widget {
	if (widget == nil) return nil;
	for (PWWidgetController *controller in _controllers) {
		if (controller.widget == widget) return controller;
	}
	return nil;
}

+ (instancetype)controllerForPresentedWidgetNamed:(NSString *)name {
	if (name == nil) return nil;
	for (PWWidgetController *controller in _controllers) {
		if ([controller.widget.name isEqualToString:name]) return controller;
	}
	return nil;
}

+ (instancetype)controllerForPresentedWidgetWithPrincipalClass:(Class)principalClass {
	if (principalClass == NULL) return nil;
	for (PWWidgetController *controller in _controllers) {
		if ([controller.widget isMemberOfClass:principalClass]) return controller;
	}
	return nil;
}

+ (void)adjustLayoutForAllControllers {
	for (PWWidgetController *controller in [self allControllers]) {
		[controller adjustLayout];
	}
}

+ (void)dismissAllControllers:(BOOL)force {
	
	for (PWWidgetController *controller in [self allControllers]) {
		if (force) {
			[controller _forceDismiss];
		} else {
			[controller dismiss];
		}
	}
	
	PWController *controller = [PWController sharedInstance];
	PWWindow *window = controller.window;
	PWView *view = controller.mainView;
	PWBackgroundView *backgroundView = view.backgroundView;
	
	[backgroundView hide];
	[window resignKeyWindow];
}

+ (void)minimizeAllControllers {
	for (PWWidgetController *controller in [self allControllers]) {
		[controller minimize];
	}
}

+ (void)updateActiveController:(PWWidgetController *)controller {
	LOG(@"updateActiveController: %@", controller);
	_activeController = controller;
}

- (instancetype)initWithWidget:(PWWidget *)widget {
	if ((self = [super init])) {
		_isActive = NO;
		_widget = [widget retain];
	}
	return self;
}

- (BOOL)_present {
	
	if (_isPresented) {
		LOG(@"PWWidgetController: Unable to present widget. Reason: Widget is already presented.");
		return NO;
	}
	
	LOG(@"_present");
	
	[self.class hideCenter];
	[self.class lock];
	[self _resetKeyboardHeight];
	
	PWController *controller = [PWController sharedInstance];
	PWWindow *window = controller.window;
	PWView *view = controller.mainView;
	PWBackgroundView *backgroundView = view.backgroundView;
	
	_isAnimating = YES;
	_isPresented = YES;
	_isMinimized = NO;
	
	_widget.widgetController = self;
	
	// configure widget
	// configure title, widget theme, tint/bar text colors, default item view controller plist
	[_widget configure];
	
	// simple check before loading the widget
	if (_widget.requiresProtectedDataAccess && ![PWController protectedDataAvailable]) {
		[self _showProtectedDataUnavailable:NO];
		[self _forceDismiss];
		return NO;
	}
	
	[_widget _setConfigured];
	
	// create container view
	[view addSubview:[self createContainerView]];
	
	// add navigation controller view to it
	UIView *navigationControllerView = _widget.navigationController.view;
	_containerView.navigationControllerView = navigationControllerView;
	[_containerView addSubview:navigationControllerView];
	
	// configure the theme
	PWTheme *theme = _widget.theme;
	[theme _configureAppearance];
	[theme setupTheme];
	
	// load the widget
	// e.g. create or push custom view controllers
	[_widget load];
	
	// notify the widget
	if (_widget.userInfo != nil) {
		[_widget userInfoChanged:_widget.userInfo];
	}
	
	// if the widget wants to dismiss it in load method, then dismiss it manually
	if (_pendingDismissalRequest) {
		[self _forceDismiss];
		return NO;
	}
	
	// configure for default layout & block further changes
	[_widget preparePresentation];
	
	// ensure the widget has already pushed a view controller
	id topViewController = _widget.topViewController;
	
	// if the widget does not have a root view controller, or it requests to dismiss in load method, then dismiss it immediately
	if (topViewController == nil) {
		
		// show an error alert
		if (topViewController == nil) {
			UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:CT(@"UnablePresentWidget") message:[NSString stringWithFormat:CT(@"UnablePresentWidgetMessage"), _widget.displayName] delegate:nil cancelButtonTitle:CT(@"Dismiss") otherButtonTitles:nil];
			[alertView show];
			[alertView release];
		}
		
		// manually dismiss it
		[self _forceDismiss];
		return NO;
	}
	
	[_widget willPresent];
	
	// show window
	[window adjustLayout];
	[window makeKeyAndVisible];
	
	// make myself active
	[self makeActive:YES];
	
	// adjust the center and bounds of container view
	CGRect bounds = [self _containerBounds];
	CGPoint center = [self _containerCenterForBounds:bounds];
	_containerView.bounds = bounds;
	_containerView.center = center;
	
	// update mask and show background view
	[self _updateBackgroundViewMaskForPresentation];
	[backgroundView show];
	
	// begin animation
	CALayer *layer = _containerView.layer;
	
	[CATransaction begin];
	[CATransaction setAnimationDuration:PWAnimationDuration];
	[CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
	[CATransaction setCompletionBlock:^{
		
		_isAnimating = NO;
		[_widget didPresent];
		
		if (_pendingDismissalRequest) {
			[self _forceDismiss];
		}
	}];
	
	CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
	fade.fromValue = @0.0;
	fade.toValue = @1.0;
	
	CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
	scale.fromValue = @1.2;
	scale.toValue = @1.0;
	
	layer.opacity = 1.0;
	layer.transform = CATransform3DMakeScale(1.0, 1.0, 1.0);
	
	[layer addAnimation:fade forKey:@"fade"];
	[layer addAnimation:scale forKey:@"scale"];
	[CATransaction commit];
	
	return YES;
}

- (BOOL)dismiss {
	
	// no widget is currently presented, unable to dismiss
	if (!_isPresented) {
		LOG(@"PWWidgetController: Unable to dismiss widget. Reason: No widget is presented.");
		return NO;
	}
	
	if (_isAnimating) {
		LOG(@"PWWidgetController: Unable to dismiss widget. Widget is being animated.");
		return NO;
	}
	
	if (_isMinimized) {
		LOG(@"PWWidgetController: Unable to dismiss widget. Widget is currently minimized.");
		return NO;
	}
	
	PWController *controller = [PWController sharedInstance];
	PWWindow *window = controller.window;
	PWView *view = controller.mainView;
	PWBackgroundView *backgroundView = view.backgroundView;
	
	_isAnimating = YES;
	[self resignActive:YES];
	
	// notify widget
	[_widget willDismiss];
	
	// show background view
	[window resignKeyWindow];
	[backgroundView hide];
	
	// begin animation
	CALayer *layer = _containerView.layer;
	CGFloat scaleTo = .82;
	
	[CATransaction begin];
	[CATransaction setAnimationDuration:PWAnimationDuration];
	[CATransaction setCompletionBlock:^{
		
		// remove theme
		[_widget.theme removeTheme];
		
		[_widget didDismiss];
		
		// remove container view
		[self removeContainerView];
		
		// this is to force release all the event handlers that may retain widget instance (inside block)
		// then widget will never get released
		[_widget _dealloc];
		[_widget release], _widget = nil;
		
		_isPresented = NO;
		_isMinimized = NO;
		_isAnimating = NO;
		
		[self.class releaseLock];
		
		// release the widget controller (self)
		[_controllers removeObject:self];
	}];
	
	CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
	fade.fromValue = @1.0;
	fade.toValue = @0.0;
	
	CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
	scale.fromValue = @1.0;
	scale.toValue = @(scaleTo);
	
	layer.opacity = 0.0;
	layer.transform = CATransform3DMakeScale(scaleTo, scaleTo, 1.0);
	
	[layer addAnimation:fade forKey:@"fade"];
	[layer addAnimation:scale forKey:@"scale"];
	[CATransaction commit];
	
	return YES;
}

- (BOOL)dismissWhenMinimized {
	
	if (!_isPresented) {
		LOG(@"PWWidgetController: Unable to dismiss widget. Reason: No widget is presented.");
		return NO;
	}
	
	if (_isAnimating) {
		LOG(@"PWWidgetController: Unable to dismiss widget. Widget is being animated.");
		return NO;
	}
	
	if (!_isMinimized) {
		LOG(@"PWWidgetController: Unable to dismiss widget. Widget is not minimized.");
		return NO;
	}
	
	// update flag
	_isAnimating = YES;
	_pendingDismissalRequest = NO;
	
	// force hide keyboard
	[_containerView endEditing:YES];
	
	// notify widget
	[_widget willDismiss];
	
	// remove theme
	[_widget.theme removeTheme];
	
	// remove container view
	[self removeContainerView];
	
	// perform animation
	CALayer *layer = _miniView.layer;
	CGFloat scaleTo = _miniView.scale * 0.8;
	
	[CATransaction begin];
	[CATransaction setAnimationDuration:PWAnimationDuration];
	[CATransaction setCompletionBlock:^{
		
		[_widget didDismiss];
		
		// remove mini view
		[self removeMiniView];
		
		// this is to force release all the event handlers that may retain widget instance (inside block)
		// then widget will never get released
		[_widget _dealloc];
		[_widget release], _widget = nil;
		
		_isPresented = NO;
		_isMinimized = NO;
		_isAnimating = NO;
		
		// release the widget controller (self)
		[_controllers removeObject:self];
	}];
	
	CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
	fade.fromValue = @1.0;
	fade.toValue = @0.0;
	
	CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
	scale.fromValue = @(_miniView.scale);
	scale.toValue = @(scaleTo);
	
	layer.opacity = 0.0;
	layer.transform = CATransform3DMakeScale(scaleTo, scaleTo, 1.0);
	
	[layer addAnimation:fade forKey:@"fade"];
	[layer addAnimation:scale forKey:@"scale"];
	[CATransaction commit];
	
	return YES;
}

- (void)_forceDismiss {
	
	BOOL shouldReleaseLock = _isPresented && !_isMinimized;
	PWController *controller = [PWController sharedInstance];
	PWWindow *window = controller.window;
	PWView *view = controller.mainView;
	PWBackgroundView *backgroundView = view.backgroundView;
	
	if (_isPresented && _isActive && !_isMinimized) {
		[backgroundView hide];
		[window resignKeyWindow];
		[self resignActive:YES];
	}
	
	// remove theme
	[_widget.theme removeTheme];
	
	// remove container view
	[self removeContainerView];
	
	// this is to force release all the event handlers that may retain widget instance (inside block)
	// then widget will never get released
	[_widget _dealloc];
	[_widget release], _widget = nil;
	
	_isPresented = NO;
	_isMinimized = NO;
	_isAnimating = NO;
	
	if (shouldReleaseLock) {
		[self.class releaseLock];
	}
	
	[_controllers removeObject:self];
}

- (BOOL)minimize {
	
	if (!_isPresented) {
		LOG(@"PWWidgetController: Unable to minimize widget. Reason: No widget is presented.");
		return NO;
	}
	
	if (_isAnimating) {
		LOG(@"PWWidgetController: Unable to minimize widget. Widget is being animated.");
		return NO;
	}
	
	if (_isMinimized) {
		LOG(@"PWWidgetController: Unable to minimize widget. Widget is already minimized.");
		return NO;
	}
	
	PWController *controller = [PWController sharedInstance];
	PWWindow *window = controller.window;
	PWView *view = controller.mainView;
	PWBackgroundView *backgroundView = view.backgroundView;
	
	_isMinimized = YES;
	_isAnimating = YES;
	
	// resign active state, and hide keyboard
	[self resignActive:YES];
	
	[_widget.theme enterSnapshotMode];
	[_containerView.layer displayIfNeeded];
	
	// this little delay is to ensure that the new changes are applied in enterSnapshotMode
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.05 * NSEC_PER_SEC), dispatch_get_main_queue(), ^(void){
	
		// generate image for mini view
		UIGraphicsBeginImageContextWithOptions(_containerView.bounds.size, NO, 0);
		[_containerView drawViewHierarchyInRect:_containerView.bounds afterScreenUpdates:NO];
		[_widget.theme exitSnapshotMode];
		
		UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
		UIGraphicsEndImageContext();
		
		// ask window to create a mini view with the snapshot image
		PWMiniView *miniView = [self createMiniView:snapshot];
		miniView.scale = [PWController sharedInstance]._miniViewScale; // retrieve the scale from preference
		
		// hide container view
		_containerView.hidden = YES;
		
		// hide background view
		[window resignKeyWindow];
		[backgroundView hide];
		
		// animate the layer
		CALayer *layer = miniView.layer;
		CGFloat fadeTo = .9;
		CGFloat viewScale = miniView.scale;
		CGFloat initialExtraScale = .95;
		CGPoint initialPosition = [self _miniViewCenter];
		
		[CATransaction begin];
		[CATransaction setAnimationDuration:PWMaxMinimizationDuration];
		[CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
		[CATransaction setCompletionBlock:^{
			
			[_miniView finishAnimation];
			
			// perform second animation
			[CATransaction begin];
			[CATransaction setAnimationDuration:.15];
			[CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
			[CATransaction setCompletionBlock:^{
				_isAnimating = NO;
				[self.class releaseLock];
			}];
			
			CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
			scale.fromValue = @(viewScale * initialExtraScale);
			scale.toValue = @(viewScale);
			
			layer.transform = CATransform3DMakeScale(viewScale, viewScale, 1.0);
			
			[layer addAnimation:scale forKey:@"scale"];
			[CATransaction commit];
		}];
		
		CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
		fade.fromValue = @1.0;
		fade.toValue = @(fadeTo);
		
		CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
		scale.fromValue = @1.0;
		scale.toValue = @(viewScale * initialExtraScale);
		
		CABasicAnimation *position = [CABasicAnimation animationWithKeyPath:@"position"];
		position.fromValue = [NSValue valueWithCGPoint:layer.position];
		position.toValue = [NSValue valueWithCGPoint:initialPosition];
		
		layer.opacity = fadeTo;
		layer.transform = CATransform3DMakeScale(viewScale * initialExtraScale, viewScale * initialExtraScale, 1.0);
		layer.position = initialPosition;
		
		[layer addAnimation:fade forKey:@"fade"];
		[layer addAnimation:scale forKey:@"scale"];
		[layer addAnimation:position forKey:@"position"];
		[CATransaction commit];
	});
		
	return YES;
}

- (BOOL)maximize {
	
	if (!_isPresented) {
		LOG(@"PWWidgetController: Unable to maximize widget. Reason: No widget is presented.");
		return NO;
	}
	
	if (_isAnimating) {
		LOG(@"PWWidgetController: Unable to maximize widget. Widget is being animated.");
		return NO;
	}
	
	if (!_isMinimized) {
		LOG(@"PWWidgetController: Unable to maximize widget. Widget is already maximized.");
		return NO;
	}
	
	PWController *controller = [PWController sharedInstance];
	PWWindow *window = controller.window;
	PWView *view = controller.mainView;
	PWBackgroundView *backgroundView = view.backgroundView;
	
	[self.class hideCenter];
	[self.class lock];
	[self _resetKeyboardHeight];
	
	//[window adjustLayout];
	[window makeKeyAndVisible];
	
	[self _resizeAnimated:NO];
	
	_isAnimating = YES;
	
	CGFloat miniViewScale = _miniView.scale;
	CGPoint miniViewCenter = _miniView.center;
	
	// show main view and container view
	_containerView.hidden = NO;
	
	// make myself active
	[self makeActive:NO];
	
	// update mask and show background view
	[self _updateBackgroundViewMaskForMaximization];
	[backgroundView show];
	
	// remove mini view
	[self removeMiniView];
	
	// animate the layer
	CALayer *layer = _containerView.layer;
	CGFloat fadeFrom = .6;
	
	[CATransaction begin];
	[CATransaction setAnimationDuration:PWMaxMinimizationDuration];
	[CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
	[CATransaction setCompletionBlock:^{
		
		// force main view to perform layoutSubviews
		[_containerView setNeedsLayout];
		
		// ask the top view controller to configure first responder (regain keyboard)
		[_widget.topViewController configureFirstResponder];
		
		// update flags
		_isAnimating = NO;
		_isMinimized = NO;
	}];
	
	CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
	fade.fromValue = @(fadeFrom);
	fade.toValue = @(1.0);
	
	CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
	scale.fromValue = @(miniViewScale);
	scale.toValue = @(1.0);
	
	CABasicAnimation *position = [CABasicAnimation animationWithKeyPath:@"position"];
	position.fromValue = [NSValue valueWithCGPoint:miniViewCenter];
	position.toValue = [NSValue valueWithCGPoint:layer.position];
	
	layer.transform = CATransform3DMakeScale(1.0, 1.0, 1.0);
	
	[layer addAnimation:fade forKey:@"fade"];
	[layer addAnimation:scale forKey:@"scale"];
	[layer addAnimation:position forKey:@"position"];
	[CATransaction commit];
	
	return YES;
}

- (void)makeActive:(BOOL)configureFirstResponder {
	
	if (self.isActive) return;
	
	LOG(@"makeActive: %@", _widget);
	
	// make the active controller inactive
	PWWidgetController *activeController = [PWWidgetController activeController];
	[activeController resignActive:NO];
	
	// minimize all other widgets
	if (![PWController supportsMultipleWidgetsOnScreen]) {
		for (PWWidgetController *controller in [PWWidgetController allControllers]) {
			if (controller != self && !controller.isMinimized) {
				[controller minimize];
			}
		}
	}
	
	// make myself active
	_isActive = YES;
	[self.class updateActiveController:self];
	[_containerView hideOverlay];
	[_containerView.superview bringSubviewToFront:_containerView];
	if (configureFirstResponder) {
		[_widget.topViewController configureFirstResponder];
	}
}

- (void)resignActive:(BOOL)makeActive {
	
	if (!self.isActive) return;
	
	LOG(@"resignActive: %@", _widget);
	
	// make myself inactive
	_isActive = NO;
	[self.class updateActiveController:nil];
	[_containerView endEditing:YES];
	[_containerView showOverlay];
	
	// find next controller, then make it active
	if (makeActive) {
		for (PWWidgetController *controller in [PWWidgetController allControllers]) {
			if (controller != self && controller.isPresented && !controller.isMinimized) {
				[controller makeActive:YES];
				break;
			}
		}
	}
}

- (PWContainerView *)createContainerView {
	
	if (_containerView != nil) {
		RELEASE_VIEW(_containerView);
	}
	
	_containerView = [[PWContainerView alloc] initWithWidgetController:self];
	return _containerView;
}

- (void)removeContainerView {
	RELEASE_VIEW(_containerView)
}

- (PWMiniView *)createMiniView:(UIImage *)snapshot {
	
	if (_miniView != nil) {
		RELEASE_VIEW(_miniView);
	}
	
	PWController *controller = [PWController sharedInstance];
	PWView *view = controller.mainView;
	
	PWContainerView *containerView = _containerView;
	CGRect rect = containerView.frame;
	
	_miniView = [[PWMiniView alloc] initWithSnapshot:snapshot];
	_miniView.clipsToBounds = YES;
	_miniView.frame = rect;
	
	// configure gesture recognizers
	UIPanGestureRecognizer *panRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleMiniViewPan:)];
	[panRecognizer setMinimumNumberOfTouches:1];
	[panRecognizer setMaximumNumberOfTouches:1];
	[_miniView addGestureRecognizer:panRecognizer];
	[panRecognizer release];
	
	UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleMiniViewSingleTap:)];
	[_miniView addGestureRecognizer:singleTap];
	[singleTap release];
	
	UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleMiniViewDoubleTap:)];
	doubleTap.numberOfTapsRequired = 2;
	[_miniView addGestureRecognizer:doubleTap];
	[doubleTap release];
	
	[singleTap requireGestureRecognizerToFail:doubleTap];
	
	[view addSubview:_miniView];
	
	return _miniView;
}

- (void)removeMiniView {
	RELEASE_VIEW(_miniView)
}

- (void)adjustLayout {
	
	if (!_isPresented) return;
	
	// force navigation controller to update layout
	// the height of navigation bar is constant on iPad, so it is unnecessary to update layout again
	if (![PWController isIPad]) {
		[UIView performWithoutAnimation:^{
			UINavigationController *navigationController = _widget.navigationController;
			[navigationController _updateLayoutForStatusBarAndInterfaceOrientation];
		}];
	}
	
	// update theme layout
	[UIView performWithoutAnimation:^{
		PWTheme *theme = _widget.theme;
		[theme adjustLayout];
	}];
	
	if (_isMinimized) {
		// re-position mini view
		_miniView.center = [self _miniViewCenter];
	} else {
		// resize widget
		[self _resizeAnimated:NO];
	}
}

- (CGPoint)_containerCenterForBounds:(CGRect)bounds {
	
	PWController *controller = [PWController sharedInstance];
	PWView *view = controller.mainView;
	id<PWContentViewControllerDelegate> viewController = _widget.topViewController;
	
	if (_widget == nil || viewController == nil || ![viewController.class conformsToProtocol:@protocol(PWContentViewControllerDelegate)])
		return CGPointZero;
	
	PWWidgetOrientation orientation = [PWController currentOrientation];
	BOOL requiresKeyboard = viewController.requiresKeyboard;
	
	// set default keyboard height
	if (_keyboardHeight == 0.0) {
		_keyboardHeight = [[PWController sharedInstance] defaultHeightOfKeyboardInOrientation:orientation];
	}
	
	// view dimensions
	CGSize viewSize = view.bounds.size;
	CGSize containerViewSize = bounds.size;
	CGFloat keyboardHeight = requiresKeyboard ? _keyboardHeight : 0.0;
	
	CGFloat margin = 2.0;
	CGPoint defaultCenter = CGPointMake(viewSize.width / 2, viewSize.height / 2 - keyboardHeight / 2);
	
	if (![PWController supportsDragging]) {
		
		// always return the center point on iPhone
		return defaultCenter;
		
	} else {
		
		CGPoint center;
		
		if (_hasContainerViewLocation) {
			center = CenterFromReferenceLocation(_containerViewLocation, containerViewSize, viewSize);
			center.x += margin;
			center.y += margin;
		} else {
			center = defaultCenter;
		}
		
		CGFloat minX = containerViewSize.width / 2;
		CGFloat maxX = viewSize.width - minX;
		CGFloat minY = containerViewSize.height / 2;
		CGFloat maxY = viewSize.height - minY;
		
		minX += margin;
		maxX -= margin;
		minY += margin;
		maxY -= margin;
		
		// limit the moving bounds
		center.x = MAX(minX, MIN(center.x, maxX));
		center.y = MAX(minY, MIN(center.y, maxY));
		
		return center;
	}
}

- (CGRect)_containerBounds {
	
	PWController *controller = [PWController sharedInstance];
	PWView *view = controller.mainView;
	id<PWContentViewControllerDelegate> viewController = _widget.topViewController;
	
	if (_widget == nil || viewController == nil || ![viewController.class conformsToProtocol:@protocol(PWContentViewControllerDelegate)])
		return CGRectZero;
	
	PWWidgetOrientation orientation = [PWController currentOrientation];
	//BOOL requiresKeyboard = viewController.requiresKeyboard;
	
	// view dimensions
	CGSize size = view.bounds.size;
	CGFloat width = size.width;
	CGFloat height = size.height;
	
	// calculate container width
	CGFloat contentWidth = [viewController contentWidthForOrientation:orientation];
	CGFloat containerWidth = MIN(MAX(0.0, contentWidth), width);
	
	// calculate container height
	CGFloat contentHeight = [viewController contentHeightForOrientation:orientation];
	CGFloat navigationBarHeight = [controller heightOfNavigationBarInOrientation:orientation];
	CGFloat containerHeight = MIN(MAX(0.0, contentHeight + navigationBarHeight), height);
	
	// container's rect
	return CGRectMake(0, 0, containerWidth, containerHeight);
}

- (CGPoint)_miniViewCenter {
	
	CGFloat margin = 2.0;
	CGFloat statusBarHeight = 20.0;
	
	PWView *view = [PWController sharedInstance].mainView;
	CGSize viewSize = view.bounds.size;
	
	CGSize miniViewSize = _miniView.bounds.size;
	miniViewSize.width *= _miniView.scale;
	miniViewSize.height *= _miniView.scale;
	
	CGFloat minX = miniViewSize.width / 2;
	CGFloat maxX = viewSize.width - minX;
	CGFloat minY = miniViewSize.height / 2;
	CGFloat maxY = viewSize.height - minY;
	
	minX += margin;
	maxX -= margin;
	minY += margin;
	maxY -= margin;
	
	CGPoint center;
	
	if (_hasMiniViewLocation) {
		center = CenterFromReferenceLocation(_miniViewLocation, miniViewSize, viewSize);
		center.x += margin;
		center.y += margin;
	} else {
		center = CGPointMake(maxX, statusBarHeight + miniViewSize.height / 2.0);
	}
	
	// limit the moving bounds
	center.x = MAX(minX, MIN(center.x, maxX));
	center.y = MAX(minY, MIN(center.y, maxY));
	
	return center;
}

- (void)_updateBackgroundViewMaskForPresentation {
	
	if (![PWController shouldMaskBackgroundView]) return;
	
	LOG(@"_updateBackgroundViewMaskForPresentation");
	
	PWView *mainView = [PWController sharedInstance].mainView;
	PWBackgroundView *backgroundView = mainView.backgroundView;
	
	CGFloat cornerRadius = [_widget.theme cornerRadius];
	
	[backgroundView setMaskRect:_containerView.frame fromRect:CGRectNull cornerRadius:cornerRadius animationType:PWBackgroundViewAnimationTypePresentation];
}

- (void)_updateBackgroundViewMaskForMaximization {
	
	if (![PWController shouldMaskBackgroundView]) return;
	
	LOG(@"_updateBackgroundViewMaskForMaximization");
	
	PWView *mainView = [PWController sharedInstance].mainView;
	PWBackgroundView *backgroundView = mainView.backgroundView;
	
	CGRect bounds = _containerView.bounds;
	CGPoint center = _miniView.center;
	
	bounds.size.width *= _miniView.scale;
	bounds.size.height *= _miniView.scale;
	
	CGRect fromRect = bounds;
	fromRect.origin.x = center.x - fromRect.size.width / 2;
	fromRect.origin.y = center.y - fromRect.size.height / 2;
	
	CGFloat cornerRadius = [_widget.theme cornerRadius];
	
	[backgroundView setMaskRect:_containerView.frame fromRect:fromRect cornerRadius:cornerRadius animationType:PWBackgroundViewAnimationTypeMaximization];
}

- (void)_resizeAnimated:(BOOL)animated {
	
	LOG(@"_resizeAnimated: %d", (int)animated);
	
	BOOL shouldUpdateBackgroundViewMask = _isActive && !_isMinimized && [PWController shouldMaskBackgroundView];
	
	PWView *mainView = [PWController sharedInstance].mainView;
	PWBackgroundView *backgroundView = mainView.backgroundView;
	
	CGRect currentBounds = _containerView.bounds;
	CGPoint currentCenter = _containerView.center;
	
	CGRect bounds = [self _containerBounds];
	CGPoint center = [self _containerCenterForBounds:bounds];
	
	CGFloat cornerRadius = [_widget.theme cornerRadius];
	
	if (CGPointEqualToPoint(currentCenter, center) && CGRectEqualToRect(currentBounds, bounds)) {
		LOG(@"_resizeAnimated: center and rect remain unchanged");
		if (shouldUpdateBackgroundViewMask) {
			[backgroundView setMaskRect:_containerView.frame fromRect:CGRectNull cornerRadius:cornerRadius animationType:PWBackgroundViewAnimationTypeNone];
		}
		return;
	}
	
	if (_isAnimating || !animated) {
		
		_containerView.center = center;
		_containerView.bounds = bounds;
		[_containerView setNeedsLayout];
		[_containerView layoutIfNeeded];
		
		if (shouldUpdateBackgroundViewMask) {
			[backgroundView setMaskRect:_containerView.frame fromRect:CGRectNull cornerRadius:cornerRadius animationType:PWBackgroundViewAnimationTypeNone];
		}
		
	} else {
		
		[UIView animateWithDuration:PWAnimationDuration delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionTransitionNone animations:^{
			
			// must not call layoutIfNeeded here, otherwise the navigation controller view
			// will animate as well (as a result the navigation bar and cells animate in a weird way)
			_containerView.center = center;
			_containerView.bounds = bounds;
			[_containerView setNeedsLayout];
			
			// force the background view to animate
			UIView *containerBackgroundView = _containerView.containerBackgroundView;
			containerBackgroundView.frame = bounds;
			[containerBackgroundView setNeedsLayout];
			[containerBackgroundView layoutIfNeeded];
			
			// force the theme to adjust layout
			PWTheme *theme = _widget.theme;
			[theme adjustLayout];
			
		} completion:nil];
		
		CGRect rect = bounds;
		rect.origin.x = center.x - bounds.size.width / 2;
		rect.origin.y = center.y - bounds.size.height / 2;
		
		if (shouldUpdateBackgroundViewMask) {
			[backgroundView setMaskRect:rect fromRect:CGRectNull cornerRadius:cornerRadius animationType:PWBackgroundViewAnimationTypeResize];
		}
	}
}

- (void)_resetKeyboardHeight {
	_keyboardHeight = [[PWController sharedInstance] defaultHeightOfKeyboardInOrientation:[PWController currentOrientation]];
}

- (void)_keyboardWillShowHandler:(CGFloat)height {
	
	// ignore the change in keyboard height on iPad
	if (![PWController isIPad] && height != _keyboardHeight) {
		
		_keyboardHeight = height;
		
		if (!_isAnimating && _isActive) {
			[self _resizeAnimated:YES];
		}
	}
}

- (void)_keyboardWillHideHandler {
	
	PWWidgetOrientation orientation = [PWController currentOrientation];
	CGFloat keyboardHeight = [[PWController sharedInstance] defaultHeightOfKeyboardInOrientation:orientation];
	
	// ignore the change in keyboard height on iPad
	if (![PWController isIPad] && _keyboardHeight != keyboardHeight) {
		
		_keyboardHeight = keyboardHeight;
		
		if (!_isAnimating && _isActive) {
			[self _resizeAnimated:YES];
		}
	}
}

- (void)_protectedDataWillBecomeUnavailableHandler {
	[self _showProtectedDataUnavailable:YES];
}

- (void)_showProtectedDataUnavailable:(BOOL)presented {
	
	if (_widget == nil) return;
	
	if (presented) {
		
		// not being dismissed or presented
		if (!_isAnimating) {
		
			BOOL requiresProtectedDataAccess = _widget.requiresProtectedDataAccess;
			if (requiresProtectedDataAccess) {
				
				// show the message
				PWAlertView *alertView = [[PWAlertView alloc] initWithTitle:CT(@"ProtectedDataUnavailable") message:[NSString stringWithFormat:CT(@"ProtectedDataUnavailableDismissedMessage"), _widget.displayName] buttonTitle:nil cancelButtonTitle:CT(@"Dismiss") defaultValue:nil style:UIAlertViewStyleDefault completion:nil];
				[alertView show];
				[alertView release];
			}
		}
		
	} else {
		
		// show the message
		PWAlertView *alertView = [[PWAlertView alloc] initWithTitle:CT(@"ProtectedDataUnavailable") message:[NSString stringWithFormat:CT(@"ProtectedDataUnavailableUnablePresentMessage"), _widget.displayName] buttonTitle:nil cancelButtonTitle:CT(@"Dismiss") defaultValue:nil style:UIAlertViewStyleDefault completion:nil];
		[alertView show];
		[alertView release];
	}
}

- (void)handleNavigationBarPan:(UIPanGestureRecognizer *)sender {
	
	LOG(@"handleNavigationBarPan: %@", sender);
	
	UIGestureRecognizerState state = [sender state];
	
	PWView *view = [PWController sharedInstance].mainView;
	PWBackgroundView *backgroundView = view.backgroundView;
	
	CGSize viewSize = view.bounds.size;
	CGSize containerViewSize = _containerView.bounds.size;
	
	CGFloat margin = 2.0;
	CGFloat minX = containerViewSize.width / 2;
	CGFloat maxX = viewSize.width - minX;
	CGFloat minY = containerViewSize.height / 2;
	CGFloat maxY = viewSize.height - minY;
	
	minX += margin;
	maxX -= margin;
	minY += margin;
	maxY -= margin;
	
	// limit the moving bounds
	CGPoint center = [sender translationInView:view];
	center.x = MAX(minX, MIN(_containerView.center.x + center.x, maxX));
	center.y = MAX(minY, MIN(_containerView.center.y + center.y, maxY));
	
	if (![PWController isIPad]) {
		center.x = _containerView.center.x;
	}
	
	[sender setTranslation:CGPointZero inView:view];
	
	if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateEnded) {
		[self makeActive:YES];
	}
	
	// hide background view when start dragging
	if (state == UIGestureRecognizerStateBegan) {
		if ([PWController shouldShowBackgroundView]) {
			[backgroundView hide];
		}
	}
	
	if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled || state == UIGestureRecognizerStateFailed) {
		
		_isDragging = NO;
		
		// show background view when stop dragging
		// and adjust the mask rect
		if ([PWController shouldShowBackgroundView]) {
			
			if ([PWController shouldMaskBackgroundView]) {
				CGRect finalRect = _containerView.bounds;
				finalRect.origin.x = center.x - containerViewSize.width / 2.0;
				finalRect.origin.y = center.y - containerViewSize.height / 2.0;
				
				CGFloat cornerRadius = [_widget.theme cornerRadius];
				
				[backgroundView setMaskRect:finalRect fromRect:CGRectNull cornerRadius:cornerRadius animationType:PWBackgroundViewAnimationTypeNone];
			}
			
			[backgroundView show];
		}
		
		[UIView animateWithDuration:PWTransitionAnimationDuration animations:^{
			_containerView.center = center;
			_containerView.alpha = 1.0;
		}];
		
	} else {
		
		_isDragging = YES;
		
		[UIView animateWithDuration:PWTransitionAnimationDuration animations:^{
			_containerView.center = center;
			_containerView.alpha = .8;
		}];
	}
	
	CGPoint centerMinusMargin = CGPointMake(center.x - margin, center.y - margin);
	ReferenceLocation location = ReferenceLocationFromSizeAndCenter(containerViewSize, centerMinusMargin, viewSize);
	
	_hasContainerViewLocation = YES;
	_containerViewLocation = location;
}

- (void)handleMiniViewPan:(UIPanGestureRecognizer *)sender {
	
	LOG(@"handleMiniViewPan: %@", sender);
	
	UIGestureRecognizerState state = [sender state];
	
	PWView *view = [PWController sharedInstance].mainView;
	CGSize viewSize = view.bounds.size;
	CGSize miniViewSize = _miniView.bounds.size;
	
	miniViewSize.width *= _miniView.scale;
	miniViewSize.height *= _miniView.scale;
	
	CGFloat margin = 2.0;
	CGFloat midX = viewSize.width / 2;
	CGFloat minX = miniViewSize.width / 2;
	CGFloat maxX = viewSize.width - minX;
	CGFloat minY = miniViewSize.height / 2;
	CGFloat maxY = viewSize.height - minY;
	
	minX += margin;
	maxX -= margin;
	minY += margin;
	maxY -= margin;
	
	// limit the moving bounds
	CGPoint center = [sender translationInView:view];
	center.x = MAX(minX, MIN(_miniView.center.x + center.x, maxX));
	center.y = MAX(minY, MIN(_miniView.center.y + center.y, maxY));
	
	[sender setTranslation:CGPointZero inView:view];
	
	if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled || state == UIGestureRecognizerStateFailed) {
		
		_isDragging = NO;
		
		CGFloat velocity = 1.0;
		
		// snap to either left or right side
		if (![PWController isIPad]) {
			
			if (center.x <= midX) {
				center.x = minX;
			} else {
				center.x = maxX;
			}
			
			velocity = 1.0 - fabs(_miniView.center.x - midX) / midX;
		}
		
		[UIView animateWithDuration:PWTransitionAnimationDuration * velocity animations:^{
			_miniView.center = center;
		}];
		
	} else {
		
		_isDragging = YES;
		
		if (state == UIGestureRecognizerStateBegan) {
			[_miniView.superview bringSubviewToFront:_miniView];
		}
		
		[UIView animateWithDuration:PWTransitionAnimationDuration animations:^{
			_miniView.center = center;
		}];
	}
	
	CGPoint centerMinusMargin = CGPointMake(center.x - margin, center.y - margin);
	ReferenceLocation location = ReferenceLocationFromSizeAndCenter(miniViewSize, centerMinusMargin, viewSize);
	
	_hasMiniViewLocation = YES;
	_miniViewLocation = location;
}

- (void)handleMiniViewSingleTap:(UITapGestureRecognizer *)sender {
	LOG(@"handleMiniViewSingleTap: %@", sender);
	[self maximize];
}

- (void)handleMiniViewDoubleTap:(UITapGestureRecognizer *)sender {
	LOG(@"handleMiniViewDoubleTap: %@", sender);
	[self dismissWhenMinimized];
}

- (void)dealloc {
	DEALLOCLOG;
	RELEASE(_widget)
	RELEASE_VIEW(_backgroundView)
	RELEASE_VIEW(_containerView)
	RELEASE_VIEW(_miniView)
	[super dealloc];
}

@end