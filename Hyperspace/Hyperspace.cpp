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


// Hyperspace screensaver
// Terry Welsh
// Originally wrote this saver in 2001, but computers weren't fast
// enough to run it at a decent frame rate.  Finally released it in 2005.

#include <stdio.h>
#include <math.h>
#include <time.h>
#include <vector>
#include <stdint.h>
#include <rsMath/rsMath.h>
#include <Hyperspace/flare.h>
#include <Hyperspace/causticTextures.h>
#include <Hyperspace/wavyNormalCubeMaps.h>
#include <Hyperspace/splinePath.h>
#include <Hyperspace/tunnel.h>
#include <Hyperspace/goo.h>
#include <Hyperspace/stretchedParticle.h>
#include <Hyperspace/starBurst.h>
#include <Hyperspace/nebulamap.h>
#include "Hyperspace.h"


void draw(HyperspaceSaverSettings *inSettings){
	// Camera movements
	static float camHeading[3] = {0.0f, 0.0f, 0.0f};  // current, target, and last
	static int changeCamHeading = 1;
	static float camHeadingChangeTime[2] = {20.0f, 0.0f};  // total, elapsed
	static float camRoll[3] = {0.0f, 0.0f, 0.0f};  // current, target, and last
	static int changeCamRoll = 1;
	static float camRollChangeTime[2] = {1.0f, 0.0f};  // total, elapsed
	camHeadingChangeTime[1] += inSettings->frameTime;
	if(camHeadingChangeTime[1] >= camHeadingChangeTime[0]){  // Choose new direction
		camHeadingChangeTime[0] = rsRandf(15.0f) + 5.0f;
		camHeadingChangeTime[1] = 0.0f;
		camHeading[2] = camHeading[1];  // last = target
		if(changeCamHeading){
			// face forward most of the time
			if(rsRandi(6))
				camHeading[1] = 0.0f;
			// face backward the rest of the time
			else if(rsRandi(2))
				camHeading[1] = RS_PI;
			else
				camHeading[1] = -RS_PI;
			changeCamHeading = 0;
		}
		else
			changeCamHeading = 1;
	}
	float t = camHeadingChangeTime[1] / camHeadingChangeTime[0];
	t = 0.5f * (1.0f - cosf(RS_PI * t));
	camHeading[0] = camHeading[1] * t + camHeading[2] * (1.0f - t);
	camRollChangeTime[1] += inSettings->frameTime;
	if(camRollChangeTime[1] >= camRollChangeTime[0]){  // Choose new roll angle
		camRollChangeTime[0] = rsRandf(5.0f) + 10.0f;
		camRollChangeTime[1] = 0.0f;
		camRoll[2] = camRoll[1];  // last = target
		if(changeCamRoll){
			camRoll[1] = rsRandf(RS_PIx2*2) - RS_PIx2;
			changeCamRoll = 0;
		}
		else
			changeCamRoll = 1;
	}
	t = camRollChangeTime[1] / camRollChangeTime[0];
	t = 0.5f * (1.0f - cosf(RS_PI * t));
	camRoll[0] = camRoll[1] * t + camRoll[2] * (1.0f - t);

	static float pathDir[3] = {0.0f, 0.0f, -1.0f};
	inSettings->thePath->moveAlongPath(float(inSettings->dSpeed) * inSettings->frameTime * 0.04f);
	inSettings->thePath->update(inSettings->frameTime);
	inSettings->thePath->getPoint(inSettings->dDepth + 2, inSettings->thePath->step, inSettings->camPos);
	inSettings->thePath->getBaseDirection(inSettings->dDepth + 2, inSettings->thePath->step, pathDir);
	float pathAngle = atan2f(-pathDir[0], -pathDir[2]);

	// Build the camera matrices through HSRenderer's modelview stack, the direct
	// replacement for GL_MODELVIEW (same loadIdentity/rotate/translate/readback
	// sequence the original glRotatef/glTranslatef/glGetFloatv|Doublev code used).
	inSettings->renderer->loadIdentity();
	inSettings->renderer->rotate((pathAngle + camHeading[0]) * RS_RAD2DEG, 0, 1, 0);
	inSettings->renderer->rotate(camRoll[0] * RS_RAD2DEG, 0, 0, 1);
	inSettings->renderer->getCurrentMatrix(inSettings->billboardMat);
	inSettings->renderer->loadIdentity();
	inSettings->renderer->rotate(-camRoll[0] * RS_RAD2DEG, 0, 0, 1);
	inSettings->renderer->rotate((-pathAngle - camHeading[0]) * RS_RAD2DEG, 0, 1, 0);
	inSettings->renderer->translate(inSettings->camPos[0]*-1, inSettings->camPos[1]*-1, inSettings->camPos[2]*-1);
	inSettings->renderer->getCurrentMatrix(inSettings->modelMat);
	inSettings->unroll = camRoll[0] * RS_RAD2DEG;

	if(inSettings->dUseGoo){
		// calculate diagonal fov
		float diagFov = 0.5f * float(inSettings->dFov) / RS_RAD2DEG;
		diagFov = tanf(diagFov);
		diagFov = sqrtf(diagFov * diagFov + (diagFov * inSettings->aspectRatio * diagFov * inSettings->aspectRatio));
		diagFov = 2.0f * atanf(diagFov);
		inSettings->theGoo->update(inSettings->camPos[0], inSettings->camPos[2], pathAngle + camHeading[0], diagFov, inSettings);
	}

	// draw stars
	inSettings->renderer->setPipeline(HS_PIPELINE_SPRITE);
	inSettings->renderer->setCullMode(HS_CULL_BACK);
	inSettings->renderer->bindTexture(0, inSettings->flaretex[0]);
	static float temppos[2];
	for(int i=0; i<inSettings->dStars; i++){
		temppos[0] = inSettings->stars[i]->pos[0] - inSettings->camPos[0];
		temppos[1] = inSettings->stars[i]->pos[2] - inSettings->camPos[2];
		if(temppos[0] > inSettings->depth){
			inSettings->stars[i]->pos[0] -= inSettings->depth * 2.0f;
			inSettings->stars[i]->lastPos[0] -= inSettings->depth * 2.0f;
		}
		if(temppos[0] < inSettings->depth*-1){
			inSettings->stars[i]->pos[0] += inSettings->depth * 2.0f;
			inSettings->stars[i]->lastPos[0] += inSettings->depth * 2.0f;
		}
		if(temppos[1] > inSettings->depth){
			inSettings->stars[i]->pos[2] -= inSettings->depth * 2.0f;
			inSettings->stars[i]->lastPos[2] -= inSettings->depth * 2.0f;
		}
		if(temppos[1] < inSettings->depth*-1){
			inSettings->stars[i]->pos[2] += inSettings->depth * 2.0f;
			inSettings->stars[i]->lastPos[2] += inSettings->depth * 2.0f;
		}
		inSettings->stars[i]->draw(inSettings->camPos, inSettings->unroll, inSettings->modelMat, inSettings->projMat, inSettings->viewport, inSettings->renderer);
	}
	inSettings->renderer->setCullMode(HS_CULL_NONE);

	// pick animated texture frame
	static float textureTime = 0.0f;
	textureTime += inSettings->frameTime;
	// loop frames every 2 seconds
	const float texFrameTime(2.0f / float(inSettings->numAnimTexFrames));
	while(textureTime > texFrameTime){
		textureTime -= texFrameTime;
		inSettings->whichTexture ++;
	}
	while(inSettings->whichTexture >= inSettings->numAnimTexFrames)
		inSettings->whichTexture -= inSettings->numAnimTexFrames;

	// alpha component gets normalmap lerp value
	const float lerp = textureTime / texFrameTime;

	// draw goo
	if(inSettings->dUseGoo){
		static float goo_rgb_phase[3] = {-0.1f, -0.1f, -0.1f};
		static float goo_rgb_speed[3] = {rsRandf(0.02f) + 0.02f, rsRandf(0.02f) + 0.02f, rsRandf(0.02f) + 0.02f};
		float goo_rgb[4];
		for(int i=0; i<3; i++){
			goo_rgb_phase[i] += goo_rgb_speed[i] * inSettings->frameTime;
			if(goo_rgb_phase[i] >= RS_PIx2)
				goo_rgb_phase[i] -= RS_PIx2;
			goo_rgb[i] = sinf(goo_rgb_phase[i]);
			if(goo_rgb[i] < 0.0f)
				goo_rgb[i] = 0.0f;
		}
		goo_rgb[3] = lerp;
		inSettings->renderer->setPipeline(HS_PIPELINE_GOO);
		inSettings->renderer->bindTexture(0, inSettings->theWNCM->texture[inSettings->whichTexture]);
		inSettings->renderer->bindTexture(1, inSettings->theWNCM->texture[(inSettings->whichTexture + 1) % inSettings->numAnimTexFrames]);
		inSettings->renderer->bindTexture(2, inSettings->nebulatex);
		inSettings->renderer->color4f(goo_rgb[0], goo_rgb[1], goo_rgb[2], goo_rgb[3]);
		inSettings->theGoo->draw(inSettings->renderer);
	}

	// update starburst
	static float starBurstTime = 300.0f;  // burst after 5 minutes
	starBurstTime -= inSettings->frameTime;
	if(starBurstTime <= 0.0f){
		float pos[] = {inSettings->camPos[0] + (pathDir[0] * inSettings->depth * (0.5f + rsRandf(0.5f))),
			rsRandf(2.0f) - 1.0f,
			inSettings->camPos[2] + (pathDir[2] * inSettings->depth * (0.5f + rsRandf(0.5f)))};
		inSettings->theStarBurst->restart(pos);  // it won't actually restart unless it's ready to
		starBurstTime = rsRandf(240.0f) + 60.0f;  // burst again within 1-5 minutes
	}
	inSettings->theStarBurst->draw(lerp, inSettings);

	// draw tunnel
	if(inSettings->dUseTunnels){
		inSettings->theTunnel->make(inSettings->frameTime);
		inSettings->renderer->setPipeline(HS_PIPELINE_TUNNEL);
		inSettings->renderer->setCullMode(HS_CULL_BACK);
		inSettings->renderer->bindTexture(1, inSettings->theCausticTextures->caustictex[(inSettings->whichTexture + 1) % inSettings->numAnimTexFrames]);
		inSettings->renderer->bindTexture(0, inSettings->theCausticTextures->caustictex[inSettings->whichTexture]);
		inSettings->theTunnel->draw(lerp, inSettings->renderer);
		inSettings->renderer->setCullMode(HS_CULL_NONE);
	}

	// draw sun with lens flare
	inSettings->renderer->setFog(inSettings->depth * 0.7f, inSettings->depth, false);
	float flarepos[3] = {0.0f, 2.0f, 0.0f};
	inSettings->renderer->setPipeline(HS_PIPELINE_SPRITE);
	inSettings->renderer->bindTexture(0, inSettings->flaretex[0]);
	inSettings->sunStar->draw(inSettings->camPos, inSettings->unroll, inSettings->modelMat, inSettings->projMat, inSettings->viewport, inSettings->renderer);
	float diff[3] = {flarepos[0] - inSettings->camPos[0], flarepos[1] - inSettings->camPos[1], flarepos[2] - inSettings->camPos[2]};
	float alpha = 0.5f - 0.005f * sqrtf(diff[0] * diff[0] + diff[1] * diff[1] + diff[2] * diff[2]);
	if(alpha > 0.0f)
		flare(flarepos, 1.0f, 1.0f, 1.0f, alpha, inSettings);
	inSettings->renderer->setFog(inSettings->depth * 0.7f, inSettings->depth, true);
}


