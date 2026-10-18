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


#include <Hyperspace/starBurst.h>
#include <Hyperspace/wavyNormalCubeMaps.h>
#include <Hyperspace/flare.h>
#include <Hyperspace/HSRenderer.h>
#include <rsMath/rsMath.h>


starBurst::starBurst(){
	int i, j;
	float vel[3];
	float normalizer;

	// initialize stars
	stars = new stretchedParticle*[SB_NUM_STARS];
	stars_active = new bool[SB_NUM_STARS];
	stars_velocity = new float*[SB_NUM_STARS];
	for(i=0; i<SB_NUM_STARS; i++){
		stars[i] = new stretchedParticle;
		stars_active[i] = 0;
		stars_velocity[i] = new float[3];
		vel[0] = rsRandf(1.0f) - 0.5f;
		vel[1] = rsRandf(1.0f) - 0.5f;
		vel[2] = rsRandf(1.0f) - 0.5f;
		normalizer = (rsRandf(0.75f) + 0.25f)
			/ sqrtf(vel[0] * vel[0] + vel[1] * vel[1] + vel[2] * vel[2]);
		stars_velocity[i][0] = vel[0] * normalizer;
		stars_velocity[i][1] = vel[1] * normalizer;
		stars_velocity[i][2] = vel[2] * normalizer;
	}

	// Precompute the unit sphere once, replacing the original's GL_TRIANGLE_STRIP display
	// list. Each of the 32 latitude bands keeps its own 33 vertex pairs (not shared with
	// neighboring bands), matching the original's redundant immediate-mode vertex emission
	// exactly; the strip-to-triangle-list expansion below is the standard one (triangle k
	// of a strip is vertices k, k+1, k+2), which preserves the original's winding.
	float xyz[3];
	float ci, si, cj, sj, cjj, sjj;
	for(j=0; j<32; j++){
		cj = cosf(float(j) * RS_PIx2 / 32.0f);
		sj = sinf(float(j) * RS_PIx2 / 32.0f);
		cjj = cosf(float(j+1) * RS_PIx2 / 32.0f);
		sjj = sinf(float(j+1) * RS_PIx2 / 32.0f);
		const unsigned int bandStart = (unsigned int)(sphereVertices.size() / 6);
		for(i=0; i<=32; i++){
			ci = cosf(float(i) * RS_PIx2 / 32.0f);
			si = sinf(float(i) * RS_PIx2 / 32.0f);
			xyz[0] = sj * ci;
			xyz[1] = cj;
			xyz[2] = sj * si;
			// normal == position on a unit sphere
			sphereVertices.insert(sphereVertices.end(), {xyz[0], xyz[1], xyz[2], xyz[0], xyz[1], xyz[2]});
			xyz[0] = sjj * ci;
			xyz[1] = cjj;
			xyz[2] = sjj * si;
			sphereVertices.insert(sphereVertices.end(), {xyz[0], xyz[1], xyz[2], xyz[0], xyz[1], xyz[2]});
		}
		const unsigned int bandVertexCount = 2 * 33;
		for(unsigned int k=0; k+2<bandVertexCount; k++){
			sphereIndices.push_back(bandStart + k);
			sphereIndices.push_back(bandStart + k + 1);
			sphereIndices.push_back(bandStart + k + 2);
		}
	}

	size = 4.0f;
}


// Declared but never defined even in the original, since nothing there ever deleted a
// starBurst (it leaked instead); defined now that cleanUp() actually does.
starBurst::~starBurst(){
	for(int i=0; i<SB_NUM_STARS; i++){
		delete stars[i];
		delete[] stars_velocity[i];
	}
	delete[] stars;
	delete[] stars_active;
	delete[] stars_velocity;
}


void starBurst::restart(float* position){
	int i;

	for(i=0; i<SB_NUM_STARS; i++){  // don't restart if any star is still active
		if(stars_active[i])
			return;
	}
	if(size < 3.0f)  // or if flare hasn't faded out completely
		return;

	float color[3];
	color[0] = rsRandf(1.0f);
	color[1] = rsRandf(1.0f);
	color[2] = rsRandf(1.0f);
	color[rsRandi(3)] = 1.0f;
	for(i=0; i<SB_NUM_STARS; i++){
		stars_active[i] = 1;
		stars[i]->pos[0] = position[0];
		stars[i]->pos[1] = position[1];
		stars[i]->pos[2] = position[2];
		stars[i]->color[0] = color[0];
		stars[i]->color[1] = color[1];
		stars[i]->color[2] = color[2];
	}

	size = 0.0f;
	pos[0] = position[0];
	pos[1] = position[1];
	pos[2] = position[2];
}


void starBurst::drawStars(HyperspaceSaverSettings *inSettings){
	int i;
	float distance;

	// draw stars
	inSettings->renderer->setPipeline(HS_PIPELINE_SPRITE);
	inSettings->renderer->bindTexture(0, inSettings->flaretex[0]);
	for(i=0; i<SB_NUM_STARS; i++){
		stars[i]->pos[0] += stars_velocity[i][0] * inSettings->frameTime;
		stars[i]->pos[1] += stars_velocity[i][1] * inSettings->frameTime;
		stars[i]->pos[2] += stars_velocity[i][2] * inSettings->frameTime;
		distance = sqrtf((stars[i]->pos[0] - inSettings->camPos[0]) * (stars[i]->pos[0] - inSettings->camPos[0])
			+ (stars[i]->pos[1] - inSettings->camPos[1]) * (stars[i]->pos[1] - inSettings->camPos[1])
			+ (stars[i]->pos[2] - inSettings->camPos[2]) * (stars[i]->pos[2] - inSettings->camPos[2]));
		if(distance > inSettings->depth)
			stars_active[i] = 0;
		if(stars_active[i])
			stars[i]->draw(inSettings->camPos, inSettings->unroll, inSettings->modelMat, inSettings->projMat, inSettings->viewport, inSettings->renderer);
	}
}


void starBurst::draw(float lerp, HyperspaceSaverSettings *inSettings){
	drawStars(inSettings);

	size += inSettings->frameTime * 0.5f;
	if(size >= 3.0f)
		return;

	// draw flare
	float brightness = 1.0f - (size * 0.333333f);
	if(brightness > 0.0f){
		float p[3];
		p[0] = pos[0];
		p[1] = pos[1];
		p[2] = pos[2];
		flare(p, 1.0f, 1.0f, 1.0f, brightness, inSettings);
	}

	HSRenderer *renderer = inSettings->renderer;
	renderer->matrixPush();
	renderer->translate(pos[0], pos[1], pos[2]);
	renderer->scale(size, size, size);

	// draw sphere
	renderer->setPipeline(HS_PIPELINE_GOO);
	renderer->bindTexture(0, inSettings->theWNCM->texture[inSettings->whichTexture]);
	renderer->bindTexture(1, inSettings->theWNCM->texture[(inSettings->whichTexture + 1) % inSettings->numAnimTexFrames]);
	renderer->bindTexture(2, inSettings->nebulatex);
	renderer->color4f(brightness, brightness, brightness, lerp);
	renderer->drawIndexedMesh(sphereVertices.data(), (uint32_t)(sphereVertices.size() / 6),
							   sphereIndices.data(), (uint32_t)sphereIndices.size());

	renderer->matrixPop();
}
