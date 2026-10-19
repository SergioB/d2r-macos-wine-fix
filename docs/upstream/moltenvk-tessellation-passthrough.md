# Draft: MoltenVK issue

**Title:** Pass-through tessellation pipeline (3 control points, tess level 1) produces no output

## Environment

MoltenVK 1.4.2 (x86_64 slice, under Rosetta 2) · macOS 26.6.2 · Apple M3 · vkd3d 1.18 (Wine 11.0) ·
Diablo II: Resurrected (D3D12) terrain rendering.

## Description

The game renders its terrain with a D3D12 hull/domain shader pair that vkd3d translates to this
TCS/TES (SPIRV-Cross GLSL output):

```glsl
// TCS: layout(vertices = 3) out;
o0[gl_InvocationID] = gl_in[gl_InvocationID].gl_Position;
o1[gl_InvocationID] = v1[gl_InvocationID];   // vec4
o2[gl_InvocationID] = v2[gl_InvocationID];   // vec3
o3[gl_InvocationID] = v3[gl_InvocationID];   // vec3
o4[gl_InvocationID] = v4[gl_InvocationID];   // vec3
o5[gl_InvocationID] = v5[gl_InvocationID];   // vec4
gl_TessLevelOuter[0..2] = 1.0; gl_TessLevelInner[0] = 1.0;

// TES: layout(triangles) in;
gl_Position = TessCoord-weighted sum of v0[0..2]; o1..o5 likewise from v1..v5
```

drawn with `VK_PRIMITIVE_TOPOLOGY_PATCH_LIST`, `patchControlPoints = 3`, indexed. Nothing reaches the
render targets: replacing the fragment shader's outputs with constant colours shows no pixels at all,
and no MoltenVK warnings or errors are logged (MVK_CONFIG_LOG_LEVEL=2). Dropping the TCS/TES and drawing
the same vertex buffer as `TRIANGLE_LIST` with the same VS/FS renders correctly.

The SPIR-V passes `spirv-val --target-env vulkan1.1`. Shaders and a pipeline description can be
provided (vkd3d `VKD3D_SHADER_DUMP_PATH` dumps).

Possibly relevant: three `vec3` interface variables (o2..o4) between TCS and TES.
