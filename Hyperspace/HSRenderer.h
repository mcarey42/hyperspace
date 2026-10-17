//
//  HSRenderer.h
//  Hyperspace
//
//  Per-instance Metal 4 renderer. Replaces the OpenGL fixed-function calls the
//  engine used to make with a small immediate-mode-style C++ API, so the existing
//  C++ effect code (tunnel, goo, starBurst, flare, stretchedParticle, causticTextures)
//  can keep its draw-call structure almost unchanged.
//
//  Every HyperspaceView owns its own HSRenderer, so multiple simultaneous instances
//  (wallpaper + preview) no longer share any GPU state.
//

#ifndef HSRENDERER_H
#define HSRENDERER_H

#include <cstdint>

#ifdef __OBJC__
@class MTKView;
#else
typedef struct objc_object MTKView;
#endif

enum HSPrimitive
{
	HS_TRIANGLE_STRIP
};

enum HSPipeline
{
	HS_PIPELINE_SPRITE,	// additive textured quads: stars, flare, sun. Fogged.
	HS_PIPELINE_TUNNEL,	// two caustic textures blended by vertex alpha, fogged, overbright.
	HS_PIPELINE_GOO,		// two normal cubemaps blended by vertex alpha, reflects nebula cube, Fresnel, fogged.
	HS_PIPELINE_CAUSTIC		// offscreen: additive colored triangle strips, no texture.
};

enum HSCullMode
{
	HS_CULL_NONE,
	HS_CULL_BACK
};

typedef uint32_t HSTextureRef;	// opaque handle, 0 = invalid
const HSTextureRef HS_INVALID_TEXTURE = 0;

class HSRendererImpl;

// Owns the Metal device/queue/pipelines for one HyperspaceView instance.
class HSRenderer
{
public:
	HSRenderer();
	~HSRenderer();

	// Returns false if this Mac's GPU doesn't support Metal 4 (shouldn't happen on
	// any Apple silicon Mac, but HyperspaceView falls back to an error message if so).
	bool attachToView(MTKView *view);

	// Per-frame bracketing. beginFrame clears to black; endFrame presents.
	void beginFrame();
	void endFrame();

	// Fog applies uniformly to every pipeline's fragment shader.
	void setFog(float start, float end, bool enabled);

	// Projection matrix (column-major 4x4, OpenGL convention), separate from the
	// modelview stack below, exactly like GL's separate GL_PROJECTION register.
	void setProjectionMatrix(const double projMat[16]);
	void setProjectionMatrix(const float projMat[16]);
	static void perspective(float fovyDegrees, float aspect, float zNear, float zFar, double outMat[16]);
	static void ortho2D(float left, float right, float bottom, float top, double outMat[16]);
	// gluProject equivalent: object space -> window coordinates.
	static bool project(double objX, double objY, double objZ,
						 const double modelMat[16], const double projMat[16], const int viewport[4],
						 double *winX, double *winY, double *winZ);

	// CPU-side modelview matrix stack, the exact GL replacement: the camera is built
	// with loadIdentity/rotate/translate just like the old GL_MODELVIEW register was,
	// then getCurrentMatrix() reads it back for gluProject-style calls, and per-object
	// drawing pushes/pops on top of it precisely like the old immediate-mode code did.
	// hsVertex* transforms by (projection * stack-top) before writing into the current
	// pipeline's dynamic vertex buffer.
	void matrixPush();
	void matrixPop();
	void loadIdentity();
	void translate(float x, float y, float z);
	void rotate(float degrees, float x, float y, float z);
	void scale(float x, float y, float z);
	void multMatrixf(const float m[16]);
	void getCurrentMatrix(double out[16]) const;
	void getCurrentMatrix(float out[16]) const;

	// Immediate-mode emulation. begin/vertex*/end batches into the active pipeline's
	// per-frame dynamic vertex buffer and flushes with one draw call per end().
	void setPipeline(HSPipeline pipeline);
	void setCullMode(HSCullMode mode);
	void bindTexture(int unit, HSTextureRef texture);	// unit 0/1/2, meaning depends on pipeline
	void begin(HSPrimitive primitive);
	void color4f(float r, float g, float b, float a);
	void texCoord2f(float s, float t);
	void normal3fv(const float n[3]);
	void vertex3f(float x, float y, float z);
	void vertex3fv(const float v[3]);
	void end();

	// Indexed mesh draw for goo tiles (impSurface), bypassing the immediate-mode batcher.
	// vertices are interleaved normal(3)+position(3) floats, exactly like the old N3F_V3F VBOs.
	void drawIndexedMesh(const float *interleavedNormalPosition, uint32_t vertexCount,
						  const uint32_t *indices, uint32_t indexCount);

	// Texture creation. Data is always RGBA8, top row first.
	HSTextureRef createTexture2D(int width, int height, const uint8_t *rgba8, bool mipmapped);
	HSTextureRef createTextureCube(int size, const uint8_t *facesRGBA8[6], bool mipmapped);
	void destroyTexture(HSTextureRef texture);

	// Offscreen caustic frame rendering, replacing the old glReadPixels-from-the-visible-
	// framebuffer approach (which broke on anything smaller than the render size).
	void beginCausticFrame(int size);
	HSTextureRef endCausticFrame();	// generates mipmaps, returns the finished texture

private:
	HSRendererImpl *impl;
};

#endif
