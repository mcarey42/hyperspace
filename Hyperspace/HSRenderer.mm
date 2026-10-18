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
#import <vector>
#import <map>

// Pure anchor for +[NSBundle bundleForClass:], so the Metal library always loads from
// this .saver bundle regardless of which process (legacyScreenSaver, HyperspaceHost, the
// System Settings preview) has loaded it.
@interface HSRendererBundleAnchor : NSObject
@end
@implementation HSRendererBundleAnchor
@end

static const size_t kVertexBufferCapacity = 4 * 1024 * 1024;	// 4MB, reset every frame
static const size_t kVertexStride = sizeof(float) * 14;	// clipPosition(4) + eyePosition(3) + attrib3(3) + color(4)

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
	// Triple-buffered, matching Apple's own Metal 4 sample exactly: an MTL4CommandAllocator
	// can't be reset until the GPU has actually finished the passes it recorded (commit()
	// returning only means the CPU handed the buffer to the queue, not that the GPU is done
	// with it), so each allocator is only reused once the frame 3 iterations behind it has
	// been confirmed complete via a real GPU-signaled event, not a semaphore bumped at
	// commit time — the same margin the sample gives itself rather than the bare minimum.
	static const int kMaxFramesInFlight = 3;
	id<MTL4CommandAllocator> allocators[kMaxFramesInFlight] = {nil, nil, nil};
	id<MTLResidencySet> residencySet = nil;
	id<MTLSharedEvent> frameEvent = nil;
	uint64_t frameNumber = 0;
	// Guards against beginFrame()/endFrame() being entered twice without an intervening
	// matched pair completing. waitUntilSignaledValue:timeoutMS: below can pump the run
	// loop while it blocks, and on the main thread that can let AppKit redeliver a UI
	// event (e.g. a click) that re-enters animateOneFrame() -> beginFrame() before the
	// first call returns, which would otherwise reset impl->allocator out from under an
	// encoder that's still open.
	bool frameInProgress = false;

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

	id<MTLLibrary> library = nil;
	id<MTL4Compiler> compiler = nil;
	id<MTLRenderPipelineState> spritePSO = nil;
	id<MTLRenderPipelineState> tunnelPSO = nil;
	id<MTLRenderPipelineState> gooPSO = nil;
	id<MTLRenderPipelineState> causticPSO = nil;
	// Two samplers, selected per pipeline in end(): the original never set an explicit wrap
	// mode for 2D textures (sprite/flare, tunnel/caustic), which left them at GL's default
	// of GL_REPEAT — tunnel actually depends on that (texSpin adds a cosine offset, and the
	// fragment shader multiplies uv by (3,2), both routinely landing outside [0,1], which
	// needs to tile, not clamp). Cube maps (goo's nebula + wavy-normal textures) explicitly
	// used GL_CLAMP_TO_EDGE in the original, so they keep a separate clamped sampler.
	id<MTLSamplerState> samplerRepeat = nil;
	id<MTLSamplerState> samplerClamp = nil;
	id<MTL4ArgumentTable> argTable = nil;

	// Per-frame dynamic vertex buffer: a simple bump allocator reset every beginFrame.
	id<MTLBuffer> vertexBuffer = nil;
	size_t vertexBufferOffset = 0;

	// Fog uniforms, matching HSFogUniforms in Shaders.metal.
	id<MTLBuffer> fogBuffer = nil;

	// Texture storage.
	std::map<HSTextureRef, id<MTLTexture>> textures;
	HSTextureRef nextTextureRef = 1;

	// One-off offscreen caustic-texture generation (see beginCausticFrame/endCausticFrame).
	// Each call gets its own throwaway allocator rather than reusing impl->allocator, since
	// this always runs during initSaver() before the per-frame allocator has any work on it;
	// kept alive forever (never reset) is fine — this only happens a couple dozen times total.
	std::vector<id<MTL4CommandAllocator>> setupAllocators;
	id<MTLTexture> causticTexture = nil;
	int causticSize = 0;

	// The view's residency set at attachToView time (when the view is still 0x0, before
	// SwiftUI/AppKit ever gives it a real size) may not be the object MTKView ends up
	// actually using for its drawables once it's properly sized. Track what's currently
	// registered with the queue so beginFrame can detect and fix a swap.
	__weak id<MTLResidencySet> registeredViewResidencySet = nil;

	// Immediate-mode state.
	HSPipeline currentPipeline = HS_PIPELINE_SPRITE;
	HSCullMode currentCullMode = HS_CULL_NONE;
	HSTextureRef boundTextures[3] = {HS_INVALID_TEXTURE, HS_INVALID_TEXTURE, HS_INVALID_TEXTURE};
	float currentColor[4] = {1.0f, 1.0f, 1.0f, 1.0f};
	float currentAttrib3[3] = {0.0f, 0.0f, 0.0f};
	std::vector<float> vertexAccumulator;	// CPU staging for begin/vertex*/end

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

	id<MTL4CommandAllocator> allocators[HSRendererImpl::kMaxFramesInFlight];
	for (int i = 0; i < HSRendererImpl::kMaxFramesInFlight; ++i)
	{
		allocators[i] = [device newCommandAllocator];
		if (!allocators[i])
			return false;
	}

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
	for (int i = 0; i < HSRendererImpl::kMaxFramesInFlight; ++i)
		impl->allocators[i] = allocators[i];
	impl->residencySet = residencySet;
	impl->frameEvent = [device newSharedEvent];
	impl->frameEvent.signaledValue = 0;
	impl->frameNumber = 0;
	impl->view = mtkView;

	mtkView.device = device;
	mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
	mtkView.paused = YES;
	mtkView.enableSetNeedsDisplay = NO;
	// The view's own drawable textures need to be resident too, but mtkView.residencySet
	// isn't meaningful yet here (the view is still 0x0 at this point, before AppKit/SwiftUI
	// ever gives it a real size) — beginFrame() registers the real one once it exists.

	id<MTLLibrary> library = [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:[HSRendererBundleAnchor class]] error:&error];
	if (!library)
	{
		NSLog(@"HSRenderer: failed to load Metal library: %@", error);
		return false;
	}

	id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&error];
	if (!compiler)
	{
		NSLog(@"HSRenderer: failed to create MTL4Compiler: %@", error);
		return false;
	}

	auto makePipeline = [&](NSString *fragmentFunctionName, MTLPixelFormat colorFormat) -> id<MTLRenderPipelineState>
	{
		MTL4LibraryFunctionDescriptor *vertexFn = [MTL4LibraryFunctionDescriptor new];
		vertexFn.library = library;
		vertexFn.name = @"hsVertexMain";

		MTL4LibraryFunctionDescriptor *fragmentFn = [MTL4LibraryFunctionDescriptor new];
		fragmentFn.library = library;
		fragmentFn.name = fragmentFunctionName;

		MTL4RenderPipelineDescriptor *desc = [MTL4RenderPipelineDescriptor new];
		desc.vertexFunctionDescriptor = vertexFn;
		desc.fragmentFunctionDescriptor = fragmentFn;
		desc.colorAttachments[0].pixelFormat = colorFormat;
		desc.colorAttachments[0].blendingState = MTL4BlendStateEnabled;
		desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
		desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
		desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;

		NSError *pipelineError = nil;
		id<MTLRenderPipelineState> pso = [compiler newRenderPipelineStateWithDescriptor:desc
																	compilerTaskOptions:nil
																				   error:&pipelineError];
		if (!pso)
			NSLog(@"HSRenderer: failed to build pipeline for %@: %@", fragmentFunctionName, pipelineError);
		return pso;
	};

	id<MTLRenderPipelineState> spritePSO = makePipeline(@"hsSpriteFragment", MTLPixelFormatBGRA8Unorm);
	id<MTLRenderPipelineState> tunnelPSO = makePipeline(@"hsTunnelFragment", MTLPixelFormatBGRA8Unorm);
	id<MTLRenderPipelineState> gooPSO = makePipeline(@"hsGooFragment", MTLPixelFormatBGRA8Unorm);
	id<MTLRenderPipelineState> causticPSO = makePipeline(@"hsCausticFragment", MTLPixelFormatRGBA8Unorm);
	if (!spritePSO || !tunnelPSO || !gooPSO || !causticPSO)
		return false;

	MTLSamplerDescriptor *repeatDesc = [MTLSamplerDescriptor new];
	repeatDesc.minFilter = MTLSamplerMinMagFilterLinear;
	repeatDesc.magFilter = MTLSamplerMinMagFilterLinear;
	repeatDesc.mipFilter = MTLSamplerMipFilterLinear;
	repeatDesc.sAddressMode = MTLSamplerAddressModeRepeat;
	repeatDesc.tAddressMode = MTLSamplerAddressModeRepeat;
	repeatDesc.rAddressMode = MTLSamplerAddressModeRepeat;
	id<MTLSamplerState> samplerRepeat = [device newSamplerStateWithDescriptor:repeatDesc];

	MTLSamplerDescriptor *clampDesc = [MTLSamplerDescriptor new];
	clampDesc.minFilter = MTLSamplerMinMagFilterLinear;
	clampDesc.magFilter = MTLSamplerMinMagFilterLinear;
	clampDesc.mipFilter = MTLSamplerMipFilterLinear;
	clampDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
	clampDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
	clampDesc.rAddressMode = MTLSamplerAddressModeClampToEdge;
	id<MTLSamplerState> samplerClamp = [device newSamplerStateWithDescriptor:clampDesc];

	MTL4ArgumentTableDescriptor *argTableDesc = [MTL4ArgumentTableDescriptor new];
	argTableDesc.maxBufferBindCount = 2;
	argTableDesc.maxTextureBindCount = 3;
	argTableDesc.maxSamplerStateBindCount = 1;
	id<MTL4ArgumentTable> argTable = [device newArgumentTableWithDescriptor:argTableDesc error:&error];
	if (!argTable)
	{
		NSLog(@"HSRenderer: failed to create argument table: %@", error);
		return false;
	}
	[argTable setSamplerState:samplerRepeat.gpuResourceID atIndex:0];

	id<MTLBuffer> vertexBuffer = [device newBufferWithLength:kVertexBufferCapacity options:MTLResourceStorageModeShared];
	vertexBuffer.label = @"HSRenderer vertex ring";
	id<MTLBuffer> fogBuffer = [device newBufferWithLength:32 options:MTLResourceStorageModeShared];
	fogBuffer.label = @"HSRenderer fog uniforms";
	[residencySet addAllocation:vertexBuffer];
	[residencySet addAllocation:fogBuffer];
	[residencySet commit];

	impl->library = library;
	impl->compiler = compiler;
	impl->spritePSO = spritePSO;
	impl->tunnelPSO = tunnelPSO;
	impl->gooPSO = gooPSO;
	impl->causticPSO = causticPSO;
	impl->samplerRepeat = samplerRepeat;
	impl->samplerClamp = samplerClamp;
	impl->argTable = argTable;
	impl->vertexBuffer = vertexBuffer;
	impl->fogBuffer = fogBuffer;

	return true;
}

