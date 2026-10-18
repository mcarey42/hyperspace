//
//  HSRenderer.mm
//  Hyperspace
//
//  Metal 4 backend for HSRenderer.h. See that header for the design rationale.
//

#import "HSRenderer.h"
#import "HSLog.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <cmath>
#import <cstring>
#import <vector>
#import <map>
#import <utility>
#import <atomic>
#import <memory>

// Pure anchor for +[NSBundle bundleForClass:], so the Metal library always loads from
// this .saver bundle regardless of which process (legacyScreenSaver, HyperspaceHost, the
// System Settings preview) has loaded it.
@interface HSRendererBundleAnchor : NSObject
@end
@implementation HSRendererBundleAnchor
@end

// 16MB, reset every frame. Was 4MB, sized for the pre-batching code path where each strip's
// vertices went straight to the GPU in native MTLPrimitiveTypeTriangleStrip form. Batching
// submissions into single draw calls requires expanding each strip to an independent triangle
// list (triangle k of an N-vertex strip becomes 3 vertices instead of sharing N total), which
// multiplies a long strip's footprint by nearly 3x — e.g. the tunnel's 42-vertex rings become
// 120 vertices each. At default settings (2000 stars, tunnels+goo on) that pushed total
// per-frame usage over 4MB, silently dropping whatever didn't fit — observed as the tunnel
// disappearing entirely, since it's encoded after stars/goo in the frame.
static const size_t kVertexBufferCapacity = 16 * 1024 * 1024;
static const size_t kIndexBufferCapacity = 2 * 1024 * 1024;	// goo/starburst indices; smaller margin is fine since these aren't strip-expanded
// Fog uniforms are written once per batch that follows a setFog() change, into a small
// per-frame-slot buffer; 256-byte stride keeps every binding comfortably aligned. A frame
// only changes fog a couple of times, so 256 entries is a wide margin.
static const size_t kFogUniformStride = 256;
static const size_t kFogBufferCapacity = 256 * kFogUniformStride;
// Every vertex is 14 floats: clipPosition(4) + eyePosition(3) + attrib3(3) + color(4).

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

// Counters touched from Metal's commit-feedback threads, so they live in a shared_ptr the
// feedback blocks retain rather than in HSRendererImpl (which may be deleted first).
struct HSAtomicStats
{
	std::atomic<uint64_t> gpuCompleted{0};
	std::atomic<uint64_t> gpuErrors{0};
};

class HSRendererImpl
{
public:
	uint32_t logTag = 0;
	HSFrameStats stats;
	std::shared_ptr<HSAtomicStats> gpuStats = std::make_shared<HSAtomicStats>();
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

	// Per-frame dynamic vertex buffers: a simple bump allocator reset every beginFrame, one
	// buffer per frame-in-flight slot (indexed the same way as allocators[]), matching Apple's
	// own Metal 4 samples. A single shared buffer rewound every frame let the CPU overwrite
	// vertex data that up to kMaxFramesInFlight - 1 earlier frames were still reading on the
	// GPU; a slot's buffer is only rewound after the same frameEvent wait that frees its
	// allocator.
	id<MTLBuffer> frameVertexBuffers[kMaxFramesInFlight] = {nil, nil, nil};

	// Same bump-allocator scheme, for drawIndexedMesh's index data (goo's marching-cubes
	// tiles, and later the starburst sphere).
	id<MTLBuffer> frameIndexBuffers[kMaxFramesInFlight] = {nil, nil, nil};

	// Whichever buffers the current beginFrame/endFrame (or beginCausticFrame/endCausticFrame)
	// pair is bump-allocating from. currentIndexBuffer is nil during caustic frames, which
	// only ever draw non-indexed strips.
	id<MTLBuffer> currentVertexBuffer = nil;
	size_t vertexBufferOffset = 0;
	id<MTLBuffer> currentIndexBuffer = nil;
	size_t indexBufferOffset = 0;

	// Fog uniforms, matching HSFogUniforms in Shaders.metal. setFog() used to memcpy straight
	// into one shared buffer, but draws only read it once the GPU runs the committed frame, so
	// every draw in a frame saw whatever setFog() wrote last (the sun and flare, meant to be
	// unfogged, were fogged), and the CPU overwrote it while earlier frames could still be
	// reading it. Now setFog() only updates fogUniforms; each batch flush writes the current
	// value into this frame slot's frameFogBuffers[] entry (see hsCurrentFogAddress).
	struct FogUniforms { float color[4]; float scale; float end; uint32_t enabled; uint32_t pad; };
	FogUniforms fogUniforms = {{0.0f, 0.0f, 0.0f, 1.0f}, 0.0f, 0.0f, 0, 0};
	bool fogDirty = true;
	id<MTLBuffer> frameFogBuffers[kMaxFramesInFlight] = {nil, nil, nil};
	id<MTLBuffer> currentFogBuffer = nil;	// nil outside beginFrame/endFrame
	size_t fogBufferOffset = 0;
	uint64_t currentFogAddress = 0;
	// Fog-disabled uniforms written once in attachToView and never touched again, bound by
	// caustic setup frames (whose shader ignores fog) so they never share frame memory.
	id<MTLBuffer> fogBuffer = nil;

