//
//  HSLog.h
//  Hyperspace
//
//  Diagnostic logging for chasing blank-screen issues in the legacyScreenSaver host.
//  Stream with:
//    log stream --level debug --predicate 'subsystem == "com.reallyslick.Hyperspace"'
//  Lifecycle signposts show up in Instruments' "Points of Interest" track; the per-frame
//  interval is opt-in (see HSFrameSignpostLog).
//

#ifndef HSLOG_H
#define HSLOG_H

#include <os/log.h>
#include <os/signpost.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>

static inline os_log_t HSLog()
{
	static os_log_t log;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ log = os_log_create("com.reallyslick.Hyperspace", "render"); });
	return log;
}

static inline os_log_t HSSignpostLog()
{
	static os_log_t log;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ log = os_log_create("com.reallyslick.Hyperspace", OS_LOG_CATEGORY_POINTS_OF_INTEREST); });
	return log;
}

// Per-frame signposts are opt-in: set HYPERSPACE_FRAME_SIGNPOSTS=1 in the environment (e.g. the
// HyperspaceHost scheme) to record them in Points of Interest. Otherwise this returns
// OS_LOG_DISABLED, which makes the signpost calls no-ops: always-on Points of Interest
// signposts at ~60fps were a steady stream into the system log. (OS_LOG_CATEGORY_DYNAMIC_TRACING
// would be quiet too, but Instruments' os_signpost instrument doesn't enable it, so nothing is
// captured.) Instruments can't record signposts from the sandboxed legacyScreenSaver host at all,
// so profile frames in HyperspaceHost.
static inline os_log_t HSFrameSignpostLog()
{
	static os_log_t log;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		const char *flag = getenv("HYPERSPACE_FRAME_SIGNPOSTS");
		bool enabled = flag && flag[0] && strcmp(flag, "0") != 0;
		log = enabled ? os_log_create("com.reallyslick.Hyperspace", OS_LOG_CATEGORY_POINTS_OF_INTEREST) : OS_LOG_DISABLED;
	});
	return log;
}

#endif
