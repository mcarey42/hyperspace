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

#ifdef WIN32
#include <windows.h>
#include <rsWin32Saver/rsWin32Saver.h>
#include <regstr.h>
#include <commctrl.h>
#include <resource.h>
#include <Hyperspace/extensions.h>
#endif
#ifdef RS_XSCREENSAVER
#include <rsXScreenSaver/rsXScreenSaver.h>
#endif

#include <stdio.h>
#include <rsText/rsText.h>
#include <math.h>
#include <time.h>
#include <OpenGL/gl.h>
#include <OpenGL/glu.h>
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
#include <Hyperspace/shaders.h>
#include "Hyperspace.h"
#include "HSRenderer.h"

//#include <fstream>
//std::ofstream outfile;


/*#ifdef WIN32
LPCTSTR registryPath = ("Software\\Really Slick\\Hyperspace");
HGLRC hglrc;
HDC hdc;
#endif
int readyToDraw = 0;
int xsize, ysize;
float aspectRatio;
float frameTime = 0.0f;
// text output
rsText* textwriter;
// Parameters edited in the dialog box
int dSpeed;
int dStars;
int dStarSize;
int dResolution;
int dDepth;
int dFov;
int dUseTunnels;
int dUseGoo;
int dShaders;


float unroll;
float billboardMat[16];
double modelMat[16];
double projMat[16];
int viewport[4];

float camPos[3] = {0.0f, 0.0f, 0.0f};
float depth;
int numAnimTexFrames = 20;
causticTextures* theCausticTextures;
wavyNormalCubeMaps* theWNCM; 
int whichTexture = 0;
splinePath* thePath;
tunnel* theTunnel;
goo* theGoo;
unsigned int speckletex, spheretex, nebulatex;
unsigned int goo_vp, goo_fp, tunnel_vp, tunnel_fp;

stretchedParticle** stars;
stretchedParticle* sunStar;
starBurst* theStarBurst;
*/


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

	// TODO(Phase 2.5): goo update.

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
	(void)lerp;	// used by goo once it lands in Phase 2.5

	// TODO(Phase 2.5): starburst.

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


/*void IdleProc(){
	// update time
	static rsTimer timer;
	frameTime = timer.tick();

	if(readyToDraw && !isSuspended && !checkingPassword)
		draw();
}*/


void setDefaults(HyperspaceSaverSettings *inSettings){
	inSettings->dSpeed = 10;
	inSettings->dStars = 2000;
	inSettings->dStarSize = 10;
	inSettings->dResolution = 10;
	inSettings->dDepth = 5;
	inSettings->dFov = 50;
	inSettings->dUseTunnels = 1;
	inSettings->dUseGoo = 1;
	inSettings->dShaders = 1;
}


#ifdef RS_XSCREENSAVER
void handleCommandLine(int argc, char* argv[]){
	setDefaults();
	getArgumentsValue(argc, argv, std::string("-speed"), dSpeed, 1, 100);
	getArgumentsValue(argc, argv, std::string("-stars"), dStars, 0, 10000);
	getArgumentsValue(argc, argv, std::string("-starsize"), dStarSize, 1, 100);
	getArgumentsValue(argc, argv, std::string("-resolution"), dResolution, 4, 20);
	getArgumentsValue(argc, argv, std::string("-depth"), dDepth, 1, 10);
	getArgumentsValue(argc, argv, std::string("-fov"), dFov, 10, 150);
	getArgumentsValue(argc, argv, std::string("-usetunnels"), dUseTunnels, 0, 1);
	getArgumentsValue(argc, argv, std::string("-usegoo"), dUseGoo, 0, 1);
	getArgumentsValue(argc, argv, std::string("-shaders"), dShaders, 0, 1);
}
#endif


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


#ifdef WIN32
void initSaver(HWND hwnd){
	RECT rect;

	// Window initialization
	hdc = GetDC(hwnd);
	setBestPixelFormat(hdc);
	hglrc = wglCreateContext(hdc);
	GetClientRect(hwnd, &rect);
	wglMakeCurrent(hdc, hglrc);
	
	// setup viewport
	//viewport[0] = rect.left;
	//viewport[1] = rect.top;
	//viewport[2] = rect.right - rect.left;
	//viewport[3] = rect.bottom - rect.top;

	// initialize extensions
	if(!initExtensions())
		dShaders = 0;

	reshape(rect.right, rect.bottom);
#endif
//#ifdef RS_XSCREENSAVER
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

	// TODO(Phase 2.5): goo.

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

	// TODO(Phase 2.5): starburst, nebula cube map.

	inSettings->renderer->setFog(inSettings->depth * 0.7f, inSettings->depth, true);

	inSettings->readyToDraw = 1;
}