bool HSRenderer::beginFrame()
{
	if (impl->frameInProgress)
		return false;	// re-entrant call (see frameInProgress's comment); drop this one
	impl->frameInProgress = true;

	// Wait for the GPU to actually finish the frame kMaxFramesInFlight iterations back (not
	// just for its commit() to return) before reclaiming the allocator it used.
	impl->frameNumber++;
	id<MTL4CommandAllocator> allocator = impl->allocators[impl->frameNumber % HSRendererImpl::kMaxFramesInFlight];
	if (impl->frameNumber > HSRendererImpl::kMaxFramesInFlight)
		[impl->frameEvent waitUntilSignaledValue:impl->frameNumber - HSRendererImpl::kMaxFramesInFlight timeoutMS:1000];
	[allocator reset];

	MTKView *view = impl->view;
	// attachToView ran while the view was still 0x0 (before AppKit/SwiftUI ever gave it a
	// real size), so the residency set it registered for the view's drawables then may not
	// be the one MTKView actually vends once the view is properly sized. Catch that swap
	// here — cheap to check, and this is the only place that's guaranteed to run once the
	// view has real geometry, before any GPU work that would write to its drawable texture.
	if (view.residencySet != impl->registeredViewResidencySet)
	{
		if (view.residencySet)
			[impl->queue addResidencySet:view.residencySet];
		impl->registeredViewResidencySet = view.residencySet;
	}

	MTL4RenderPassDescriptor *passDescriptor = view.currentMTL4RenderPassDescriptor;
	impl->drawable = view.currentDrawable;
	if (!passDescriptor || !impl->drawable)
	{
		impl->frameEvent.signaledValue = impl->frameNumber;	// no GPU work this frame; keep the bookkeeping consistent
		impl->commandBuffer = nil;
		impl->encoder = nil;
		impl->frameInProgress = false;
		return false;
	}

	passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
	passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
	passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

	id<MTL4CommandBuffer> commandBuffer = [impl->device newCommandBuffer];
	[commandBuffer beginCommandBufferWithAllocator:allocator];

	impl->commandBuffer = commandBuffer;
	impl->encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
	// GL's default front face is CCW; Metal's default is CW. Match GL so "cull back face"
	// (used for the starfield and the tunnel) culls the same triangles it always did.
	[impl->encoder setFrontFacingWinding:MTLWindingCounterClockwise];
	[impl->encoder setCullMode:MTLCullModeNone];
	impl->currentCullMode = HS_CULL_NONE;
	impl->vertexBufferOffset = 0;
	return true;
}