	// Texture storage.
	std::map<HSTextureRef, id<MTLTexture>> textures;
	// MTL4 command buffers don't retain the resources they use, so a texture destroyed by
	// cleanUp() (stopAnimation) may still be sampled by up to kMaxFramesInFlight frames, or by
	// setup work, already committed. destroyTexture() parks it here with the frame and setup
	// values it must outlive; hsReleaseRetiredResources() drops it (and its residency) after.
	struct RetiredTexture
	{
		id<MTLTexture> texture;
		uint64_t afterFrame;
		uint64_t afterSetup;
	};
	std::vector<RetiredTexture> retiredTextures;
	HSTextureRef nextTextureRef = 1;

	// One-off offscreen caustic-texture generation (see beginCausticFrame/endCausticFrame).
	// Each call gets its own throwaway allocator rather than reusing impl->allocator, since
	// this always runs during initSaver() before the per-frame allocator has any work on it;
	// kept alive forever (never reset) is fine — this only happens a couple dozen times total.
	std::vector<id<MTL4CommandAllocator>> setupAllocators;
	// Vertex buffers for caustic frames, kept apart from frameVertexBuffers[] so setup work
	// never shares memory with frames that may still be in flight (initSaver() can run again
	// after a stop/start while earlier frames are on the GPU). Each caustic frame is ~14.5MB
	// of strip-expanded geometry and initSaver() commits several of them back to back
	// without a CPU wait (see hsCommitSetupSubmission), so they can't share one rewound
	// buffer either: each buffer is tagged with the setupEvent value of the submission that
	// last read it, and is only reused once the GPU has signaled past that value. The pool
	// is released once all setup work has completed (see hsReleaseIdleSetupBuffers).
	struct SetupVertexBuffer
	{
		id<MTLBuffer> buffer;
		uint64_t lastUseSetupValue;
	};
	std::vector<SetupVertexBuffer> setupVertexBuffers;
	size_t currentSetupVertexBuffer = 0;
	id<MTLTexture> causticTexture = nil;
	int causticSize = 0;
	// Signaled (cheaply, GPU-side, no CPU wait) after every one-off setup submission;
	// waitForSetupCompletion() schedules one GPU-side queue wait for the highest value
	// signaled so far, once all setup work has been issued. See that method's header comment.
	id<MTLSharedEvent> setupEvent = nil;
	uint64_t setupEventValue = 0;

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

	// Deferred batching: GL's immediate mode let the driver coalesce thousands of tiny
	// glBegin/glEnd draws for you; Metal has no such thing, and one drawPrimitives call per
	// quad (e.g. one per star) measured at ~4265 draws/frame, which is what was capping frame
	// rate well below 60fps. Consecutive end()/drawIndexedMesh() submissions that share the
	// same pipeline/cullMode/textures now accumulate into one contiguous buffer range and
	// flush as a single draw call, only flushing early when that state actually changes.
	struct BatchKey
	{
		HSPipeline pipeline = HS_PIPELINE_SPRITE;
		HSCullMode cullMode = HS_CULL_NONE;
		HSTextureRef textures[3] = {HS_INVALID_TEXTURE, HS_INVALID_TEXTURE, HS_INVALID_TEXTURE};
		bool operator==(const BatchKey &o) const
		{
			return pipeline == o.pipeline && cullMode == o.cullMode
				&& textures[0] == o.textures[0] && textures[1] == o.textures[1] && textures[2] == o.textures[2];
		}
	};
	// Non-indexed (sprite/tunnel/caustic): strips are expanded to independent triangles so
	// they concatenate; drawn with one drawPrimitives call per flush.
	bool hasPendingSpriteBatch = false;
	BatchKey pendingSpriteKey;
	size_t pendingSpriteStartOffset = 0;
	uint32_t pendingSpriteVertexCount = 0;
	// Indexed (goo tiles, starburst sphere): already independent triangles via indices, so
	// batches just need each submission's indices rebased onto the shared vertex range.
	bool hasPendingMeshBatch = false;
	BatchKey pendingMeshKey;
	size_t pendingMeshVertexStartOffset = 0;
	size_t pendingMeshIndexStartOffset = 0;
	uint32_t pendingMeshVertexCount = 0;
	uint32_t pendingMeshIndexCount = 0;

	HSRendererImpl()
	{
		hsMatIdentity(modelStack[0]);
		hsMatIdentity(projectionMatrix);
	}
};

// GPU address of fog uniforms matching the fog state at the time this batch was queued.
// setFog() flushes pending batches before changing fogUniforms, so "current" is right here.
static uint64_t hsCurrentFogAddress(HSRendererImpl *impl)
{
	if (!impl->currentFogBuffer)
		return impl->fogBuffer.gpuAddress;
	if (impl->fogDirty || impl->currentFogAddress == 0)
	{
		if (impl->fogBufferOffset + kFogUniformStride <= kFogBufferCapacity)
		{
			std::memcpy(static_cast<uint8_t *>(impl->currentFogBuffer.contents) + impl->fogBufferOffset,
						&impl->fogUniforms, sizeof(impl->fogUniforms));
			impl->currentFogAddress = impl->currentFogBuffer.gpuAddress + impl->fogBufferOffset;
			impl->fogBufferOffset += kFogUniformStride;
		}
		// else: out of entries this frame; keep the last one rather than overrun
		impl->fogDirty = false;
	}
	return impl->currentFogAddress;
}