void cleanUp(HyperspaceSaverSettings *inSettings){
	// TODO(Phase 2.5): free goo/starburst/nebula once they're allocated again.
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
	delete inSettings->thePath;
	inSettings->first = 1;
}
//#endif


/*#ifdef WIN32
void cleanUp(HWND hwnd){
	// Free memory
	if(dUseGoo)
		delete theGoo;
	if(dUseTunnels){
		delete theTunnel;
		delete theCausticTextures;
	}
	delete thePath;
	delete theWNCM;

	// Kill device context
	ReleaseDC(hwnd, hdc);
	wglMakeCurrent(NULL, NULL);
	wglDeleteContext(hglrc);
}


// Initialize all user-defined stuff
void readRegistry(){
	LONG result;
	HKEY skey;
	DWORD valtype, valsize, val;

	setDefaults();

	result = RegOpenKeyEx(HKEY_CURRENT_USER, registryPath, 0, KEY_READ, &skey);
	if(result != ERROR_SUCCESS)
		return;

	valsize=sizeof(val);

	result = RegQueryValueEx(skey, "Speed", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dSpeed = val;
	result = RegQueryValueEx(skey, "Stars", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dStars = val;
	result = RegQueryValueEx(skey, "StarSize", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dStarSize = val;
	result = RegQueryValueEx(skey, "Resolution", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dResolution = val;
	result = RegQueryValueEx(skey, "Depth", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dDepth = val;
	result = RegQueryValueEx(skey, "Fov", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dFov = val;
	result = RegQueryValueEx(skey, "UseTunnels", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dUseTunnels = val;
	result = RegQueryValueEx(skey, "UseGoo", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dUseGoo = val;
	result = RegQueryValueEx(skey, "Shaders", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dShaders = val;
	result = RegQueryValueEx(skey, "FrameRateLimit", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dFrameRateLimit = val;

	RegCloseKey(skey);
}


// Save all user-defined stuff
void writeRegistry(){
    LONG result;
	HKEY skey;
	DWORD val, disp;

	result = RegCreateKeyEx(HKEY_CURRENT_USER, registryPath, 0, NULL, REG_OPTION_NON_VOLATILE, KEY_WRITE, NULL, &skey, &disp);
	if(result != ERROR_SUCCESS)
		return;

	val = dSpeed;
	RegSetValueEx(skey, "Speed", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dStars;
	RegSetValueEx(skey, "Stars", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dStarSize;
	RegSetValueEx(skey, "StarSize", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dResolution;
	RegSetValueEx(skey, "Resolution", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dDepth;
	RegSetValueEx(skey, "Depth", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dFov;
	RegSetValueEx(skey, "Fov", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dUseTunnels;
	RegSetValueEx(skey, "UseTunnels", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dUseGoo;
	RegSetValueEx(skey, "UseGoo", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dShaders;
	RegSetValueEx(skey, "Shaders", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dFrameRateLimit;
	RegSetValueEx(skey, "FrameRateLimit", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));

	RegCloseKey(skey);
}


BOOL aboutProc(HWND hdlg, UINT msg, WPARAM wpm, LPARAM lpm){
	switch(msg){
	case WM_CTLCOLORSTATIC:
		if(HWND(lpm) == GetDlgItem(hdlg, WEBPAGE)){
			SetTextColor(HDC(wpm), RGB(0,0,255));
			SetBkColor(HDC(wpm), COLORREF(GetSysColor(COLOR_3DFACE)));
			return(int(GetSysColorBrush(COLOR_3DFACE)));
		}
		break;
    case WM_COMMAND:
		switch(LOWORD(wpm)){
		case IDOK:
		case IDCANCEL:
			EndDialog(hdlg, LOWORD(wpm));
			break;
		case WEBPAGE:
			ShellExecute(NULL, "open", "http://www.reallyslick.com/", NULL, NULL, SW_SHOWNORMAL);
		}
	}
	return FALSE;
}


void initControls(HWND hdlg){
	char cval[16];

	CheckDlgButton(hdlg, USETUNNELS, dUseTunnels);
	CheckDlgButton(hdlg, USEGOO, dUseGoo);
	CheckDlgButton(hdlg, USESHADERS, dShaders);

	SendDlgItemMessage(hdlg, SPEED, TBM_SETRANGE, 0, LPARAM(MAKELONG(DWORD(1), DWORD(100))));
	SendDlgItemMessage(hdlg, SPEED, TBM_SETPOS, 1, LPARAM(dSpeed));
	SendDlgItemMessage(hdlg, SPEED, TBM_SETLINESIZE, 0, LPARAM(1));
	SendDlgItemMessage(hdlg, SPEED, TBM_SETPAGESIZE, 0, LPARAM(5));
	sprintf(cval, "%d", dSpeed);
	SendDlgItemMessage(hdlg, SPEEDTEXT, WM_SETTEXT, 0, LPARAM(cval));

	SendDlgItemMessage(hdlg, STARS, TBM_SETRANGE, 0, LPARAM(MAKELONG(DWORD(0), DWORD(10000))));
	SendDlgItemMessage(hdlg, STARS, TBM_SETPOS, 1, LPARAM(dStars));
	SendDlgItemMessage(hdlg, STARS, TBM_SETLINESIZE, 0, LPARAM(1));
	SendDlgItemMessage(hdlg, STARS, TBM_SETPAGESIZE, 0, LPARAM(50));
	sprintf(cval, "%d", dStars);
	SendDlgItemMessage(hdlg, STARSTEXT, WM_SETTEXT, 0, LPARAM(cval));
	
	SendDlgItemMessage(hdlg, STARSIZE, TBM_SETRANGE, 0, LPARAM(MAKELONG(DWORD(1), DWORD(100))));
	SendDlgItemMessage(hdlg, STARSIZE, TBM_SETPOS, 1, LPARAM(dStarSize));
	SendDlgItemMessage(hdlg, STARSIZE, TBM_SETLINESIZE, 0, LPARAM(1));
	SendDlgItemMessage(hdlg, STARSIZE, TBM_SETPAGESIZE, 0, LPARAM(5));
	sprintf(cval, "%d", dStarSize);
	SendDlgItemMessage(hdlg, STARSIZETEXT, WM_SETTEXT, 0, LPARAM(cval));
	
	SendDlgItemMessage(hdlg, RESOLUTION, TBM_SETRANGE, 0, LPARAM(MAKELONG(DWORD(4), DWORD(20))));
	SendDlgItemMessage(hdlg, RESOLUTION, TBM_SETPOS, 1, LPARAM(dResolution));
	SendDlgItemMessage(hdlg, RESOLUTION, TBM_SETLINESIZE, 0, LPARAM(1));
	SendDlgItemMessage(hdlg, RESOLUTION, TBM_SETPAGESIZE, 0, LPARAM(2));
	if(dUseGoo)
		EnableWindow(GetDlgItem(hdlg, RESOLUTION), TRUE);
	else
		EnableWindow(GetDlgItem(hdlg, RESOLUTION), FALSE);
	sprintf(cval, "%d", dResolution);
	SendDlgItemMessage(hdlg, RESOLUTIONTEXT, WM_SETTEXT, 0, LPARAM(cval));

	SendDlgItemMessage(hdlg, DEPTH, TBM_SETRANGE, 0, LPARAM(MAKELONG(DWORD(1), DWORD(10))));
	SendDlgItemMessage(hdlg, DEPTH, TBM_SETPOS, 1, LPARAM(dDepth));
	SendDlgItemMessage(hdlg, DEPTH, TBM_SETLINESIZE, 0, LPARAM(1));
	SendDlgItemMessage(hdlg, DEPTH, TBM_SETPAGESIZE, 0, LPARAM(2));
	sprintf(cval, "%d", dDepth);
	SendDlgItemMessage(hdlg, DEPTHTEXT, WM_SETTEXT, 0, LPARAM(cval));

	SendDlgItemMessage(hdlg, FOV, TBM_SETRANGE, 0, LPARAM(MAKELONG(DWORD(10), DWORD(150))));
	SendDlgItemMessage(hdlg, FOV, TBM_SETPOS, 1, LPARAM(dFov));
	SendDlgItemMessage(hdlg, FOV, TBM_SETLINESIZE, 0, LPARAM(1));
	SendDlgItemMessage(hdlg, FOV, TBM_SETPAGESIZE, 0, LPARAM(5));
	sprintf(cval, "%d", dFov);
	SendDlgItemMessage(hdlg, FOVTEXT, WM_SETTEXT, 0, LPARAM(cval));

	initFrameRateLimitSlider(hdlg, FRAMERATELIMIT, FRAMERATELIMITTEXT);
}


BOOL screenSaverConfigureDialog(HWND hdlg, UINT msg, WPARAM wpm, LPARAM lpm){
	int ival;
	char cval[16];

    switch(msg){
    case WM_INITDIALOG:
        InitCommonControls();
        readRegistry();
        initControls(hdlg);
        return TRUE;
    case WM_COMMAND:
        switch(LOWORD(wpm)){
        case IDOK:
			dSpeed = SendDlgItemMessage(hdlg, SPEED, TBM_GETPOS, 0, 0);
			dStars = SendDlgItemMessage(hdlg, STARS, TBM_GETPOS, 0, 0);
			dStarSize = SendDlgItemMessage(hdlg, STARSIZE, TBM_GETPOS, 0, 0);
			dResolution = SendDlgItemMessage(hdlg, RESOLUTION, TBM_GETPOS, 0, 0);
			dDepth = SendDlgItemMessage(hdlg, DEPTH, TBM_GETPOS, 0, 0);
			dFov = SendDlgItemMessage(hdlg, FOV, TBM_GETPOS, 0, 0);
			dUseTunnels = (IsDlgButtonChecked(hdlg, USETUNNELS) == BST_CHECKED);
			dUseGoo = (IsDlgButtonChecked(hdlg, USEGOO) == BST_CHECKED);
			dShaders = (IsDlgButtonChecked(hdlg, USESHADERS) == BST_CHECKED);
			dFrameRateLimit = SendDlgItemMessage(hdlg, FRAMERATELIMIT, TBM_GETPOS, 0, 0);
			writeRegistry();
            // Fall through
        case IDCANCEL:
            EndDialog(hdlg, LOWORD(wpm));
            break;
		case DEFAULTS:
			setDefaults();
			initControls(hdlg);
			break;
		case ABOUT:
			DialogBox(mainInstance, MAKEINTRESOURCE(DLG_ABOUT), hdlg, DLGPROC(aboutProc));
			break;
		case USEGOO:
			if(IsDlgButtonChecked(hdlg, USEGOO) == BST_CHECKED)
				EnableWindow(GetDlgItem(hdlg, RESOLUTION), TRUE);
			else
				EnableWindow(GetDlgItem(hdlg, RESOLUTION), FALSE);
			break;
		}
        return TRUE;
	case WM_HSCROLL:
		if(HWND(lpm) == GetDlgItem(hdlg, SPEED)){
			ival = SendDlgItemMessage(hdlg, SPEED, TBM_GETPOS, 0, 0);
			sprintf(cval, "%d", ival);
			SendDlgItemMessage(hdlg, SPEEDTEXT, WM_SETTEXT, 0, LPARAM(cval));
		}
		if(HWND(lpm) == GetDlgItem(hdlg, STARS)){
			ival = SendDlgItemMessage(hdlg, STARS, TBM_GETPOS, 0, 0);
			sprintf(cval, "%d", ival);
			SendDlgItemMessage(hdlg, STARSTEXT, WM_SETTEXT, 0, LPARAM(cval));
		}
		if(HWND(lpm) == GetDlgItem(hdlg, STARSIZE)){
			ival = SendDlgItemMessage(hdlg, STARSIZE, TBM_GETPOS, 0, 0);
			sprintf(cval, "%d", ival);
			SendDlgItemMessage(hdlg, STARSIZETEXT, WM_SETTEXT, 0, LPARAM(cval));
		}
		if(HWND(lpm) == GetDlgItem(hdlg, RESOLUTION)){
			ival = SendDlgItemMessage(hdlg, RESOLUTION, TBM_GETPOS, 0, 0);
			sprintf(cval, "%d", ival);
			SendDlgItemMessage(hdlg, RESOLUTIONTEXT, WM_SETTEXT, 0, LPARAM(cval));
		}
		if(HWND(lpm) == GetDlgItem(hdlg, DEPTH)){
			ival = SendDlgItemMessage(hdlg, DEPTH, TBM_GETPOS, 0, 0);
			sprintf(cval, "%d", ival);
			SendDlgItemMessage(hdlg, DEPTHTEXT, WM_SETTEXT, 0, LPARAM(cval));
		}
		if(HWND(lpm) == GetDlgItem(hdlg, FOV)){
			ival = SendDlgItemMessage(hdlg, FOV, TBM_GETPOS, 0, 0);
			sprintf(cval, "%d", ival);
			SendDlgItemMessage(hdlg, FOVTEXT, WM_SETTEXT, 0, LPARAM(cval));
		}
		if(HWND(lpm) == GetDlgItem(hdlg, FRAMERATELIMIT))
			updateFrameRateLimitSlider(hdlg, FRAMERATELIMIT, FRAMERATELIMITTEXT);
		return TRUE;
    }
    return FALSE;
}


LONG screenSaverProc(HWND hwnd, UINT msg, WPARAM wpm, LPARAM lpm){
	switch(msg){
	case WM_CREATE:
		readRegistry();
		initSaver(hwnd);
		break;
	case WM_DESTROY:
		readyToDraw = 0;
		cleanUp(hwnd);
		break;
	}
	return defScreenSaverProc(hwnd, msg, wpm, lpm);
}
#endif
 */