void HSRenderer::endFrame()
{
	if (!impl->commandBuffer)
		return;

	[impl->encoder endEncoding];
	[impl->commandBuffer endCommandBuffer];

	id<CAMetalDrawable> drawable = impl->drawable;
	id<MTL4CommandBuffer> commandBuffer = impl->commandBuffer;

	[impl->queue waitForDrawable:drawable];
	__block id<MTL4CommandBuffer> retainedBuffer = commandBuffer;	// keep alive until the GPU actually runs it
	[impl->queue commit:&retainedBuffer count:1];
	[impl->queue signalDrawable:drawable];
	[drawable present];
	// Signaled once the GPU finishes this frame's passes, not merely once commit() returns
	// (commit is an async CPU-side enqueue) — the next beginFrame waits on this before it
	// resets the allocator these commands were recorded into.
	[impl->queue signalEvent:impl->frameEvent value:impl->frameNumber];

	impl->encoder = nil;
	impl->commandBuffer = nil;
	impl->drawable = nil;
	impl->frameInProgress = false;
}

// --- Everything below is wired up in later phases; stub for now. ---

// Matches HSFogUniforms in Shaders.metal: float4 color; float scale; float end; bool enabled;
void HSRenderer::setFog(float start, float end, bool enabled)
{
	struct { float color[4]; float scale; float end; uint32_t enabled; uint32_t pad; } uniforms;
	uniforms.color[0] = uniforms.color[1] = uniforms.color[2] = 0.0f;	// fog is always black in this engine
	uniforms.color[3] = 1.0f;
	uniforms.scale = (end != start) ? 1.0f / (end - start) : 0.0f;
	uniforms.end = end;
	uniforms.enabled = enabled ? 1 : 0;
	std::memcpy(impl->fogBuffer.contents, &uniforms, sizeof(uniforms));
}