// Issues the deferred draw call for whatever non-indexed (sprite/tunnel/caustic) geometry has
// accumulated since the last flush, using the state captured in pendingSpriteKey — not whatever
// impl->currentPipeline/currentCullMode/boundTextures happen to be *now*, since those may have
// already moved on to the next batch by the time this flush actually runs.
static void hsFlushSpriteBatch(HSRendererImpl *impl)
{
	if (!impl->hasPendingSpriteBatch || impl->pendingSpriteVertexCount == 0)
	{
		impl->hasPendingSpriteBatch = false;
		impl->pendingSpriteVertexCount = 0;
		return;
	}

	id<MTLRenderPipelineState> pso = nil;
	id<MTLSamplerState> sampler = impl->samplerRepeat;
	switch (impl->pendingSpriteKey.pipeline)
	{
		case HS_PIPELINE_SPRITE:  pso = impl->spritePSO; break;
		case HS_PIPELINE_TUNNEL:  pso = impl->tunnelPSO; break;
		case HS_PIPELINE_GOO:     pso = impl->gooPSO; sampler = impl->samplerClamp; break;
		case HS_PIPELINE_CAUSTIC: pso = impl->causticPSO; break;
	}

	[impl->argTable setAddress:(impl->currentVertexBuffer.gpuAddress + impl->pendingSpriteStartOffset) atIndex:0];
	[impl->argTable setAddress:hsCurrentFogAddress(impl) atIndex:1];
	[impl->argTable setSamplerState:sampler.gpuResourceID atIndex:0];
	for (int unit = 0; unit < 3; ++unit)
	{
		auto it = impl->textures.find(impl->pendingSpriteKey.textures[unit]);
		id<MTLTexture> tex = (it != impl->textures.end()) ? it->second : nil;
		if (tex)
			[impl->argTable setTexture:tex.gpuResourceID atIndex:unit];
	}

	[impl->encoder setCullMode:(impl->pendingSpriteKey.cullMode == HS_CULL_BACK) ? MTLCullModeBack : MTLCullModeNone];
	[impl->encoder setRenderPipelineState:pso];
	[impl->encoder setArgumentTable:impl->argTable atStages:MTLRenderStageVertex | MTLRenderStageFragment];
	[impl->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:impl->pendingSpriteVertexCount];

	impl->hasPendingSpriteBatch = false;
	impl->pendingSpriteVertexCount = 0;
}

// Same idea as hsFlushSpriteBatch, for the indexed (goo tiles / starburst sphere) path.
static void hsFlushMeshBatch(HSRendererImpl *impl)
{
	if (!impl->hasPendingMeshBatch || impl->pendingMeshIndexCount == 0)
	{
		impl->hasPendingMeshBatch = false;
		impl->pendingMeshIndexCount = 0;
		impl->pendingMeshVertexCount = 0;
		return;
	}

	[impl->argTable setAddress:(impl->currentVertexBuffer.gpuAddress + impl->pendingMeshVertexStartOffset) atIndex:0];
	[impl->argTable setAddress:hsCurrentFogAddress(impl) atIndex:1];
	[impl->argTable setSamplerState:impl->samplerClamp.gpuResourceID atIndex:0];
	for (int unit = 0; unit < 3; ++unit)
	{
		auto it = impl->textures.find(impl->pendingMeshKey.textures[unit]);
		id<MTLTexture> tex = (it != impl->textures.end()) ? it->second : nil;
		if (tex)
			[impl->argTable setTexture:tex.gpuResourceID atIndex:unit];
	}

	[impl->encoder setCullMode:(impl->pendingMeshKey.cullMode == HS_CULL_BACK) ? MTLCullModeBack : MTLCullModeNone];
	[impl->encoder setRenderPipelineState:impl->gooPSO];
	[impl->encoder setArgumentTable:impl->argTable atStages:MTLRenderStageVertex | MTLRenderStageFragment];
	[impl->encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
								indexCount:impl->pendingMeshIndexCount
								 indexType:MTLIndexTypeUInt32
							   indexBuffer:(impl->currentIndexBuffer.gpuAddress + impl->pendingMeshIndexStartOffset)
							 indexBufferLength:impl->pendingMeshIndexCount * sizeof(uint32_t)];

	impl->hasPendingMeshBatch = false;
	impl->pendingMeshIndexCount = 0;
	impl->pendingMeshVertexCount = 0;
}

// Commit options whose feedback handler counts GPU completions and logs GPU-side errors,
// which are otherwise completely silent with MTL4CommandQueue.
static MTL4CommitOptions *hsCommitOptions(HSRendererImpl *impl, const char *what)
{
	std::shared_ptr<HSAtomicStats> gpuStats = impl->gpuStats;
	uint32_t tag = impl->logTag;
	MTL4CommitOptions *options = [MTL4CommitOptions new];
	[options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
		gpuStats->gpuCompleted++;
		if (feedback.error)
		{
			uint64_t n = ++gpuStats->gpuErrors;
			if (n <= 10 || n % 100 == 0)
				os_log_error(HSLog(), "#%u GPU error on %{public}s commit (error #%llu): %{public}@",
							 tag, what, n, feedback.error);
		}
	}];
	return options;
}

