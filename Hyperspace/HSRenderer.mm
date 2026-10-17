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
void HSRenderer::setCamera(const double modelMat[16], const double projMat[16]) {}
void HSRenderer::perspective(float fovyDegrees, float aspect, float zNear, float zFar, double outMat[16]) {}
void HSRenderer::ortho2D(float left, float right, float bottom, float top, double outMat[16]) {}
bool HSRenderer::project(double objX, double objY, double objZ,
						  const double modelMat[16], const double projMat[16], const int viewport[4],
						  double *winX, double *winY, double *winZ) { return false; }
void HSRenderer::matrixPush() {}
void HSRenderer::matrixPop() {}
void HSRenderer::loadIdentity() {}
void HSRenderer::translate(float x, float y, float z) {}
void HSRenderer::rotate(float degrees, float x, float y, float z) {}
void HSRenderer::scale(float x, float y, float z) {}
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
