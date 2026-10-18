#ifndef HYPERSPACE_H
#define HYPERSPACE_H

#include "HSRenderer.h"

class causticTextures;
class wavyNormalCubeMaps;
class splinePath;
class tunnel;
class goo;
class stretchedParticle;
class starBurst;

#define FLARESIZE 64

struct HyperspaceSaverSettings
{
	// Parameters edited in the dialog box
	int dSpeed;
	int dStars;
	int dStarSize;
	int dResolution;
	int dDepth;
	int dFov;
	bool dUseTunnels;
	bool dUseGoo;

	// Additional globals:
	HSRenderer *renderer;
	float frameTime;
	bool doingPreview;
	bool readyToDraw;
	// What initSaver() actually built. The configure sheet edits dStars/dUseTunnels/dUseGoo
	// before the stop/start that applies them, so cleanUp() must free what exists, not what
	// the settings say now (deleting stars[2000..2999] of a 2000-star array, say).
	int builtStars;
	bool builtTunnels, builtGoo;
	int xsize, ysize;
	float aspectRatio;
	bool first;

	float unroll;
	float billboardMat[16];
	double modelMat[16];
	double projMat[16];
	int viewport[4];

	float camPos[3]/* = {0.0f, 0.0f, 0.0f}*/;
	float depth;
	int numAnimTexFrames/* = 20*/;
	causticTextures* theCausticTextures;
	wavyNormalCubeMaps* theWNCM;
	int whichTexture/* = 0*/;
	splinePath* thePath;
	tunnel* theTunnel;
	goo* theGoo;
	HSTextureRef nebulatex;

	stretchedParticle** stars;
	stretchedParticle* sunStar;
	starBurst* theStarBurst;

	unsigned char flare1[FLARESIZE][FLARESIZE][4];
	unsigned char flare2[FLARESIZE][FLARESIZE][4];
	unsigned char flare3[FLARESIZE][FLARESIZE][4];
	unsigned char flare4[FLARESIZE][FLARESIZE][4];
	HSTextureRef flaretex[4];
};

__private_extern__ void draw(HyperspaceSaverSettings *inSettings);
__private_extern__ void reshape(int width, int height, HyperspaceSaverSettings *inSettings);
__private_extern__ void initSaver(HyperspaceSaverSettings *inSettings);
__private_extern__ void cleanUp(HyperspaceSaverSettings *inSettings);
__private_extern__ void setDefaults(HyperspaceSaverSettings *inSettings);

#endif
