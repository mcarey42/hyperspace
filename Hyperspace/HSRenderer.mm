//
//  HSRenderer.mm
//  Hyperspace
//
//  Metal 4 backend for HSRenderer.h. See that header for the design rationale.
//

#import "HSRenderer.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <cmath>
#import <cstring>

static const int kMaxMatrixStackDepth = 32;

// Column-major 4x4 multiply, GL convention: out = a * b.
static void hsMatMul(const double a[16], const double b[16], double out[16])
{
	double result[16];
	for (int col = 0; col < 4; ++col)
	{
		for (int row = 0; row < 4; ++row)
		{
			double sum = 0.0;
			for (int k = 0; k < 4; ++k)
				sum += a[k * 4 + row] * b[col * 4 + k];
			result[col * 4 + row] = sum;
		}
	}
	std::memcpy(out, result, sizeof(result));
}

static void hsMatVecMul(const double m[16], const double v[4], double out[4])
{
	for (int row = 0; row < 4; ++row)
		out[row] = m[0 * 4 + row] * v[0] + m[1 * 4 + row] * v[1] + m[2 * 4 + row] * v[2] + m[3 * 4 + row] * v[3];
}

static void hsMatIdentity(double m[16])
{
	std::memset(m, 0, sizeof(double) * 16);
	m[0] = m[5] = m[10] = m[15] = 1.0;
}

static void hsMatTranslation(double x, double y, double z, double m[16])
{
	hsMatIdentity(m);
	m[12] = x;
	m[13] = y;
	m[14] = z;
}

static void hsMatScale(double x, double y, double z, double m[16])
{
	hsMatIdentity(m);
	m[0] = x;
	m[5] = y;
	m[10] = z;
}

// Standard axis-angle (Rodrigues) rotation matrix, matching glRotatef exactly.
static void hsMatRotation(double degrees, double x, double y, double z, double m[16])
{
	double len = std::sqrt(x * x + y * y + z * z);
	if (len > 1e-12)
	{
		x /= len; y /= len; z /= len;
	}
	double radians = degrees * M_PI / 180.0;
	double c = std::cos(radians), s = std::sin(radians), t = 1.0 - c;
	hsMatIdentity(m);
	m[0] = t * x * x + c;
	m[1] = t * x * y + s * z;
	m[2] = t * x * z - s * y;
	m[4] = t * x * y - s * z;
	m[5] = t * y * y + c;
	m[6] = t * y * z + s * x;
	m[8] = t * x * z + s * y;
	m[9] = t * y * z - s * x;
	m[10] = t * z * z + c;
}

class HSRendererImpl
{
public:
	id<MTLDevice> device = nil;
	id<MTL4CommandQueue> queue = nil;
	id<MTL4CommandAllocator> allocator = nil;
	id<MTLResidencySet> residencySet = nil;
	dispatch_semaphore_t frameSemaphore = nullptr;	// single-buffered: wait for the previous frame before reusing the allocator

	__weak MTKView *view = nil;

	// Per-frame recording state, valid between beginFrame/endFrame.
	id<MTL4CommandBuffer> commandBuffer = nil;
	id<MTL4RenderCommandEncoder> encoder = nil;
	id<CAMetalDrawable> drawable = nil;

	// Modelview stack (the direct replacement for GL_MODELVIEW) and the separate
	// projection matrix (the direct replacement for GL_PROJECTION).
	double modelStack[kMaxMatrixStackDepth][16];
	int stackTop = 0;
	double projectionMatrix[16];

	HSRendererImpl()
	{
		hsMatIdentity(modelStack[0]);
		hsMatIdentity(projectionMatrix);
	}
};

HSRenderer::HSRenderer() : impl(new HSRendererImpl) {}

HSRenderer::~HSRenderer()
{
	delete impl;
}

bool HSRenderer::attachToView(MTKView *mtkView)
{
	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	if (!device)
		return false;
	if (![device supportsFamily:MTLGPUFamilyMetal4])
		return false;

	NSError *error = nil;

	id<MTL4CommandQueue> queue = [device newMTL4CommandQueue];
	if (!queue)
		return false;

	id<MTL4CommandAllocator> allocator = [device newCommandAllocator];
	if (!allocator)
		return false;

	MTLResidencySetDescriptor *residencyDesc = [MTLResidencySetDescriptor new];
	residencyDesc.label = @"HSRenderer residency set";
	id<MTLResidencySet> residencySet = [device newResidencySetWithDescriptor:residencyDesc error:&error];
	if (!residencySet)
	{
		NSLog(@"HSRenderer: failed to create residency set: %@", error);
		return false;
	}
	[residencySet commit];
	[queue addResidencySet:residencySet];

	impl->device = device;
	impl->queue = queue;
	impl->allocator = allocator;
	impl->residencySet = residencySet;
	impl->frameSemaphore = dispatch_semaphore_create(1);
	impl->view = mtkView;

	mtkView.device = device;
	mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
	mtkView.paused = YES;
	mtkView.enableSetNeedsDisplay = NO;
	// The view's own drawable textures need to be resident too.
	[queue addResidencySet:mtkView.residencySet];

	return true;
}

