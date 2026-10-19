# Draft: vkd3d bug report / merge request

**Title:** vkd3d: implement NULL SRVs for TEXTURECUBE / TEXTURECUBEARRAY without VK_EXT_robustness2

## Description

Without `VK_EXT_robustness2` (e.g. on MoltenVK), `vkd3d_create_null_srv()` only handles BUFFER,
TEXTURE2D and TEXTURE2DARRAY; other dimensions print

```
vkd3d_create_null_srv Unhandled view dimension 0x9.
```

and leave the descriptor unwritten, so shaders sampling it read whatever the slot previously contained.
Diablo II: Resurrected creates a null `TEXTURECUBE` SRV at startup.

## Fix

Create the NULL 2D SRV image with 6 array layers (square 1x1 with >= 6 layers is already made
`VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT` by `vkd3d_create_image()`, and the init barrier already covers
`VK_REMAINING_ARRAY_LAYERS`), and add `TEXTURECUBE` / `TEXTURECUBEARRAY` cases creating 6-layer cube
views with zero swizzle (patches/0003-vkd3d-null-cube-srv.patch).

## Second, MoltenVK-specific workaround (not for upstream as-is)

patches/0002 drops hull/domain shaders and draws 3-control-point patch lists as triangle lists, which
is only correct for pass-through tessellation (tess factor 1, linear interpolation); it works around a
MoltenVK tessellation bug (see moltenvk-tessellation-passthrough.md) and is enabled by default in this
project's build (`VKD3D_D2R_NOTESS=0` disables it).