HSRenderer::HSRenderer() : impl(new HSRendererImpl) {}

void HSRenderer::setLogTag(uint32_t tag)
{
	impl->logTag = tag;
}

HSFrameStats HSRenderer::frameStats() const
{
	HSFrameStats s = impl->stats;
	s.gpuCompleted = impl->gpuStats->gpuCompleted.load();
	s.gpuErrors = impl->gpuStats->gpuErrors.load();
	return s;
}

HSRenderer::~HSRenderer()
{
	// Nothing below may be freed while the GPU can still touch it (MTL4 doesn't retain
	// resources for committed work). Normally this is at most a couple of frames' wait, and
	// teardown is off the startup path that can't tolerate CPU blocking.
	if (impl->frameEvent && impl->frameNumber > 0)
		[impl->frameEvent waitUntilSignaledValue:impl->frameNumber timeoutMS:500];
	if (impl->setupEvent && impl->setupEventValue > 0)
		[impl->setupEvent waitUntilSignaledValue:impl->setupEventValue timeoutMS:500];
	if (impl->queue && impl->residencySet)
		[impl->queue removeResidencySet:impl->residencySet];
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
	impl->setupEvent = [device newSharedEvent];
	impl->setupEvent.signaledValue = 0;
	impl->setupEventValue = 0;
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

	id<MTLBuffer> frameVertexBuffers[HSRendererImpl::kMaxFramesInFlight];
	id<MTLBuffer> frameIndexBuffers[HSRendererImpl::kMaxFramesInFlight];
	for (int i = 0; i < HSRendererImpl::kMaxFramesInFlight; ++i)
	{
		frameVertexBuffers[i] = [device newBufferWithLength:kVertexBufferCapacity options:MTLResourceStorageModeShared];
		frameIndexBuffers[i] = [device newBufferWithLength:kIndexBufferCapacity options:MTLResourceStorageModeShared];
		if (!frameVertexBuffers[i] || !frameIndexBuffers[i])
			return false;
		frameVertexBuffers[i].label = [NSString stringWithFormat:@"HSRenderer vertex ring %d", i];
		frameIndexBuffers[i].label = [NSString stringWithFormat:@"HSRenderer index ring %d", i];
		[residencySet addAllocation:frameVertexBuffers[i]];
		[residencySet addAllocation:frameIndexBuffers[i]];
	}
	id<MTLBuffer> frameFogBuffers[HSRendererImpl::kMaxFramesInFlight];
	for (int i = 0; i < HSRendererImpl::kMaxFramesInFlight; ++i)
	{
		frameFogBuffers[i] = [device newBufferWithLength:kFogBufferCapacity options:MTLResourceStorageModeShared];
		if (!frameFogBuffers[i])
			return false;
		frameFogBuffers[i].label = [NSString stringWithFormat:@"HSRenderer fog uniforms %d", i];
		[residencySet addAllocation:frameFogBuffers[i]];
	}
	id<MTLBuffer> fogBuffer = [device newBufferWithLength:kFogUniformStride options:MTLResourceStorageModeShared];
	fogBuffer.label = @"HSRenderer setup fog uniforms (disabled)";
	HSRendererImpl::FogUniforms disabledFog = {{0.0f, 0.0f, 0.0f, 1.0f}, 0.0f, 0.0f, 0, 0};
	std::memcpy(fogBuffer.contents, &disabledFog, sizeof(disabledFog));
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
	for (int i = 0; i < HSRendererImpl::kMaxFramesInFlight; ++i)
	{
		impl->frameVertexBuffers[i] = frameVertexBuffers[i];
		impl->frameIndexBuffers[i] = frameIndexBuffers[i];
	}
	impl->fogBuffer = fogBuffer;
	for (int i = 0; i < HSRendererImpl::kMaxFramesInFlight; ++i)
		impl->frameFogBuffers[i] = frameFogBuffers[i];

	return true;
}

// Caustic setup buffers are only needed while initSaver() is generating textures; once the
// GPU has signaled past the last setup submission, nothing can still be reading any of them,
// so drop them (~16MB each) rather than keeping them for the lifetime of the renderer.
// Non-blocking: just a signaledValue check, cheap enough to run every frame.
// Same goes for the throwaway setup allocators (initSaver() creates a few dozen per run, and
// they hold their recorded command memory), and for textures parked by destroyTexture().
static void hsReleaseRetiredResources(HSRendererImpl *impl)
{
	bool changedResidency = false;
	uint64_t setupDone = impl->setupEvent.signaledValue;
	if (setupDone >= impl->setupEventValue)
	{
		for (const auto &entry : impl->setupVertexBuffers)
			[impl->residencySet removeAllocation:entry.buffer];
		changedResidency = changedResidency || !impl->setupVertexBuffers.empty();
		impl->setupVertexBuffers.clear();
		impl->setupAllocators.clear();
	}

	uint64_t framesDone = impl->frameEvent.signaledValue;
	auto &retired = impl->retiredTextures;
	for (auto it = retired.begin(); it != retired.end();)
	{
		if (framesDone >= it->afterFrame && setupDone >= it->afterSetup)
		{
			[impl->residencySet removeAllocation:it->texture];
			changedResidency = true;
			it = retired.erase(it);
		}
		else
			++it;
	}

	if (changedResidency)
		[impl->residencySet commit];
}

