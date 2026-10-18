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


#include <Hyperspace/wavyNormalCubeMaps.h>
#include <rsMath/rsMath.h>
#include <math.h>


wavyNormalCubeMaps::wavyNormalCubeMaps(int frames, int size, HSRenderer* r){
	int g;

	renderer = r;
	numFrames = frames;
	texSize = size;

	uint8_t* faceMaps[6];
	for(int f=0; f<6; f++)
		faceMaps[f] = new uint8_t[texSize * texSize * 4];

	texture = new HSTextureRef[numFrames];

	const float inv = 1.0f / float(texSize);

	// Fills one RGBA8 face buffer (alpha unused, padded to 255) from the wavy-normal
	// function. The nine coefficients convert pixel (i,j) into a point on the unit cube
	// face, matching the original's six inlined loops exactly (see the comment at each
	// call site below for which GL_TEXTURE_CUBE_MAP_*_ARB face it corresponds to).
	auto fillFace = [this](uint8_t* map,
						   float x0, float xi, float xj, float y0, float yi, float yj, float z0, float zi, float zj){
		float vec[3], norm[3];
		for(int i=0; i<texSize; i++){
			for(int j=0; j<texSize; j++){
				const float pi(float(i) - 0.5f * float(texSize) + 0.5f), pj(float(j) - 0.5f * float(texSize) + 0.5f);
				vec[0] = x0 + xi * pi + xj * pj;
				vec[1] = y0 + yi * pi + yj * pj;
				vec[2] = z0 + zi * pi + zj * pj;
				this->normalize(vec);
				this->wavyfunc(vec, norm);
				uint8_t* pixel = &map[(i + j * texSize) * 4];
				pixel[0] = uint8_t(norm[0] * 127.999f + 128.0f);
				pixel[1] = uint8_t(norm[1] * 127.999f + 128.0f);
				pixel[2] = uint8_t(norm[2] * -127.999f + 128.0f);
				pixel[3] = 255;
			}
		}
	};

	for(g=0; g<numFrames; g++){
		phase = RS_PIx2 * float(g) / float(numFrames);

		// +X (GL_TEXTURE_CUBE_MAP_POSITIVE_X_ARB, "right")
		fillFace(faceMaps[0], 0.5f,0,0, 0,0,-inv, 0,-inv,0);
		// -X (GL_TEXTURE_CUBE_MAP_NEGATIVE_X_ARB, "left")
		fillFace(faceMaps[1], -0.5f,0,0, 0,0,-inv, 0,inv,0);
		// +Y (GL_TEXTURE_CUBE_MAP_POSITIVE_Y_ARB, "top")
		fillFace(faceMaps[2], 0,inv,0, 0.5f,0,0, 0,0,inv);
		// -Y (GL_TEXTURE_CUBE_MAP_NEGATIVE_Y_ARB, "bottom")
		fillFace(faceMaps[3], 0,inv,0, -0.5f,0,0, 0,0,-inv);
		// +Z (GL_TEXTURE_CUBE_MAP_POSITIVE_Z_ARB, "front")
		fillFace(faceMaps[4], 0,inv,0, 0,0,-inv, 0.5f,0,0);
		// -Z (GL_TEXTURE_CUBE_MAP_NEGATIVE_Z_ARB, "back")
		fillFace(faceMaps[5], 0,-inv,0, 0,0,-inv, -0.5f,0,0);

		const uint8_t* constFaces[6] = {faceMaps[0], faceMaps[1], faceMaps[2], faceMaps[3], faceMaps[4], faceMaps[5]};
		texture[g] = renderer->createTextureCube(texSize, constFaces, true);
	}

	for(int f=0; f<6; f++)
		delete[] faceMaps[f];
}


wavyNormalCubeMaps::~wavyNormalCubeMaps(){
	for(int g=0; g<numFrames; g++)
		renderer->destroyTexture(texture[g]);
	delete[] texture;
}


void wavyNormalCubeMaps::wavyfunc(float* point, float* normal){
	for(int i=0; i<3; i++)
		normal[i] = point[i];

	normal[0] += 0.2f * rsCosf((1.0f * point[0] + 4.0f * point[1]) * RS_PI + phase)
		+ 0.1f * rsCosf((3.0f * point[1] + 13.0f * point[2]) * RS_PI - phase);
	normal[1] += 0.2f * rsCosf((2.0f * point[1] - 5.0f * point[2]) * RS_PI + phase)
		+ 0.1f * rsCosf((2.0f * point[2] + 12.0f * point[0]) * RS_PI - phase);
	normal[2] += 0.2f * rsCosf((1.0f * point[2] + 6.0f * point[0]) * RS_PI + phase)
		+ 0.1f * rsCosf((1.0f * point[0] - 11.0f * point[1]) * RS_PI - phase);

	normalize(normal);
}


inline void wavyNormalCubeMaps::normalize(float* vector){
	static float normalizer;

	normalizer = 1.0f / sqrtf(vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2]);
	vector[0] *= normalizer;
	vector[1] *= normalizer;
	vector[2] *= normalizer;
}