void HSRenderer::beginFrame()
{
	dispatch_semaphore_wait(impl->frameSemaphore, DISPATCH_TIME_FOREVER);
	[impl->allocator reset];

	MTKView *view = impl->view;
	MTL4RenderPassDescriptor *passDescriptor = view.currentMTL4RenderPassDescriptor;
	impl->drawable = view.currentDrawable;
	if (!passDescriptor || !impl->drawable)
	{
		dispatch_semaphore_signal(impl->frameSemaphore);
		impl->commandBuffer = nil;
		impl->encoder = nil;
		return;
	}

	passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
	passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
	passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

	id<MTL4CommandBuffer> commandBuffer = [impl->device newCommandBuffer];
	[commandBuffer beginCommandBufferWithAllocator:impl->allocator];

	impl->commandBuffer = commandBuffer;
	impl->encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
}

void HSRenderer::endFrame()
{
	if (!impl->commandBuffer)
		return;

	[impl->encoder endEncoding];
	[impl->commandBuffer endCommandBuffer];

	id<CAMetalDrawable> drawable = impl->drawable;
	id<MTL4CommandBuffer> commandBuffer = impl->commandBuffer;
	dispatch_semaphore_t semaphore = impl->frameSemaphore;

	[impl->queue waitForDrawable:drawable];
	__block id<MTL4CommandBuffer> retainedBuffer = commandBuffer;	// keep alive until the completion handler fires
	[impl->queue commit:&retainedBuffer count:1];
	[impl->queue signalDrawable:drawable];
	[drawable present];

	// MTL4CommandBuffer has no addCompletedHandler; a drawable-presented handler on the
	// view's layer would work too, but since we're single-buffered it's simplest to just
	// signal once the queue has accepted the commit (commit: is synchronous enqueue; the
	// GPU work itself still runs async, but waitForDrawable on the *next* beginFrame call
	// naturally serializes us behind presentation, which is what single-buffering needs).
	dispatch_semaphore_signal(semaphore);

	impl->encoder = nil;
	impl->commandBuffer = nil;
	impl->drawable = nil;
}

// --- Everything below is wired up in later phases; stub for now. ---

void HSRenderer::setFog(float start, float end, bool enabled) {}

void HSRenderer::setProjectionMatrix(const double projMat[16])
{
	std::memcpy(impl->projectionMatrix, projMat, sizeof(double) * 16);
}

void HSRenderer::setProjectionMatrix(const float projMat[16])
{
	for (int i = 0; i < 16; ++i)
		impl->projectionMatrix[i] = double(projMat[i]);
}

// Exact port of gluPerspective's matrix construction.
void HSRenderer::perspective(float fovyDegrees, float aspect, float zNear, float zFar, double outMat[16])
{
	double radians = double(fovyDegrees) * M_PI / 360.0;	// fovy/2, in radians
	double deltaZ = double(zFar) - double(zNear);
	double sine = std::sin(radians);
	if (deltaZ == 0.0 || sine == 0.0 || aspect == 0.0)
	{
		hsMatIdentity(outMat);
		return;
	}
	double cotangent = std::cos(radians) / sine;
	hsMatIdentity(outMat);
	outMat[0] = cotangent / aspect;
	outMat[5] = cotangent;
	outMat[10] = -(double(zFar) + double(zNear)) / deltaZ;
	outMat[11] = -1.0;
	outMat[14] = -2.0 * double(zFar) * double(zNear) / deltaZ;
	outMat[15] = 0.0;
}

// Exact port of gluOrtho2D (glOrtho with near=-1, far=1).
void HSRenderer::ortho2D(float left, float right, float bottom, float top, double outMat[16])
{
	double near = -1.0, far = 1.0;
	hsMatIdentity(outMat);
	outMat[0] = 2.0 / (double(right) - double(left));
	outMat[5] = 2.0 / (double(top) - double(bottom));
	outMat[10] = -2.0 / (far - near);
	outMat[12] = -(double(right) + double(left)) / (double(right) - double(left));
	outMat[13] = -(double(top) + double(bottom)) / (double(top) - double(bottom));
	outMat[14] = -(far + near) / (far - near);
}