bool HSRenderer::beginFrame()
{
	if (impl->frameInProgress)
	{
		impl->stats.skipReentrant++;
		return false;	// re-entrant call (see frameInProgress's comment); drop this one
	}

	// Check whether the view can actually give us a drawable before touching any frame-
	// tracking state (frameNumber/frameEvent/allocators) — matching the order Apple's own
	// "Drawing a triangle with Metal 4" sample uses. Doing this check last (the previous
	// order here) meant every call made during the window before the view has real geometry
	// (e.g. the ViewBridge/LegacyViewController startup race this renderer has repeatedly hit)
	// still advanced frameNumber, waited on frameEvent, and reset an allocator for a frame that
	// was never actually going to submit any GPU work.
	MTKView *view = impl->view;
	MTL4RenderPassDescriptor *passDescriptor = view.currentMTL4RenderPassDescriptor;
	id<CAMetalDrawable> drawable = view.currentDrawable;
	if (!passDescriptor || !drawable)
	{
		if (!passDescriptor)
			impl->stats.skipNoPassDescriptor++;
		else
			impl->stats.skipNoDrawable++;
		return false;
	}

	impl->frameInProgress = true;
	impl->drawable = drawable;

	// Wait for the GPU to actually finish the frame kMaxFramesInFlight iterations back (not
	// just for its commit() to return) before reclaiming the allocator it used.
	impl->frameNumber++;
	const int slot = int(impl->frameNumber % HSRendererImpl::kMaxFramesInFlight);
	id<MTL4CommandAllocator> allocator = impl->allocators[slot];
	if (impl->frameNumber > HSRendererImpl::kMaxFramesInFlight)
	{
		BOOL signaled = [impl->frameEvent waitUntilSignaledValue:impl->frameNumber - HSRendererImpl::kMaxFramesInFlight timeoutMS:1000];
		if (!signaled)
		{
			// The wait timed out — the GPU hasn't actually confirmed it's done with this
			// allocator yet. Resetting it anyway (the previous code did, ignoring the return
			// value) is a real Metal API violation if the GPU is still recording into it, and
			// is a plausible cause of the IOGPUMetalError/hang class of bug this renderer has
			// hit before. Drop this frame instead; retry the same frame number next time
			// rather than advancing past a slot that was never confirmed free.
			impl->stats.skipFenceTimeout++;
			os_log_error(HSLog(), "#%u frame fence wait timed out (frame %llu, GPU at %llu)",
						 impl->logTag, impl->frameNumber, impl->frameEvent.signaledValue);
			impl->frameNumber--;
			impl->frameInProgress = false;
			impl->drawable = nil;
			return false;
		}
	}
	[allocator reset];
	hsReleaseRetiredResources(impl);

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
	// Safe to rewind: this slot's buffers were last read by frame frameNumber -
	// kMaxFramesInFlight, which the frameEvent wait above confirmed the GPU has finished.
	impl->currentVertexBuffer = impl->frameVertexBuffers[slot];
	impl->currentIndexBuffer = impl->frameIndexBuffers[slot];
	impl->currentFogBuffer = impl->frameFogBuffers[slot];
	impl->fogBufferOffset = 0;
	impl->currentFogAddress = 0;
	impl->vertexBufferOffset = 0;
	impl->indexBufferOffset = 0;
	impl->hasPendingSpriteBatch = false;
	impl->hasPendingMeshBatch = false;
	return true;
}

void HSRenderer::endFrame()
{
	if (!impl->commandBuffer)
		return;

	hsFlushSpriteBatch(impl);
	hsFlushMeshBatch(impl);
	[impl->encoder endEncoding];
	[impl->commandBuffer endCommandBuffer];

	id<CAMetalDrawable> drawable = impl->drawable;
	id<MTL4CommandBuffer> commandBuffer = impl->commandBuffer;

	[impl->queue waitForDrawable:drawable];
	__block id<MTL4CommandBuffer> retainedBuffer = commandBuffer;	// keep alive until the GPU actually runs it
	[impl->queue commit:&retainedBuffer count:1 options:hsCommitOptions(impl, "frame")];
	impl->stats.presented++;
	[impl->queue signalDrawable:drawable];
	[drawable present];
	// Signaled once the GPU finishes this frame's passes, not merely once commit() returns
	// (commit is an async CPU-side enqueue) — the next beginFrame waits on this before it
	// resets the allocator these commands were recorded into.
	[impl->queue signalEvent:impl->frameEvent value:impl->frameNumber];

	impl->encoder = nil;
	impl->commandBuffer = nil;
	impl->drawable = nil;
	impl->currentVertexBuffer = nil;
	impl->currentIndexBuffer = nil;
	impl->currentFogBuffer = nil;
	impl->frameInProgress = false;
}

