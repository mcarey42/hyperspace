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

## Workflow

- One branch (`modernize-metal`), one commit per phase/sub-phase milestone, each verified by
  building and running in `HyperspaceHost` before committing — see the plan file for the phase
  breakdown.
