//
//  Shaders.metal
//  Hyperspace
//
//  Direct ports of the original GLSL (shaders.h) goo/tunnel shaders, plus new
//  sprite and caustic shaders replacing the fixed-function paths (sphere-map
//  texgen, GL_MODULATE, fixed fog) that the dropped "Use shaders" checkbox used
//  to fall back to.
//
//  All four pipelines share one vertex layout and one vertex function; only the
//  fragment function differs. `attrib3` carries either a texture coordinate
//  (sprite/tunnel, in .xy) or an object-space normal (goo, used directly as a
//  cube lookup direction, exactly like the original GLSL did with gl_Normal).
//

#include <metal_stdlib>
using namespace metal;

struct HSVertexIn
{
	float4 clipPosition	[[attribute(0)]];	// precomputed projection * modelview * local, CPU-side
	float3 eyePosition		[[attribute(1)]];	// modelview * local, for fog and goo's reflection vector
	float3 attrib3			[[attribute(2)]];	// texcoord.xy (sprite/tunnel) or object-space normal (goo)
	float4 color			[[attribute(3)]];	// rgb + alpha (alpha doubles as the animation-frame lerp)
};

struct HSVaryings
{
	float4 position [[position]];
	float3 eyePosition;
	float3 attrib3;
	float4 color;
};

struct HSFogUniforms
{
	float4 color;
	float scale;	// 1 / (end - start)
	float end;
	bool enabled;
};

vertex HSVaryings hsVertexMain(HSVertexIn in [[stage_in]])
{
	HSVaryings out;
	out.position = in.clipPosition;
	out.eyePosition = in.eyePosition;
	out.attrib3 = in.attrib3;
	out.color = in.color;
	return out;
}

static inline float4 hsApplyFog(float4 color, float3 eyePosition, constant HSFogUniforms &fog)
{
	if (!fog.enabled)
		return color;
	float t = saturate((fog.end + eyePosition.z) * fog.scale);
	return mix(fog.color, color, t);
}

// MARK: - Sprite (stars, flare, sun)

fragment float4 hsSpriteFragment(HSVaryings in [[stage_in]],
								  texture2d<float> tex [[texture(0)]],
								  sampler smp [[sampler(0)]],
								  constant HSFogUniforms &fog [[buffer(1)]])
{
	float4 color = tex.sample(smp, in.attrib3.xy) * in.color;
	return hsApplyFog(color, in.eyePosition, fog);
}

// MARK: - Tunnel (direct port of tunnelFragSource)

fragment float4 hsTunnelFragment(HSVaryings in [[stage_in]],
								  texture2d<float> tex0 [[texture(0)]],
								  texture2d<float> tex1 [[texture(1)]],
								  sampler smp [[sampler(0)]],
								  constant HSFogUniforms &fog [[buffer(1)]])
{
	float2 uv = in.attrib3.xy;
	float4 texcol0 = tex0.sample(smp, uv) + 0.5 * tex0.sample(smp, uv * float2(3.0, 2.0));
	float4 texcol1 = tex1.sample(smp, uv) + 0.5 * tex1.sample(smp, uv * float2(3.0, 2.0));
	float4 color = mix(texcol0, texcol1, in.color.a);
	// Note that max value of color at this point is 1.5
	color.rgb = 2.0 * mix(in.color.rgb * color.rgb,
						   max(float3(0.0), (in.color.rgb * float3(1.5)) + color.rgb - float3(1.5)),
						   0.5);
	return hsApplyFog(color, in.eyePosition, fog);
}

// MARK: - Goo (direct port of gooFragSource)

fragment float4 hsGooFragment(HSVaryings in [[stage_in]],
							   texturecube<float> normaltex0 [[texture(0)]],
							   texturecube<float> normaltex1 [[texture(1)]],
							   texturecube<float> tex [[texture(2)]],
							   sampler smp [[sampler(0)]],
							   constant HSFogUniforms &fog [[buffer(1)]])
{
	float3 dir = in.attrib3;	// object-space normal, used directly as a cube lookup, like GLSL's gl_Normal did
	float4 normal0 = normaltex0.sample(smp, dir) * 2.0 - 1.0;
	float4 normal1 = normaltex1.sample(smp, dir) * 2.0 - 1.0;
	float4 texnormal = mix(normal0, normal1, in.color.a);
	// Reflection vector
	float3 eyevec = normalize(in.eyePosition);
	float eyedotnorm = dot(eyevec, texnormal.xyz);
	float3 reflectvec = (texnormal.xyz * (eyedotnorm * 2.0)) - eyevec;
	// Reflected color
	float4 color = tex.sample(smp, reflectvec);
	// Fresnel reflection
	float fresnelalpha = 1.0 - abs(eyedotnorm);
	color *= fresnelalpha * fresnelalpha * fresnelalpha;
	// Overbrighten and modulate with vertex color using a mix of regular multiplicative and subtractive alpha
	color.rgb = 2.0 * mix(color.rgb * in.color.rgb,
						   max(float3(0.0), color.rgb + in.color.rgb - float3(1.0)),
						   0.6);
	return hsApplyFog(color, in.eyePosition, fog);
}

// MARK: - Caustic (offscreen generation; no texture, no fog)

fragment float4 hsCausticFragment(HSVaryings in [[stage_in]])
{
	return in.color;
}