void setDefaults(HyperspaceSaverSettings *inSettings){
	inSettings->dSpeed = 10;
	inSettings->dStars = 2000;
	inSettings->dStarSize = 10;
	inSettings->dResolution = 10;
	inSettings->dDepth = 5;
	inSettings->dFov = 50;
	inSettings->dUseTunnels = 1;
	inSettings->dUseGoo = 1;
}


void reshape(int width, int height, HyperspaceSaverSettings *inSettings){
	inSettings->aspectRatio = float(width) / float(height);
	inSettings->xsize = width;
	inSettings->ysize = height;
	inSettings->viewport[0] = 0;
	inSettings->viewport[1] = 0;
	inSettings->viewport[2] = width;
	inSettings->viewport[3] = height;

	HSRenderer::perspective(float(inSettings->dFov), inSettings->aspectRatio, 0.001f, 200.0f, inSettings->projMat);
	inSettings->renderer->setProjectionMatrix(inSettings->projMat);
}


void initSaver(HyperspaceSaverSettings *inSettings){
	srand((unsigned)time(NULL));

	inSettings->camPos[0] = 0.0f;
	inSettings->camPos[1] = 0.0f;
	inSettings->camPos[2] = 0.0f;
	inSettings->numAnimTexFrames = 20;
	inSettings->whichTexture = 0;

	initFlares(inSettings);

	inSettings->thePath = new splinePath((inSettings->dDepth * 2) + 6);

	if(inSettings->dUseTunnels){
		inSettings->theTunnel = new tunnel(inSettings->thePath, 20);
		// Unlike the original (which deferred this to the first draw() call because
		// building these textures required reading back the visible framebuffer),
		// Metal renders them directly into offscreen textures, so this can happen here.
		inSettings->theCausticTextures = new causticTextures(8, inSettings->numAnimTexFrames, 100, 256, 1.0f, 0.01f, 20.0f, inSettings->renderer);
		// causticTextures's constructor repoints the renderer's projection matrix at its
		// own ortho setup while it draws; put the real camera projection back.
		inSettings->renderer->setProjectionMatrix(inSettings->projMat);
	}

	// To avoid popping, depth, which will be used for fogging, is set to
	// dDepth * goo grid size - size of one goo cubelet
	inSettings->depth = float(inSettings->dDepth) * 2.0f - 2.0f / float(inSettings->dResolution);

	if(inSettings->dUseGoo)
		inSettings->theGoo = new goo(inSettings->dResolution, inSettings->depth);

	inSettings->stars = new stretchedParticle*[inSettings->dStars];
	for(int i=0; i<inSettings->dStars; i++){
		inSettings->stars[i] = new stretchedParticle;
		inSettings->stars[i]->radius = rsRandf(float(inSettings->dStarSize) * 0.0005f) + float(inSettings->dStarSize) * 0.0005f;
		if(i % 10){  // usually bland stars
			inSettings->stars[i]->color[0] = 0.8f + rsRandf(0.2f);
			inSettings->stars[i]->color[1] = 0.8f + rsRandf(0.2f);
			inSettings->stars[i]->color[2] = 0.8f + rsRandf(0.2f);
		}
		else{  // occasionally a colorful one
			inSettings->stars[i]->color[0] = 0.3f + rsRandf(0.7f);
			inSettings->stars[i]->color[1] = 0.3f + rsRandf(0.7f);
			inSettings->stars[i]->color[2] = 0.3f + rsRandf(0.7f);
			inSettings->stars[i]->color[rsRandi(3)] = 1.0f;
		}
		inSettings->stars[i]->color[rsRandi(3)] = 1.0f;
		inSettings->stars[i]->pos[0] = rsRandf(2.0f * inSettings->depth) - inSettings->depth;
		inSettings->stars[i]->pos[1] = rsRandf(4.0f) - 2.0f;
		inSettings->stars[i]->pos[2] = rsRandf(2.0f * inSettings->depth) - inSettings->depth;
		inSettings->stars[i]->fov = float(inSettings->dFov);
	}

	inSettings->sunStar = new stretchedParticle;
	inSettings->sunStar->radius = float(inSettings->dStarSize) * 0.004f;
	inSettings->sunStar->pos[0] = 0.0f;
	inSettings->sunStar->pos[1] = 2.0f;
	inSettings->sunStar->pos[2] = 0.0f;
	inSettings->sunStar->fov = float(inSettings->dFov);

	inSettings->theStarBurst = new starBurst;
	for(int i=0; i<SB_NUM_STARS; i++)
		inSettings->theStarBurst->stars[i]->radius = rsRandf(float(inSettings->dStarSize) * 0.001f) + float(inSettings->dStarSize) * 0.001f;

	inSettings->numAnimTexFrames = 20;

	// The original's nebula cube map uses the same baked RGB bitmap (nebulamap.h) on all
	// six faces; pad it to RGBA once here since HSRenderer textures are always RGBA8.
	{
		std::vector<uint8_t> rgba(NEBULAMAPSIZE * NEBULAMAPSIZE * 4);
		for(int i=0; i<NEBULAMAPSIZE; i++){
			for(int j=0; j<NEBULAMAPSIZE; j++){
				uint8_t *dst = &rgba[(i + j * NEBULAMAPSIZE) * 4];
				dst[0] = nebulamap[i][j][0];
				dst[1] = nebulamap[i][j][1];
				dst[2] = nebulamap[i][j][2];
				dst[3] = 255;
			}
		}
		const uint8_t *faces[6] = {rgba.data(), rgba.data(), rgba.data(), rgba.data(), rgba.data(), rgba.data()};
		inSettings->nebulatex = inSettings->renderer->createTextureCube(NEBULAMAPSIZE, faces, true);
	}

	inSettings->theWNCM = new wavyNormalCubeMaps(inSettings->numAnimTexFrames, 128, inSettings->renderer);

	inSettings->renderer->setFog(inSettings->depth * 0.7f, inSettings->depth, true);

	inSettings->readyToDraw = 1;
}


void cleanUp(HyperspaceSaverSettings *inSettings){
	for(int i=0; i<inSettings->dStars; i++)
		delete inSettings->stars[i];
	delete [] inSettings->stars;
	delete inSettings->sunStar;
	for(int i=0; i<4; i++)
		inSettings->renderer->destroyTexture(inSettings->flaretex[i]);
	if(inSettings->dUseTunnels){
		delete inSettings->theTunnel;
		delete inSettings->theCausticTextures;
	}
	if(inSettings->dUseGoo)
		delete inSettings->theGoo;
	delete inSettings->theStarBurst;
	delete inSettings->theWNCM;
	inSettings->renderer->destroyTexture(inSettings->nebulatex);
	delete inSettings->thePath;
	inSettings->first = 1;
}
