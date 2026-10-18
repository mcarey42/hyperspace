# CLAUDE.md

Notes for Claude Code (and future-us) working on this repo. Keep this updated as we learn things the hard way.

## Testing via HyperspaceHost

`HyperspaceHost` doesn't compile `HyperspaceView`/the renderer directly. It dynamically loads a
pre-built `Hyperspace.saver` bundle at runtime via `NSBundle` (see `HyperspaceSaverLoader` in
`HyperspaceHost/HyperspaceHostView.swift`) — the same mechanism the real screensaver host uses.

**The "HyperspaceHost" Xcode scheme has no build dependency on the "Hyperspace" (saver) target.**
Building/running "HyperspaceHost" only rebuilds the thin host app shell; it silently leaves
whatever `Hyperspace.saver` is already sitting in the build products directory untouched, even if
the saver's source has since changed.

**Before every test cycle:**
1. Switch to the "Hyperspace" scheme and build it.
2. Switch back to "HyperspaceHost" and run.

A giveaway that this was skipped: the build returns in ~1-2 seconds (no-op) instead of the ~15-20
seconds a real recompile of the saver's C++/Objective-C++/Metal sources takes. If something you
just changed doesn't seem to have taken effect, check the saver bundle's actual timestamp before
assuming the bug is in the code:

```sh
stat -f "%Sm" "$(find ~/Library/Developer/Xcode/DerivedData/Hyperspace-*/Build/Products/Debug/Hyperspace.saver/Contents/MacOS/Hyperspace -maxdepth 0)"
```

This isn't fixed permanently (would need a target dependency + copy-files build phase in
`project.pbxproj`, which can't be edited while Xcode has the project open, and the project owner
preferred not to block on that). It is a standing manual step.

## Metal 4 gotchas found porting this renderer

- **Vertex fetch**: use manual buffer indexing (`device const float* buf [[buffer(0)]]` +
  `[[vertex_id]]`), not `[[stage_in]]` + `MTLVertexDescriptor`. Metal 4's argument-table buffer
  bindings are plain GPU addresses, not the fixed-function attribute-fetch descriptors stage_in
  relies on — every Apple Metal 4 sample indexes raw buffers by `vertex_id` instead.
- **Command allocator reuse**: `commit()` returning does not mean the GPU has finished running
  that command buffer — only that the CPU handed it to the queue. Resetting an allocator before
  the GPU actually finishes the work it recorded corrupts in-flight command buffers (manifests as
  `kIOGPUCommandBufferCallbackErrorHang` / page faults). Use a real GPU-signaled `MTLSharedEvent`,
  and prefer triple-buffered allocators (matching Apple's own "Drawing a triangle with Metal 4"
  sample) over a single allocator with a one-frame margin.
- **Residency sets**: a view's `residencySet` registered while the view is still 0x0 (e.g. during
  `attachToView` before AppKit/SwiftUI has laid out the window) may not be the object MTKView
  actually vends once it has a real size. Re-check and re-register every frame if there's any
  chance the renderer attaches before the host view has geometry.
- **One-off GPU work** (mipmap generation, offscreen texture passes like caustic generation) needs
  its own throwaway `MTL4CommandAllocator`, never the per-frame allocator — otherwise it's exposed
  to the same reset-before-GPU-completion hazard as above, just via a different code path.
- **Re-entrancy**: `beginFrame()`/`endFrame()` need a guard against being entered twice without a
  matched pair completing. `waitUntilSignaledValue:timeoutMS:` can pump the run loop while
  blocking, which on the main thread can let AppKit redeliver a UI event that re-enters the draw
  call before the outer one returns.
- **MTL4 command buffers don't retain resources.** Anything a committed frame or setup pass uses
  (textures, buffers) must outlive the GPU work. `destroyTexture` parks textures until
  `frameEvent`/`setupEvent` pass the values they were last used at, and `~HSRenderer` waits for
  in-flight work before freeing. Per-frame CPU-written data (vertex/index rings, fog uniforms)
  lives in one buffer per frame-in-flight slot.

## legacyScreenSaver hosting gotchas

- **Blank screen at 60fps = `CAMetalLayer.contentsScale == 0`.** legacyScreenSaver often adds the
  view to its host window before that window has a screen (frame 0x0, `screen == nil`). MTKView
  then sets its layer's `contentsScale` to 0, and the host only sends resize/screen-change
  notifications afterwards, never a backing-properties change, so it's never corrected. Every
  drawable presents with no errors, and nothing composites. `-[HyperspaceView syncLayerScale]`
  re-syncs it every frame. HyperspaceHost never reproduces this, so test in System Settings.
- **`drawableSizeWillChange:` may never fire**: MTKView computes its first drawable size in
  `initWithFrame:`, before the delegate is set, and the host usually never resizes the view.
  `syncViewportWithDrawable` calls `reshape()` from the real drawable size every frame.
- The System Settings sheet preview and the desktop background are the same full-display
  (`isPreview=0`, 3840x2160) instance scaled down. The `isPreview=1`, 0x0 instances in the other
  process never get `startAnimation`. The module-list tiles are the static `thumbnail.png`.
- **Diagnostics**: `os_log` subsystem `com.reallyslick.Hyperspace` (see `Hyperspace/HSLog.h`).
  Lifecycle lines are at default level; per-instance stats and layer-tree state every 2s are at
  debug level:
  `log stream --level debug --predicate 'subsystem == "com.reallyslick.Hyperspace"'`.
  `init`, `initSaver` and animating signposts show up in Instruments' Points of Interest track.
  The per-frame interval is opt-in: set `HYPERSPACE_FRAME_SIGNPOSTS=1` in the environment (e.g.
  the HyperspaceHost scheme). It's off by default because always-on frame signposts flood the
  system log, and the dynamic-tracing category isn't enabled by xctrace's os_signpost
  instrument. Instruments can't capture signposts from the sandboxed legacyScreenSaver host at
  all, so profile in HyperspaceHost. GPU-side errors are logged from `MTL4CommitOptions`
  feedback handlers.
- **Detached views are never stopped or freed by the host.** legacyScreenSaver removes a view from
  its window when the preview changes or the saver ends, but never calls `stopAnimation`, and
  ScreenSaverView's animation timer keeps the view alive. Each instance used to hold ~220MB for
  the life of the process. `viewDidMoveToWindow` with a nil window now stops animation and
  releases the scene, MTKView and renderer, after which the view deallocates. Measure with
  `footprint <pid>` across repeated reselects; it should stay flat.
- To make the host reload a reinstalled bundle: `killall legacyScreenSaver`.
- Leak-check the C++ engine with HyperspaceHost: launch its binary with `MallocStackLogging=1`,
  use Hyperspace → Configure… → Close a few times (a full stop/cleanUp/initSaver cycle), then
  run `leaks <pid>`. It should report 0 leaks. Several upstream classes (tunnel, causticTextures,
  splinePath, goo) used to free only the outer level of their nested arrays.
- Some upstream sources (e.g. `splinePath.cpp`) use CRLF line endings. Preserve them when editing.

## Workflow

- One branch (`modernize-metal`), one commit per phase/sub-phase milestone, each verified by
  building and running in `HyperspaceHost` before committing — see the plan file for the phase
  breakdown.