void HSRenderer::setProjectionMatrix(const double projMat[16])
{
	std::memcpy(impl->projectionMatrix, projMat, sizeof(double) * 16);
}

void HSRenderer::setProjectionMatrix(const float projMat[16])
{
	for (int i = 0; i < 16; ++i)
		impl->projectionMatrix[i] = double(projMat[i]);
}

// gluPerspective's matrix construction, with the z row rederived for Metal's clip-space
// convention: GL expects clip.z/w in [-1,1] after the divide, Metal expects [0,1]. The fix
// is a standard one (new_z_row = 0.5 * (gl_z_row + gl_w_row)); baking it in here means every
// caller that builds a projection through this class gets correct near/far clipping without
// having to know Metal's convention differs from the gluPerspective formula they're ported from.
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
	outMat[10] = -double(zFar) / deltaZ;
	outMat[11] = -1.0;
	outMat[14] = -double(zFar) * double(zNear) / deltaZ;
	outMat[15] = 0.0;
}

// glOrtho, with the same GL-to-Metal z row rederivation as perspective() above.
void HSRenderer::ortho(float left, float right, float bottom, float top, float zNear, float zFar, double outMat[16])
{
	double near = double(zNear), far = double(zFar);
	hsMatIdentity(outMat);
	outMat[0] = 2.0 / (double(right) - double(left));
	outMat[5] = 2.0 / (double(top) - double(bottom));
	outMat[10] = -1.0 / (far - near);
	outMat[12] = -(double(right) + double(left)) / (double(right) - double(left));
	outMat[13] = -(double(top) + double(bottom)) / (double(top) - double(bottom));
	outMat[14] = -near / (far - near);
}

