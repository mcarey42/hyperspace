/*
 * Copyright (C) 2005-2010  Terence M. Welsh
 *
 * This file is part of Hyperspace.
 *
 * Hyperspace is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation; either version 2 of the License,
 * or (at your option) any later version.
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


#ifndef STARBURST_H
#define STARBURST_H



#include <vector>
#include "stretchedParticle.h"
#include "Hyperspace.h"



#define SB_NUM_STARS 200



class starBurst{
public:
	stretchedParticle** stars;
	// stars only stay active while they're within viewing range
	bool* stars_active;
	float** stars_velocity;
	// Precomputed unit sphere (N3F_V3F, normal == position), replacing the original's
	// GL_TRIANGLE_STRIP display list — built once here and resubmitted via drawIndexedMesh.
	std::vector<float> sphereVertices;
	std::vector<unsigned int> sphereIndices;
	float size;
	float pos[3];

	starBurst();
	~starBurst();
	void restart(float* position);
	void drawStars(HyperspaceSaverSettings *inSettings);
	void draw(float lerp, HyperspaceSaverSettings *inSettings);
};



#endif