// --- Everything below is wired up in later phases; stub for now. ---

// Matches HSFogUniforms in Shaders.metal: float4 color; float scale; float end; bool enabled;
void HSRenderer::setFog(float start, float end, bool enabled)
{
	// Anything already queued was submitted under the old fog state; draw it with that.
	if (impl->encoder)
	{
		hsFlushSpriteBatch(impl);
		hsFlushMeshBatch(impl);
	}

	HSRendererImpl::FogUniforms &uniforms = impl->fogUniforms;
	uniforms.color[0] = uniforms.color[1] = uniforms.color[2] = 0.0f;	// fog is always black in this engine
	uniforms.color[3] = 1.0f;
	uniforms.scale = (end != start) ? 1.0f / (end - start) : 0.0f;
	uniforms.end = end;
	uniforms.enabled = enabled ? 1 : 0;
	impl->fogDirty = true;
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
	// Deferred to flush time (hsFlushSpriteBatch/hsFlushMeshBatch), as part of each batch's
	// key, not applied to the encoder here — a pending batch accumulated under the old cull
	// mode hasn't actually drawn yet, so changing the encoder's cull mode immediately would
	// retroactively apply the new mode to geometry that was recorded under the old one.
	impl->currentCullMode = mode;
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

// Expands the accumulated triangle strip into independent triangles (triangle k of a strip
// is vertices k, k+1, k+2, with the first two swapped on odd k to preserve winding) and either
// appends it to the current pending batch, or flushes that batch and starts a new one, depending
// on whether pipeline/cullMode/textures have changed since the last end(). This is what collapses
// e.g. 2000 stars' worth of individual quad draws into a single drawPrimitives call.
void HSRenderer::end()
{
	size_t vertexCount = impl->vertexAccumulator.size() / 14;
	if (vertexCount < 3 || !impl->encoder)
	{
		impl->vertexAccumulator.clear();
		return;
	}

	uint32_t triangleCount = uint32_t(vertexCount - 2);
	uint32_t outVertexCount = triangleCount * 3;
	size_t byteSize = size_t(outVertexCount) * 14 * sizeof(float);

	HSRendererImpl::BatchKey key;
	key.pipeline = impl->currentPipeline;
	key.cullMode = impl->currentCullMode;
	key.textures[0] = impl->boundTextures[0];
	key.textures[1] = impl->boundTextures[1];
	key.textures[2] = impl->boundTextures[2];

	bool canAppend = impl->hasPendingSpriteBatch && impl->pendingSpriteKey == key;
	if (!canAppend)
		hsFlushSpriteBatch(impl);
	if (impl->vertexBufferOffset + byteSize > kVertexBufferCapacity)
	{
		impl->vertexAccumulator.clear();
		return;	// out of ring space for this frame; drop the draw rather than corrupt memory
	}
	if (!canAppend)
	{
		impl->pendingSpriteKey = key;
		impl->pendingSpriteStartOffset = impl->vertexBufferOffset;
		impl->pendingSpriteVertexCount = 0;
		impl->hasPendingSpriteBatch = true;
	}

	float *dest = reinterpret_cast<float *>(static_cast<uint8_t *>(impl->currentVertexBuffer.contents) + impl->vertexBufferOffset);
	const float *src = impl->vertexAccumulator.data();
	for (uint32_t tri = 0; tri < triangleCount; ++tri)
	{
		uint32_t i0 = tri, i1 = tri + 1, i2 = tri + 2;
		if (tri % 2 != 0)
			std::swap(i0, i1);
		std::memcpy(dest, src + size_t(i0) * 14, 14 * sizeof(float));
		std::memcpy(dest + 14, src + size_t(i1) * 14, 14 * sizeof(float));
		std::memcpy(dest + 28, src + size_t(i2) * 14, 14 * sizeof(float));
		dest += 42;
	}

	impl->vertexBufferOffset += byteSize;
	impl->pendingSpriteVertexCount += outVertexCount;
	impl->vertexAccumulator.clear();
}

// Bypasses the immediate-mode begin/vertex*/end batcher above: goo tiles (and the starburst
// sphere) hand over a whole N3F_V3F mesh at once, matching the original's VBO draw calls.
// attrib3 carries the object-space normal unchanged — like the sprite/tunnel path, this is a
// direct port of the original GLSL goo shader, which used gl_Normal (object space, no normal
// matrix) as a cube lookup direction. That's only correct because goo tiles are only ever
// pure-translated (never rotated/scaled) onto the model stack; if that ever changes, this needs
// a proper normal-matrix transform.
// Goo tiles and the starburst sphere are already independent triangles via their index buffer,
// so batching them is simpler than the strip case: just rebase each submission's indices onto
// wherever its vertices land in the shared pending-batch vertex range, and defer the actual
// drawIndexedPrimitives call the same way end() does. In practice all goo tiles (and often the
// starburst sphere too, since it reuses the same wavy-normal/nebula textures) share one key and
// collapse into a single draw call per frame instead of one per tile.
void HSRenderer::drawIndexedMesh(const float *interleavedNormalPosition, uint32_t vertexCount,
								  const uint32_t *indices, uint32_t indexCount)
{
	if (vertexCount == 0 || indexCount == 0 || !impl->encoder || !impl->currentIndexBuffer)
		return;

	size_t vertexByteSize = size_t(vertexCount) * 14 * sizeof(float);
	size_t indexByteSize = size_t(indexCount) * sizeof(uint32_t);

	HSRendererImpl::BatchKey key;
	key.pipeline = HS_PIPELINE_GOO;
	key.cullMode = impl->currentCullMode;
	key.textures[0] = impl->boundTextures[0];
	key.textures[1] = impl->boundTextures[1];
	key.textures[2] = impl->boundTextures[2];

	bool canAppend = impl->hasPendingMeshBatch && impl->pendingMeshKey == key;
	if (!canAppend)
		hsFlushMeshBatch(impl);
	if (impl->vertexBufferOffset + vertexByteSize > kVertexBufferCapacity
		|| impl->indexBufferOffset + indexByteSize > kIndexBufferCapacity)
		return;	// out of ring space for this frame; drop the draw rather than corrupt memory
	if (!canAppend)
	{
		impl->pendingMeshKey = key;
		impl->pendingMeshVertexStartOffset = impl->vertexBufferOffset;
		impl->pendingMeshIndexStartOffset = impl->indexBufferOffset;
		impl->pendingMeshVertexCount = 0;
		impl->pendingMeshIndexCount = 0;
		impl->hasPendingMeshBatch = true;
	}

	float *dest = reinterpret_cast<float *>(static_cast<uint8_t *>(impl->currentVertexBuffer.contents) + impl->vertexBufferOffset);
	for (uint32_t i = 0; i < vertexCount; ++i)
	{
		const float *src = interleavedNormalPosition + i * 6;	// normal.xyz, position.xyz
		double local[4] = {double(src[3]), double(src[4]), double(src[5]), 1.0};
		double eye[4], clip[4];
		hsMatVecMul(impl->modelStack[impl->stackTop], local, eye);
		hsMatVecMul(impl->projectionMatrix, eye, clip);

		float *v = dest + i * 14;
		v[0] = float(clip[0]); v[1] = float(clip[1]); v[2] = float(clip[2]); v[3] = float(clip[3]);
		v[4] = float(eye[0]); v[5] = float(eye[1]); v[6] = float(eye[2]);
		v[7] = src[0]; v[8] = src[1]; v[9] = src[2];
		v[10] = impl->currentColor[0]; v[11] = impl->currentColor[1]; v[12] = impl->currentColor[2]; v[13] = impl->currentColor[3];
	}

	uint32_t *destIndices = reinterpret_cast<uint32_t *>(static_cast<uint8_t *>(impl->currentIndexBuffer.contents) + impl->indexBufferOffset);
	uint32_t baseVertex = impl->pendingMeshVertexCount;
	for (uint32_t i = 0; i < indexCount; ++i)
		destIndices[i] = indices[i] + baseVertex;

	impl->vertexBufferOffset += vertexByteSize;
	impl->indexBufferOffset += indexByteSize;
	impl->pendingMeshVertexCount += vertexCount;
	impl->pendingMeshIndexCount += indexCount;
}

// Commits a one-off setup command buffer and schedules a GPU-side signal of impl->setupEvent
// once it completes — no CPU wait here, and waitForSetupCompletion() below doesn't CPU-wait
// either. Blocking the calling thread for GPU completion turned out to be unsafe to do even
// once during initSaver(): it's called deep in the screen saver extension's startup path, and
// that environment appears to have a responsiveness watchdog that doesn't tolerate it — the
// previous CPU-blocking version of this fix made the preview blank out ~4 times out of 5
// rather than fixing the race it was meant to fix.
static void hsCommitSetupSubmission(HSRendererImpl *impl, id<MTL4CommandBuffer> cmdBuffer)
{
	impl->setupEventValue++;
	id<MTL4CommandBuffer> buffers[1] = {cmdBuffer};
	[impl->queue commit:buffers count:1 options:hsCommitOptions(impl, "setup")];
	[impl->queue signalEvent:impl->setupEvent value:impl->setupEventValue];
}

void HSRenderer::waitForSetupCompletion()
{
	// GPU-side wait, not a CPU-side one: schedules the queue to hold off running any future
	// work (i.e. the main render loop's first frame, submitted well after this call returns)
	// until the setup event reaches this value. The calling thread is never blocked.
	if (impl->setupEventValue > 0)
		[impl->queue waitForEvent:impl->setupEvent value:impl->setupEventValue];
}

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

	// Residency must be established before any command buffer that touches this texture is
	// committed, including the mipmap-generation pass right below — a texture isn't
	// guaranteed GPU-accessible just because it was just created.
	[impl->residencySet addAllocation:texture];
	[impl->residencySet commit];

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
		hsCommitSetupSubmission(impl, cmdBuffer);
	}

	HSTextureRef ref = impl->nextTextureRef++;
	impl->textures[ref] = texture;
	return ref;
}