// gluOrtho2D is glOrtho with near=-1, far=1.
void HSRenderer::ortho2D(float left, float right, float bottom, float top, double outMat[16])
{
	ortho(left, right, bottom, top, -1.0f, 1.0f, outMat);
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

void HSRenderer::setPipeline(HSPipeline pipeline)
{
	impl->currentPipeline = pipeline;
}

void HSRenderer::setCullMode(HSCullMode mode)
{
	impl->currentCullMode = mode;
	if (impl->encoder)
		[impl->encoder setCullMode:(mode == HS_CULL_BACK) ? MTLCullModeBack : MTLCullModeNone];
}

void HSRenderer::bindTexture(int unit, HSTextureRef texture)
{
	if (unit >= 0 && unit < 3)
		impl->boundTextures[unit] = texture;
}

void HSRenderer::begin(HSPrimitive primitive)
{
	impl->vertexAccumulator.clear();
}

void HSRenderer::color4f(float r, float g, float b, float a)
{
	impl->currentColor[0] = r;
	impl->currentColor[1] = g;
	impl->currentColor[2] = b;
	impl->currentColor[3] = a;
}

void HSRenderer::texCoord2f(float s, float t)
{
	impl->currentAttrib3[0] = s;
	impl->currentAttrib3[1] = t;
	impl->currentAttrib3[2] = 0.0f;
}

void HSRenderer::normal3fv(const float n[3])
{
	impl->currentAttrib3[0] = n[0];
	impl->currentAttrib3[1] = n[1];
	impl->currentAttrib3[2] = n[2];
}

void HSRenderer::vertex3f(float x, float y, float z)
{
	double local[4] = {double(x), double(y), double(z), 1.0};
	double eye[4], clip[4];
	hsMatVecMul(impl->modelStack[impl->stackTop], local, eye);
	hsMatVecMul(impl->projectionMatrix, eye, clip);

	float *v = nullptr;
	size_t base = impl->vertexAccumulator.size();
	impl->vertexAccumulator.resize(base + 14);
	v = &impl->vertexAccumulator[base];
	v[0] = float(clip[0]); v[1] = float(clip[1]); v[2] = float(clip[2]); v[3] = float(clip[3]);
	v[4] = float(eye[0]); v[5] = float(eye[1]); v[6] = float(eye[2]);
	v[7] = impl->currentAttrib3[0]; v[8] = impl->currentAttrib3[1]; v[9] = impl->currentAttrib3[2];
	v[10] = impl->currentColor[0]; v[11] = impl->currentColor[1]; v[12] = impl->currentColor[2]; v[13] = impl->currentColor[3];
}

void HSRenderer::vertex3fv(const float v[3])
{
	vertex3f(v[0], v[1], v[2]);
}

void HSRenderer::end()
{
	size_t vertexCount = impl->vertexAccumulator.size() / 14;
	if (vertexCount < 3 || !impl->encoder)
		return;

	size_t byteSize = impl->vertexAccumulator.size() * sizeof(float);
	if (impl->vertexBufferOffset + byteSize > kVertexBufferCapacity)
		return;	// out of ring space for this frame; drop the draw rather than corrupt memory

	uint8_t *dest = static_cast<uint8_t *>(impl->vertexBuffer.contents) + impl->vertexBufferOffset;
	std::memcpy(dest, impl->vertexAccumulator.data(), byteSize);

	id<MTLRenderPipelineState> pso = nil;
	id<MTLSamplerState> sampler = impl->samplerRepeat;
	switch (impl->currentPipeline)
	{
		case HS_PIPELINE_SPRITE:  pso = impl->spritePSO; break;
		case HS_PIPELINE_TUNNEL:  pso = impl->tunnelPSO; break;
		case HS_PIPELINE_GOO:     pso = impl->gooPSO; sampler = impl->samplerClamp; break;
		case HS_PIPELINE_CAUSTIC: pso = impl->causticPSO; break;
	}

	[impl->argTable setAddress:(impl->vertexBuffer.gpuAddress + impl->vertexBufferOffset) atIndex:0];
	[impl->argTable setAddress:impl->fogBuffer.gpuAddress atIndex:1];
	[impl->argTable setSamplerState:sampler.gpuResourceID atIndex:0];
	for (int unit = 0; unit < 3; ++unit)
	{
		auto it = impl->textures.find(impl->boundTextures[unit]);
		id<MTLTexture> tex = (it != impl->textures.end()) ? it->second : nil;
		if (tex)
			[impl->argTable setTexture:tex.gpuResourceID atIndex:unit];
	}

	[impl->encoder setRenderPipelineState:pso];
	[impl->encoder setArgumentTable:impl->argTable atStages:MTLRenderStageVertex | MTLRenderStageFragment];
	[impl->encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:vertexCount];

	impl->vertexBufferOffset += byteSize;
	impl->vertexAccumulator.clear();
}

void HSRenderer::drawIndexedMesh(const float *interleavedNormalPosition, uint32_t vertexCount,
								  const uint32_t *indices, uint32_t indexCount) {}

HSTextureRef HSRenderer::createTexture2D(int width, int height, const uint8_t *rgba8, bool mipmapped)
{
	MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
																					 width:width
																					height:height
																				 mipmapped:mipmapped];
	desc.usage = MTLTextureUsageShaderRead;
	id<MTLTexture> texture = [impl->device newTextureWithDescriptor:desc];
	if (!texture)
		return HS_INVALID_TEXTURE;

	[texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:rgba8 bytesPerRow:width * 4];

	if (mipmapped)
	{
		// A throwaway allocator, not one of the per-frame allocators: this can be called
		// at any time (not just between beginFrame/endFrame), so it must not risk a
		// beginFrame() reset reclaiming this buffer's memory while it's still in flight.
		id<MTL4CommandAllocator> mipAllocator = [impl->device newCommandAllocator];
		impl->setupAllocators.push_back(mipAllocator);
		id<MTL4CommandBuffer> cmdBuffer = [impl->device newCommandBuffer];
		[cmdBuffer beginCommandBufferWithAllocator:mipAllocator];
		id<MTL4ComputeCommandEncoder> blit = [cmdBuffer computeCommandEncoder];
		[blit generateMipmapsForTexture:texture];
		[blit endEncoding];
		[cmdBuffer endCommandBuffer];
		id<MTL4CommandBuffer> buffers[1] = {cmdBuffer};
		[impl->queue commit:buffers count:1];
		// No CPU wait needed: subsequent frame-rendering command buffers go on this same
		// queue, so Metal guarantees this mipmap generation finishes first on the GPU.
	}

	[impl->residencySet addAllocation:texture];
	[impl->residencySet commit];

	HSTextureRef ref = impl->nextTextureRef++;
	impl->textures[ref] = texture;
	return ref;
}

