//
//  HyperspaceView.m
//  Hyperspace
//
//  Created by Nick Zitzmann on 2/19/06.
//  Copyright (c) 2006, Nick Zitzmann. All rights reserved.
//

/*
 * This file is part of Hyperspace.
 *
 * Hyperspace is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as 
 * published by the Free Software Foundation.
 *
 * Hyperspace is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#import "HyperspaceView.h"
#import "Hyperspace.h"
#import "flare.h"
#import "Hyperspace/HSLog.h"
#import <atomic>
#import <unistd.h>

// Diagnostic state (see HSLog.h). Kept out of the public header.
static std::atomic<uint32_t> sNextInstanceID{1};

@interface HyperspaceView ()
{
	uint32_t lInstanceID;
	os_signpost_id_t lSignpostID;
	os_signpost_id_t lFrameSignpostID;
	CFAbsoluteTime lLastStatsTime;
	HSFrameStats lLastStats;
	uint64_t lAnimateCalls, lLastAnimateCalls;
	uint64_t lDrawCalls, lLastDrawCalls;
	BOOL lLoggedFirstPresent;
	BOOL lLoggedFirstDrawRect;
	// Whether this instance renders at all (Metal 4 available, and not excluded by
	// "main screen only"). Separate from lView, which is released while detached.
	BOOL lCanRender;
}
- (void)logStatsIfDue;
- (BOOL)setUpRenderer;
- (void)releaseRenderer;
@end

@interface HyperspaceView (Private)
- (void)readDefaults:(ScreenSaverDefaults *)inDefaults;
- (void)setDialogValue;
@end

@implementation HyperspaceView

- (id)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
	NSString *identifier = [[NSBundle bundleForClass:[self class]] bundleIdentifier];
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:identifier];
	
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self)
	{
		lInstanceID = sNextInstanceID++;
		lSignpostID = os_signpost_id_generate(HSSignpostLog());
		lFrameSignpostID = os_signpost_id_generate(HSFrameSignpostLog());
		os_log(HSLog(), "#%u init pid=%d frame=%{public}@ isPreview=%d", lInstanceID, getpid(),
			   NSStringFromRect(frame), isPreview);
		os_signpost_event_emit(HSSignpostLog(), lSignpostID, "init", "#%u %{public}@", lInstanceID, NSStringFromRect(frame));

		// MTKView (lView, added as a subview below) is inherently layer-backed (it's built on
		// CAMetalLayer), but this view itself was never explicitly made layer-backed. Mixing a
		// non-layer-backed host view with a layer-backed Metal subview is a known source of
		// "renders fine, never actually composites" bugs specifically when the content has to
		// cross a process boundary — exactly the case here, since the real screen saver host
		// and the System Settings preview both load this view inside a sandboxed app extension
		// and composite its content remotely rather than drawing it directly in-process.
		self.wantsLayer = YES;

		lSettings.doingPreview = isPreview;
		if (isPreview)
			lMainScreen = YES;
		else
			lMainScreen = (frame.origin.x == 0 && frame.origin.y == 0) ? YES : NO;
		lIsConfiguring = NO;
		lMainScreenOnly = [defaults boolForKey:@"MainScreenOnly"];
		if (lMainScreen || !lMainScreenOnly)
		{
			if ([self setUpRenderer])
			{
				lCanRender = YES;
				lSettings.frameTime = 0;

				setDefaults(&lSettings);
				if ([defaults objectForKey:@"Speed"])
				{
					[self readDefaults:defaults];
				}

				self.animationTimeInterval = 1.0/60.0;
				lSettings.first = 1;
			}
		}
		else
			os_log(HSLog(), "#%u no renderer: lMainScreen=%d lMainScreenOnly=%d", lInstanceID, lMainScreen, lMainScreenOnly);
    }
    return self;
}


// Creates the MTKView + renderer at this view's current size. Separate from init because a
// view removed from its window releases them (see viewDidMoveToWindow) and rebuilds them if
// it's ever re-added.
- (BOOL)setUpRenderer
{
	// Use the size this view was actually given, not NSZeroRect: the host may never send a
	// later setFrameSize:, and a 0x0 MTKView never gets a drawable.
	NSSize size = self.bounds.size;
	MTKView *candidateView = [[MTKView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
	candidateView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	HSRenderer *renderer = new HSRenderer;

	renderer->setLogTag(lInstanceID);
	BOOL attached = renderer->attachToView(candidateView);
	os_log(HSLog(), "#%u attachToView=%d mtkView drawableSize=%{public}@", lInstanceID, attached,
		   NSStringFromSize(NSSizeFromCGSize(candidateView.drawableSize)));
	if (!attached)
	{
		delete renderer;
		return NO;
	}

	lView = candidateView;
	lRenderer = renderer;
	lView.delegate = self;
	self.autoresizesSubviews = YES;
	[self addSubview:lView];
	lSettings.renderer = lRenderer;
	// A new renderer has no projection yet; force syncViewportWithDrawable to reshape.
	lSettings.xsize = lSettings.ysize = 0;
	return YES;
}


// Frees the scene (if built), the MTKView with its full-screen drawables, and the renderer.
- (void)releaseRenderer
{
	if (lSettings.readyToDraw)
		cleanUp(&lSettings);	// needs the renderer to destroy its textures, so first
	lView.delegate = nil;
	[lView removeFromSuperview];
	lView = nil;
	delete lRenderer;	// waits for any in-flight GPU work before freeing
	lRenderer = NULL;
	lSettings.renderer = NULL;
}


- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	os_log(HSLog(), "#%u dealloc (animateCalls=%llu presented=%llu)", lInstanceID, lAnimateCalls,
		   lRenderer ? lRenderer->frameStats().presented : 0);
	[self releaseRenderer];
}


- (void)setFrameSize:(NSSize)size
{
	os_log(HSLog(), "#%u setFrameSize %{public}@ (was %{public}@)", lInstanceID, NSStringFromSize(size),
		   NSStringFromSize(self.frame.size));
	[super setFrameSize:size];
	if (lView)
		[lView setFrameSize:size];
}


- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
	os_log(HSLog(), "#%u drawableSizeWillChange %{public}@", lInstanceID, NSStringFromSize(NSSizeFromCGSize(size)));
	if (size.width >= 1 && size.height >= 1)
		reshape(int(size.width), int(size.height), &lSettings);
}


// reshape() is the only thing that ever sets the projection matrix and viewport, and
// drawableSizeWillChange: can't be relied on to deliver it: MTKView computes its initial
// drawableSize in initWithFrame:, before lView.delegate is assigned, and never re-reports it
// unless the size later changes (e.g. a backing-scale change on window attach). When the host
// creates this view at its final size and never resizes it — the normal case in
// legacyScreenSaver — the delegate never fires, the projection stays all zeros, and every
// frame renders black. So check the real drawable size on every frame instead.
- (void)syncViewportWithDrawable
{
	CGSize size = lView.drawableSize;
	if (size.width < 1 || size.height < 1)
		return;
	if (int(size.width) != lSettings.xsize || int(size.height) != lSettings.ysize)
	{
		os_log(HSLog(), "#%u syncViewport reshape %dx%d -> %dx%d", lInstanceID, lSettings.xsize, lSettings.ysize,
			   int(size.width), int(size.height));
		reshape(int(size.width), int(size.height), &lSettings);
	}
}


// legacyScreenSaver often adds this view to its host window before that window has a screen
// (window frame 0x0, screen nil). MTKView then sets its CAMetalLayer's contentsScale to 0, and
// the host later gives the window a screen and size with only resize/screen-change notifications,
// never a backing-properties change, so MTKView never corrects it. A layer with contentsScale 0
// composites nothing, even though every drawable presents successfully: 60fps, no errors, black
// screen. Keep the layer's scale in step with the window's backing scale ourselves.
- (void)syncLayerScale
{
	CALayer *layer = lView.layer;
	CGFloat scale = self.window.backingScaleFactor;
	if (scale < 1.0)
		scale = self.window.screen.backingScaleFactor;
	if (scale < 1.0 || !layer || layer.contentsScale == scale)
		return;
	os_log(HSLog(), "#%u syncLayerScale contentsScale %.2f -> %.2f", lInstanceID, layer.contentsScale, scale);
	layer.contentsScale = scale;
}


- (void)viewDidMoveToWindow
{
	[super viewDidMoveToWindow];

	// legacyScreenSaver removes views from their window when the preview changes or the saver
	// ends, but never calls stopAnimation and keeps the view alive: each such instance used to
	// hold ~220MB (scene, textures, vertex rings, 4K drawables) for the life of the process,
	// growing with every saver activation. Stop and release everything once detached.
	if (!self.window)
	{
		os_log(HSLog(), "#%u detached from window: isAnimating=%d, releasing renderer", lInstanceID, self.isAnimating);
		if (self.isAnimating)
			[self stopAnimation];
		[self releaseRenderer];
		[[NSNotificationCenter defaultCenter] removeObserver:self];
		return;
	}
	if (!lView && lCanRender)
		[self setUpRenderer];

	NSScreen *screen = self.window.screen;
	self.animationTimeInterval = screen ? screen.minimumRefreshInterval : (1.0 / 60.0);
	os_log(HSLog(), "#%u viewDidMoveToWindow window=%p windowFrame=%{public}@ screen=%{public}@ scale=%.1f "
		   "frame=%{public}@ mtkFrame=%{public}@ drawableSize=%{public}@ interval=%.4f",
		   lInstanceID, self.window, NSStringFromRect(self.window.frame), screen.localizedName,
		   self.window.backingScaleFactor, NSStringFromRect(self.frame), NSStringFromRect(lView.frame),
		   NSStringFromSize(NSSizeFromCGSize(lView.drawableSize)), self.animationTimeInterval);

	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	for (NSNotificationName name in @[NSWindowDidResizeNotification, NSWindowDidChangeScreenNotification,
									  NSWindowDidChangeBackingPropertiesNotification, NSWindowDidChangeOcclusionStateNotification])
	{
		[nc removeObserver:self name:name object:nil];
		if (self.window)
			[nc addObserver:self selector:@selector(logWindowNotification:) name:name object:self.window];
	}
}


- (void)logWindowNotification:(NSNotification *)note
{
	NSWindow *w = note.object;
	os_log(HSLog(), "#%u %{public}@ winFrame=%{public}@ screen=%{public}@ scale=%.1f occlusionVisible=%d "
		   "frame=%{public}@ mtkLayerBounds=%{public}@ drawable=%{public}@",
		   lInstanceID, note.name, NSStringFromRect(w.frame), w.screen.localizedName, w.backingScaleFactor,
		   (w.occlusionState & NSWindowOcclusionStateVisible) != 0, NSStringFromRect(self.frame),
		   NSStringFromRect(NSRectFromCGRect(lView.layer.bounds)), NSStringFromSize(NSSizeFromCGSize(lView.drawableSize)));
}


- (void)startAnimation
{
	if (!lView && lCanRender && self.window)
		[self setUpRenderer];
    [super startAnimation];
	os_log(HSLog(), "#%u startAnimation isAnimating=%d configuring=%d readyToDraw=%d window=%p",
		   lInstanceID, self.isAnimating, lIsConfiguring, lSettings.readyToDraw, self.window);
	os_signpost_interval_begin(HSSignpostLog(), lSignpostID, "animating", "#%u", lInstanceID);

	if (lIsConfiguring == NO && lView)
    {
        if (lMainScreen || !lMainScreenOnly)
        {
			CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
			os_signpost_interval_begin(HSSignpostLog(), lSignpostID, "initSaver", "#%u", lInstanceID);
            initSaver(&lSettings);
			os_signpost_interval_end(HSSignpostLog(), lSignpostID, "initSaver", "#%u", lInstanceID);
			os_log(HSLog(), "#%u initSaver took %.0f ms, readyToDraw=%d", lInstanceID,
				   (CFAbsoluteTimeGetCurrent() - start) * 1000.0, lSettings.readyToDraw);
			timer.reset();
        }
    }
}


- (void)stopAnimation
{
    [super stopAnimation];
	os_log(HSLog(), "#%u stopAnimation configuring=%d readyToDraw=%d", lInstanceID, lIsConfiguring, lSettings.readyToDraw);
	os_signpost_interval_end(HSSignpostLog(), lSignpostID, "animating", "#%u", lInstanceID);

	if (lIsConfiguring == NO && lView)
    {
        if (lMainScreen || !lMainScreenOnly)
		{
			cleanUp(&lSettings);
            lSettings.frameTime=0;
		}
	}
}


- (void)drawRect:(NSRect)rect
{
    if (!lLoggedFirstDrawRect)
	{
		lLoggedFirstDrawRect = YES;
		os_log(HSLog(), "#%u first drawRect %{public}@ (lView=%p)", lInstanceID, NSStringFromRect(rect), lView);
	}
    [[NSColor blackColor] set];
    NSRectFill(rect);

    if (!lCanRender)
    {
		if (lMainScreen || !lMainScreenOnly)
        {
            NSRect tFrame=[self frame];
            NSRect tStringFrame;
            NSDictionary * tAttributes;
            NSString * tString;
            NSMutableParagraphStyle * tParagraphStyle;

            tParagraphStyle=[[NSParagraphStyle defaultParagraphStyle] mutableCopy];
            [tParagraphStyle setAlignment:NSTextAlignmentCenter];

            tAttributes = [NSDictionary dictionaryWithObjectsAndKeys:[NSFont systemFontOfSize:[NSFont systemFontSize]],NSFontAttributeName,[NSColor whiteColor],NSForegroundColorAttributeName,tParagraphStyle,NSParagraphStyleAttributeName,nil];

            tString=NSLocalizedStringFromTableInBundle(@"Minimum Metal requirements\rfor this Screen Effect\rnot available\ron your Mac.",@"Localizable",[NSBundle bundleForClass:[self class]],@"No comment");

            tStringFrame.origin=NSZeroPoint;
            tStringFrame.size=[tString sizeWithAttributes:tAttributes];

            tStringFrame=SSCenteredRectInRect(tStringFrame,tFrame);

            [tString drawInRect:tStringFrame withAttributes:tAttributes];
        }
    }
}


- (void)animateOneFrame
{
	lAnimateCalls++;
	if (lAnimateCalls == 1)
		os_log(HSLog(), "#%u first animateOneFrame", lInstanceID);
	[self logStatsIfDue];

	if (lIsConfiguring == NO && lView)
    {
        if (lMainScreen || !lMainScreenOnly)
        {
			lSettings.frameTime = timer.tick();
			if (lSettings.readyToDraw)
				[lView draw];
        }
    }
}


- (void)drawInMTKView:(MTKView *)view
{
	lDrawCalls++;
	[self syncLayerScale];
	[self syncViewportWithDrawable];
	if (!lRenderer->beginFrame())
		return;
	os_signpost_interval_begin(HSFrameSignpostLog(), lFrameSignpostID, "frame", "#%u", lInstanceID);
	draw(&lSettings);
	lRenderer->endFrame();
	os_signpost_interval_end(HSFrameSignpostLog(), lFrameSignpostID, "frame", "#%u", lInstanceID);
	if (!lLoggedFirstPresent)
	{
		lLoggedFirstPresent = YES;
		os_log(HSLog(), "#%u first frame presented (drawableSize=%{public}@, %llu animate calls in)", lInstanceID,
			   NSStringFromSize(NSSizeFromCGSize(view.drawableSize)), lAnimateCalls);
	}
}


// Every ~2s per instance (debug level; stream with --level debug): what the host is driving (animate calls), what reached the renderer
// (draw calls), and where frames went (presented vs. each skip reason, GPU completions/errors),
// plus the geometry/visibility state most likely to explain a blank screen.
- (void)logStatsIfDue
{
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (lLastStatsTime == 0)
		lLastStatsTime = now;
	if (now - lLastStatsTime < 2.0)
		return;

	HSFrameStats s = lRenderer ? lRenderer->frameStats() : HSFrameStats();
	HSFrameStats &p = lLastStats;
	NSWindow *w = self.window;
	os_log_debug(HSLog(), "#%u stats %.1fs: animate=%llu draw=%llu presented=%llu skip[reent=%llu noPass=%llu noDrawable=%llu fence=%llu] "
		   "gpuDone=%llu gpuErr=%llu | ready=%d cfg=%d size=%dx%d frame=%{public}@ drawable=%{public}@ "
		   "window=%p visible=%d occluded=%d hidden=%d",
		   lInstanceID, now - lLastStatsTime,
		   lAnimateCalls - lLastAnimateCalls, lDrawCalls - lLastDrawCalls, s.presented - p.presented,
		   s.skipReentrant - p.skipReentrant, s.skipNoPassDescriptor - p.skipNoPassDescriptor,
		   s.skipNoDrawable - p.skipNoDrawable, s.skipFenceTimeout - p.skipFenceTimeout,
		   s.gpuCompleted - p.gpuCompleted, s.gpuErrors - p.gpuErrors,
		   lSettings.readyToDraw, lIsConfiguring, lSettings.xsize, lSettings.ysize,
		   NSStringFromRect(self.frame), NSStringFromSize(NSSizeFromCGSize(lView.drawableSize)),
		   w, w.isVisible, w ? !(w.occlusionState & NSWindowOcclusionStateVisible) : -1,
		   self.isHiddenOrHasHiddenAncestor);

	CALayer *ml = lView.layer;
	CALayer *root = ml;
	int depth = 0;
	while (root.superlayer) { root = root.superlayer; depth++; }
	os_log_debug(HSLog(), "#%u layers: winFrame=%{public}@ screen=%{public}@ content=%{public}@ selfLayer=%{public}@ "
		   "mtkLayer=%{public}@ %{public}@ bounds=%{public}@ scale=%.1f hidden=%d opacity=%.2f depth=%d root=%{public}@ rootBounds=%{public}@",
		   lInstanceID, NSStringFromRect(w.frame), w.screen.localizedName, NSStringFromRect(w.contentView.frame),
		   NSStringFromRect(NSRectFromCGRect(self.layer.frame)), NSStringFromClass(ml.class),
		   ml.superlayer ? @"attached" : @"DETACHED", NSStringFromRect(NSRectFromCGRect(ml.bounds)), ml.contentsScale,
		   ml.isHidden, ml.opacity, depth, NSStringFromClass(root.class), NSStringFromRect(NSRectFromCGRect(root.bounds)));

	lLastStats = s;
	lLastAnimateCalls = lAnimateCalls;
	lLastDrawCalls = lDrawCalls;
	lLastStatsTime = now;
}


- (BOOL)hasConfigureSheet
{
    return lCanRender;
}


- (NSWindow*)configureSheet
{
    lIsConfiguring = YES;
	if (ibConfigureSheet == nil)
	{
		if ([[NSBundle bundleForClass:self.class] loadNibNamed:@"ConfigureSheet" owner:self topLevelObjects:NULL])
		{
			[ibVersionTxt setStringValue:[[[NSBundle bundleForClass:[self class]] infoDictionary] objectForKey:@"CFBundleVersion"]];	// set the version text
			[self setDialogValue];
		}
		else
			NSLog(@"Warning: %@ couldn't load ConfigureSheet.nib.", [self className]);
	}
	return ibConfigureSheet;
}


#pragma mark -


- (IBAction)closeSheet:(id)sender
{
	NSString *identifier = [[NSBundle bundleForClass:[self class]] bundleIdentifier];
    ScreenSaverDefaults *inDefaults = [ScreenSaverDefaults defaultsForModuleWithName:identifier];
	
	[inDefaults setInteger:lSettings.dSpeed forKey:@"Speed"];
	[inDefaults setInteger:lSettings.dStars forKey:@"Stars"];
	[inDefaults setInteger:lSettings.dStarSize forKey:@"StarSize"];
	[inDefaults setInteger:lSettings.dResolution forKey:@"Resolution"];
	[inDefaults setInteger:lSettings.dDepth forKey:@"Depth"];
	[inDefaults setInteger:lSettings.dFov forKey:@"Fov"];
	[inDefaults setBool:lSettings.dUseGoo forKey:@"UseGoo"];
	[inDefaults setBool:lSettings.dUseTunnels forKey:@"UseTunnels"];
	[inDefaults setBool:lMainScreenOnly forKey:@"MainScreenOnly"];
	[inDefaults synchronize];
	
	lIsConfiguring = NO;
	if ([self isAnimating])
	{
		[self stopAnimation];
		[self startAnimation];
		if (lView)	// re-derive the projection matrix, since initSaver() doesn't know the new FOV
			reshape(int(lView.drawableSize.width), int(lView.drawableSize.height), &lSettings);
	}
	[NSApp endSheet:ibConfigureSheet];
	[ibConfigureSheet orderOut:self];
}


- (IBAction)reset:(id)sender
{
	setDefaults(&lSettings);
	[self setDialogValue];
}


- (IBAction)setValueForSender:(id)sender
{
	switch ([sender tag])
	{
		case 1:	// resolution of geometry
			lSettings.dResolution = [sender intValue];
			[ibResolutionTxt setIntValue:[sender intValue]];
			break;
		case 2:	// number of stars
			lSettings.dStars = [sender intValue];
			[ibStarsTxt setIntValue:[sender intValue]];
			break;
		case 3:	// speed
			lSettings.dSpeed = [sender intValue];
			[ibSpeedTxt setIntValue:[sender intValue]];
			break;
		case 4:	// size of stars
			lSettings.dStarSize = [sender intValue];
			[ibStarSizeTxt setIntValue:[sender intValue]];
			break;
		case 5:	// view depth
			lSettings.dDepth = [sender intValue];
			[ibDepthTxt setIntValue:[sender intValue]];
			break;
		case 6:	// field of view
			lSettings.dFov = [sender intValue];
			[ibFovTxt setIntValue:[sender intValue]];
			break;
		case 8:	// main screen
			lMainScreenOnly = ([sender state] == NSControlStateValueOn ? true : false);
			break;
		case 9:	// goo
			lSettings.dUseGoo = ([sender state] == NSControlStateValueOn ? true : false);
			break;
		case 10:	// tunnels
			lSettings.dUseTunnels = ([sender state] == NSControlStateValueOn ? true : false);
			break;
	}
}

@end


@implementation HyperspaceView (Private)

- (void)readDefaults:(ScreenSaverDefaults *)inDefaults
{
    lSettings.dSpeed = int([inDefaults integerForKey:@"Speed"]);
	lSettings.dStars = int([inDefaults integerForKey:@"Stars"]);
	lSettings.dStarSize = int([inDefaults integerForKey:@"StarSize"]);
	lSettings.dResolution = int([inDefaults integerForKey:@"Resolution"]);
	lSettings.dDepth = int([inDefaults integerForKey:@"Depth"]);
	lSettings.dFov = int([inDefaults integerForKey:@"Fov"]);
	if ([inDefaults objectForKey:@"UseGoo"])
		lSettings.dUseGoo = [inDefaults integerForKey:@"UseGoo"];
	if ([inDefaults objectForKey:@"UseTunnels"])
		lSettings.dUseTunnels = [inDefaults integerForKey:@"UseTunnels"];
	lMainScreenOnly = [inDefaults boolForKey:@"MainScreenOnly"];
}


- (void)setDialogValue
{
	[ibResolution setIntValue:lSettings.dResolution];
	[ibResolutionTxt setIntValue:lSettings.dResolution];
	[ibStars setIntValue:lSettings.dStars];
	[ibStarsTxt setIntValue:lSettings.dStars];
	[ibSpeed setIntValue:lSettings.dSpeed];
	[ibSpeedTxt setIntValue:lSettings.dSpeed];
	[ibStarSize setIntValue:lSettings.dStarSize];
	[ibStarSizeTxt setIntValue:lSettings.dStarSize];
	[ibDepth setIntValue:lSettings.dDepth];
	[ibDepthTxt setIntValue:lSettings.dDepth];
	[ibFov setIntValue:lSettings.dFov];
	[ibFovTxt setIntValue:lSettings.dFov];
	[ibGooCbx setState:(lSettings.dUseGoo ? NSControlStateValueOn : NSControlStateValueOff)];
	[ibTunnelCbx setState:(lSettings.dUseTunnels ? NSControlStateValueOn : NSControlStateValueOff)];
	[ibMainScreenOnlyCbx setState:(lMainScreenOnly ? NSControlStateValueOn : NSControlStateValueOff)];
}

@end
