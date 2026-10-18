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
#import <sys/time.h>

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
		lSettings.doingPreview = isPreview;
		if (isPreview)
			lMainScreen = YES;
		else
			lMainScreen = (frame.origin.x == 0 && frame.origin.y == 0) ? YES : NO;
		lIsConfiguring = NO;
		lMainScreenOnly = [defaults boolForKey:@"MainScreenOnly"];
		if (lMainScreen || !lMainScreenOnly)
		{
			MTKView *candidateView = [[MTKView alloc] initWithFrame:NSZeroRect];
			HSRenderer *renderer = new HSRenderer;

			if (renderer->attachToView(candidateView))
			{
				lView = candidateView;
				lRenderer = renderer;
				lView.delegate = self;
				[self addSubview:lView];

				lSettings.frameTime = 0;
				lSettings.renderer = lRenderer;

				setDefaults(&lSettings);
				if ([defaults objectForKey:@"Speed"])
				{
					[self readDefaults:defaults];
				}

				self.animationTimeInterval = 1.0/60.0;
				lSettings.first = 1;
			}
			else
			{
				delete renderer;
			}
		}
    }
    return self;
}


- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	if (lView)
		[lView setFrameSize:size];
}


- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
	reshape(int(size.width), int(size.height), &lSettings);
}


- (void)viewDidMoveToWindow
{
	[super viewDidMoveToWindow];
	if (@available(macOS 12.0, *))	// on Monterey and later, update the time interval for the window's screen's refresh rate
	{
		self.animationTimeInterval = self.window.screen.maximumRefreshInterval;
	}
}


- (void)startAnimation
{
    [super startAnimation];

	if (lIsConfiguring == NO && lView)
    {
        if (lMainScreen || !lMainScreenOnly)
        {
            initSaver(&lSettings);
			gettimeofday(&timer.prev_tv, NULL);	// reset the timer
        }
    }
}


- (void)stopAnimation
{
    [super stopAnimation];

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
    [[NSColor blackColor] set];
    NSRectFill(rect);

    if (lView == nil)
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

            tString=NSLocalizedStringFromTableInBundle(@"Minimum OpenGL requirements\rfor this Screen Effect\rnot available\ron your graphic card.",@"Localizable",[NSBundle bundleForClass:[self class]],@"No comment");

            tStringFrame.origin=NSZeroPoint;
            tStringFrame.size=[tString sizeWithAttributes:tAttributes];

            tStringFrame=SSCenteredRectInRect(tStringFrame,tFrame);

            [tString drawInRect:tStringFrame withAttributes:tAttributes];
        }
    }
}


- (void)animateOneFrame
{
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
	if (!lRenderer->beginFrame())
		return;
	draw(&lSettings);
	lRenderer->endFrame();
}


- (BOOL)hasConfigureSheet
{
    return (lView != nil);
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
	[inDefaults setBool:lSettings.dShaders forKey:@"UseShaders"];
	[inDefaults setBool:lSettings.dUseGoo forKey:@"UseGoo"];
	[inDefaults setBool:lSettings.dUseTunnels forKey:@"UseTunnels"];
	[inDefaults setBool:lMainScreenOnly forKey:@"MainScreenOnly"];
	[inDefaults synchronize];
	
	lIsConfiguring = NO;
	if ([self isAnimating])
	{
		[self stopAnimation];
		[self startAnimation];
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
		case 7:	// shaders
			lSettings.dShaders = ([sender state] == NSOnState ? true : false);
			break;
		case 8:	// main screen
			lMainScreenOnly = ([sender state] == NSOnState ? true : false);
			break;
		case 9:	// goo
			lSettings.dUseGoo = ([sender state] == NSOnState ? true : false);
			break;
		case 10:	// tunnels
			lSettings.dUseTunnels = ([sender state] == NSOnState ? true : false);
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
	lSettings.dShaders = [inDefaults integerForKey:@"UseShaders"];
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
	[ibShaderCbx setState:(lSettings.dShaders ? NSOnState : NSOffState)];
	[ibGooCbx setState:(lSettings.dUseGoo ? NSOnState : NSOffState)];
	[ibTunnelCbx setState:(lSettings.dUseTunnels ? NSOnState : NSOffState)];
	[ibMainScreenOnlyCbx setState:(lMainScreenOnly ? NSOnState : NSOffState)];
}

@end
