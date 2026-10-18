/*
 * Copyright (C) 2004-2010  Terence M. Welsh
 *
 * This file is part of rsUtility.
 *
 * rsUtility is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * rsUtility is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */


#ifndef RS_TIMER_H
#define RS_TIMER_H



#include <chrono>


class rsTimer{
public:
	// Time since last call to tick()
	float elapsed_time;

	rsTimer(){
		elapsed_time = 0.0f;
		reset();
	}

	// Resets the reference point used by tick(), without reporting elapsed time.
	inline void reset(){
		prev = std::chrono::steady_clock::now();
	}

	// Return time elapsed since last call to tick() (or reset()), in seconds.
	// Clamped to 0.1s so a long pause (e.g. sleep, a debugger stop) doesn't
	// make the simulation jump forward.
	inline float tick(){
		std::chrono::steady_clock::time_point now = std::chrono::steady_clock::now();
		elapsed_time = std::chrono::duration<float>(now - prev).count();
		prev = now;
		if(elapsed_time > 0.1f)
			elapsed_time = 0.1f;
		return elapsed_time;
	}

private:
	std::chrono::steady_clock::time_point prev;
};



#endif