HSTextureRef HSRenderer::createTextureCube(int size, const uint8_t *facesRGBA8[6], bool mipmapped) { return HS_INVALID_TEXTURE; }

void HSRenderer::destroyTexture(HSTextureRef texture)
{
	impl->textures.erase(texture);
}

// Renders directly into a mipmapped offscreen texture instead of the original's approach
// (draw to the visible framebuffer, glReadPixels into a CPU bitmap, re-upload via
// gluBuild2DMipmaps) — that approach is also what broke on preview-sized (<256px) drawables.
// Always called from initSaver(), before the main per-frame allocator/encoder are ever used,
// so it's safe to borrow impl->commandBuffer/encoder here.
void HSRenderer::beginCausticFrame(int size)
{
	MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
																					  width:size
																					 height:size
																				  mipmapped:YES];
	desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
	impl->causticTexture = [impl->device newTextureWithDescriptor:desc];
	impl->causticSize = size;

	id<MTL4CommandAllocator> allocator = [impl->device newCommandAllocator];
	impl->setupAllocators.push_back(allocator);

	MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
	pass.colorAttachments[0].texture = impl->causticTexture;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;

	id<MTL4CommandBuffer> commandBuffer = [impl->device newCommandBuffer];
	[commandBuffer beginCommandBufferWithAllocator:allocator];

	impl->commandBuffer = commandBuffer;
	impl->encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
	MTLViewport viewport = {0.0, 0.0, double(size), double(size), 0.0, 1.0};
	[impl->encoder setViewport:viewport];
	[impl->encoder setFrontFacingWinding:MTLWindingCounterClockwise];
	[impl->encoder setCullMode:MTLCullModeNone];
	impl->currentCullMode = HS_CULL_NONE;
	impl->vertexBufferOffset = 0;
}

HSTextureRef HSRenderer::endCausticFrame()
{
	[impl->encoder endEncoding];

	id<MTL4ComputeCommandEncoder> mipEncoder = [impl->commandBuffer computeCommandEncoder];
	[mipEncoder generateMipmapsForTexture:impl->causticTexture];
	[mipEncoder endEncoding];

	[impl->commandBuffer endCommandBuffer];
	id<MTL4CommandBuffer> buffers[1] = {impl->commandBuffer};
	[impl->queue commit:buffers count:1];
	// No CPU wait: the real per-frame rendering that will sample this texture doesn't start
	// until the main loop begins, well after initSaver() (and every beginCausticFrame/
	// endCausticFrame call it makes) returns, and everything commits to the same queue —
	// the same same-queue-ordering guarantee createTexture2D's mipmap generation relies on.

	[impl->residencySet addAllocation:impl->causticTexture];
	[impl->residencySet commit];

	HSTextureRef ref = impl->nextTextureRef++;
	impl->textures[ref] = impl->causticTexture;

	impl->commandBuffer = nil;
	impl->encoder = nil;
	impl->causticTexture = nil;
	return ref;
}