// Face order is +X,-X,+Y,-Y,+Z,-Z (slices 0-5), matching GL_TEXTURE_CUBE_MAP_POSITIVE_X etc. in
// that same enum order — both APIs use this convention, so callers built against the original
// GL face order need no reordering.
HSTextureRef HSRenderer::createTextureCube(int size, const uint8_t *facesRGBA8[6], bool mipmapped)
{
	MTLTextureDescriptor *desc = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
																						 size:size
																					mipmapped:mipmapped];
	desc.usage = MTLTextureUsageShaderRead;
	id<MTLTexture> texture = [impl->device newTextureWithDescriptor:desc];
	if (!texture)
		return HS_INVALID_TEXTURE;

	for (int face = 0; face < 6; ++face)
	{
		[texture replaceRegion:MTLRegionMake2D(0, 0, size, size)
					mipmapLevel:0
						  slice:face
					  withBytes:facesRGBA8[face]
					bytesPerRow:size * 4
				  bytesPerImage:0];
	}

	// Residency must be established before any command buffer that touches this texture is
	// committed, including the mipmap-generation pass right below.
	[impl->residencySet addAllocation:texture];
	[impl->residencySet commit];

	if (mipmapped)
	{
		// Throwaway allocator: see createTexture2D's mipmap path for why this can't reuse one
		// of the per-frame allocators.
		id<MTL4CommandAllocator> mipAllocator = [impl->device newCommandAllocator];
		impl->setupAllocators.push_back(mipAllocator);
		id<MTL4CommandBuffer> cmdBuffer = [impl->device newCommandBuffer];
		[cmdBuffer beginCommandBufferWithAllocator:mipAllocator];
		id<MTL4ComputeCommandEncoder> blit = [cmdBuffer computeCommandEncoder];
		[blit generateMipmapsForTexture:texture];
		[blit endEncoding];
		[cmdBuffer endCommandBuffer];
		hsCommitSetupSubmission(impl, cmdBuffer);
	}

	HSTextureRef ref = impl->nextTextureRef++;
	impl->textures[ref] = texture;
	return ref;
}