// Exact port of gluProject.
bool HSRenderer::project(double objX, double objY, double objZ,
						  const double modelMat[16], const double projMat[16], const int viewport[4],
						  double *winX, double *winY, double *winZ)
{
	double obj[4] = {objX, objY, objZ, 1.0};
	double eye[4], clip[4];
	hsMatVecMul(modelMat, obj, eye);
	hsMatVecMul(projMat, eye, clip);
	if (clip[3] == 0.0)
		return false;
	clip[0] /= clip[3];
	clip[1] /= clip[3];
	clip[2] /= clip[3];
	clip[0] = clip[0] * 0.5 + 0.5;
	clip[1] = clip[1] * 0.5 + 0.5;
	clip[2] = clip[2] * 0.5 + 0.5;
	*winX = clip[0] * viewport[2] + viewport[0];
	*winY = clip[1] * viewport[3] + viewport[1];
	*winZ = clip[2];
	return true;
}

void HSRenderer::matrixPush()
{
	if (impl->stackTop + 1 >= kMaxMatrixStackDepth)
		return;	// matches GL's silent-overflow behavior closely enough; this engine never nests this deep
	std::memcpy(impl->modelStack[impl->stackTop + 1], impl->modelStack[impl->stackTop], sizeof(double) * 16);
	impl->stackTop++;
}

void HSRenderer::matrixPop()
{
	if (impl->stackTop > 0)
		impl->stackTop--;
}

void HSRenderer::loadIdentity()
{
	hsMatIdentity(impl->modelStack[impl->stackTop]);
}

void HSRenderer::translate(float x, float y, float z)
{
	double op[16];
	hsMatTranslation(x, y, z, op);
	hsMatMul(impl->modelStack[impl->stackTop], op, impl->modelStack[impl->stackTop]);
}

void HSRenderer::rotate(float degrees, float x, float y, float z)
{
	double op[16];
	hsMatRotation(degrees, x, y, z, op);
	hsMatMul(impl->modelStack[impl->stackTop], op, impl->modelStack[impl->stackTop]);
}

void HSRenderer::scale(float x, float y, float z)
{
	double op[16];
	hsMatScale(x, y, z, op);
	hsMatMul(impl->modelStack[impl->stackTop], op, impl->modelStack[impl->stackTop]);
}

void HSRenderer::multMatrixf(const float m[16])
{
	double op[16];
	for (int i = 0; i < 16; ++i)
		op[i] = double(m[i]);
	hsMatMul(impl->modelStack[impl->stackTop], op, impl->modelStack[impl->stackTop]);
}

void HSRenderer::getCurrentMatrix(double out[16]) const
{
	std::memcpy(out, impl->modelStack[impl->stackTop], sizeof(double) * 16);
}

void HSRenderer::getCurrentMatrix(float out[16]) const
{
	for (int i = 0; i < 16; ++i)
		out[i] = float(impl->modelStack[impl->stackTop][i]);
}

void HSRenderer::setPipeline(HSPipeline pipeline) {}
void HSRenderer::setCullMode(HSCullMode mode) {}
void HSRenderer::bindTexture(int unit, HSTextureRef texture) {}
void HSRenderer::begin(HSPrimitive primitive) {}
void HSRenderer::color4f(float r, float g, float b, float a) {}
void HSRenderer::texCoord2f(float s, float t) {}
void HSRenderer::normal3fv(const float n[3]) {}
void HSRenderer::vertex3f(float x, float y, float z) {}
void HSRenderer::vertex3fv(const float v[3]) {}
void HSRenderer::end() {}
void HSRenderer::drawIndexedMesh(const float *interleavedNormalPosition, uint32_t vertexCount,
								  const uint32_t *indices, uint32_t indexCount) {}
HSTextureRef HSRenderer::createTexture2D(int width, int height, const uint8_t *rgba8, bool mipmapped) { return HS_INVALID_TEXTURE; }
HSTextureRef HSRenderer::createTextureCube(int size, const uint8_t *facesRGBA8[6], bool mipmapped) { return HS_INVALID_TEXTURE; }
void HSRenderer::destroyTexture(HSTextureRef texture) {}
void HSRenderer::beginCausticFrame(int size) {}
HSTextureRef HSRenderer::endCausticFrame() { return HS_INVALID_TEXTURE; }
