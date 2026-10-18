//
//  HSLog.h
//  Hyperspace
//
//  Diagnostic logging for chasing blank-screen issues in the legacyScreenSaver host.
//  Stream with:
//    log stream --level debug --predicate 'subsystem == "com.reallyslick.Hyperspace"'
//  Signposts show up in Instruments' "Points of Interest" track.
//

#ifndef HSLOG_H
#define HSLOG_H

#include <os/log.h>
#include <os/signpost.h>
#include <dispatch/dispatch.h>

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

#endif