void HSRenderer::destroyTexture(HSTextureRef texture)
{
	auto it = impl->textures.find(texture);
	if (it == impl->textures.end())
		return;
	// frameNumber is the last frame that may have sampled it (committed, or still being
	// recorded if we're mid-frame and endFrame() will commit it as that number).
	impl->retiredTextures.push_back({it->second, impl->frameNumber, impl->setupEventValue});
	impl->textures.erase(it);
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

	// Residency must be established before the render pass below (which writes to this
	// texture) is committed — a texture isn't guaranteed GPU-accessible just because it was
	// just created.
	[impl->residencySet addAllocation:impl->causticTexture];
	[impl->residencySet commit];

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

	// Never a per-frame slot's buffer (frames may still be in flight if initSaver() is
	// re-running after a stop/start), and never a setup buffer an earlier caustic frame
	// committed but the GPU hasn't finished with yet (see setupVertexBuffers' comment).
	// Checking signaledValue doesn't block, unlike waiting on it.
	uint64_t setupDone = impl->setupEvent.signaledValue;
	size_t index = impl->setupVertexBuffers.size();
	for (size_t i = 0; i < impl->setupVertexBuffers.size(); ++i)
	{
		if (impl->setupVertexBuffers[i].lastUseSetupValue <= setupDone)
		{
			index = i;
			break;
		}
	}
	if (index == impl->setupVertexBuffers.size())
	{
		id<MTLBuffer> buffer = [impl->device newBufferWithLength:kVertexBufferCapacity options:MTLResourceStorageModeShared];
		buffer.label = @"HSRenderer setup vertex buffer";
		[impl->residencySet addAllocation:buffer];
		[impl->residencySet commit];
		impl->setupVertexBuffers.push_back({buffer, 0});
	}
	impl->currentSetupVertexBuffer = index;
	impl->currentVertexBuffer = impl->setupVertexBuffers[index].buffer;
	impl->currentIndexBuffer = nil;
	impl->vertexBufferOffset = 0;
	impl->indexBufferOffset = 0;
	impl->hasPendingSpriteBatch = false;
	impl->hasPendingMeshBatch = false;
}

HSTextureRef HSRenderer::endCausticFrame()
{
	hsFlushSpriteBatch(impl);
	hsFlushMeshBatch(impl);
	[impl->encoder endEncoding];

	id<MTL4ComputeCommandEncoder> mipEncoder = [impl->commandBuffer computeCommandEncoder];
	[mipEncoder generateMipmapsForTexture:impl->causticTexture];
	[mipEncoder endEncoding];

	[impl->commandBuffer endCommandBuffer];
	hsCommitSetupSubmission(impl, impl->commandBuffer);
	impl->setupVertexBuffers[impl->currentSetupVertexBuffer].lastUseSetupValue = impl->setupEventValue;

	HSTextureRef ref = impl->nextTextureRef++;
	impl->textures[ref] = impl->causticTexture;

	impl->commandBuffer = nil;
	impl->encoder = nil;
	impl->currentVertexBuffer = nil;
	impl->causticTexture = nil;
	return ref;
}
