// Copyright (c) 2012-2022 Wojciech Figat. All rights reserved.

// Diffuse-only lighting
#define NO_SPECULAR

#include "./Flax/Common.hlsl"
#include "./Flax/Math.hlsl"
#include "./Flax/LightingCommon.hlsl"
#include "./Flax/GlobalSignDistanceField.hlsl"
#include "./Flax/GI/GlobalSurfaceAtlas.hlsl"

META_CB_BEGIN(0, Data)
float3 ViewWorldPos;
float ViewNearPlane;
float Padding00;
uint CulledObjectsCapacity;
float LightShadowsStrength;
float ViewFarPlane;
float4 ViewFrustumWorldRays[4];
GlobalSDFData GlobalSDF;
GlobalSurfaceAtlasData GlobalSurfaceAtlas;
LightData Light;
META_CB_END

struct AtlasVertexInput
{
	float2 Position : POSITION0;
	float2 TileUV : TEXCOORD0;
	uint TileAddress : TEXCOORD1;
};

struct AtlasVertexOutput
{
	float4 Position : SV_Position;
	float2 TileUV : TEXCOORD0;
	nointerpolation uint TileAddress : TEXCOORD1;
};

// Vertex shader for Global Surface Atlas rendering (custom vertex buffer to render per-tile)
META_VS(true, FEATURE_LEVEL_SM5)
META_VS_IN_ELEMENT(POSITION, 0, R16G16_FLOAT, 0, ALIGN, PER_VERTEX, 0, true)
META_VS_IN_ELEMENT(TEXCOORD, 0, R16G16_FLOAT, 0, ALIGN, PER_VERTEX, 0, true)
META_VS_IN_ELEMENT(TEXCOORD, 1, R32_UINT,  0, ALIGN, PER_VERTEX, 0, true)
AtlasVertexOutput VS_Atlas(AtlasVertexInput input)
{
	AtlasVertexOutput output;
	output.Position = float4(input.Position, 1, 1);
	output.TileUV = input.TileUV;
	output.TileAddress = input.TileAddress;
	return output;
}

// Pixel shader for Global Surface Atlas software clearing
META_PS(true, FEATURE_LEVEL_SM5)
void PS_Clear(out float4 Light : SV_Target0, out float4 RT0 : SV_Target1, out float4 RT1 : SV_Target2, out float4 RT2 : SV_Target3)
{
	Light = float4(0, 0, 0, 0);
	RT0 = float4(0, 0, 0, 0);
	RT1 = float4(0, 0, 0, 0);
	RT2 = float4(1, 0, 0, 0);
}

#ifdef _PS_DirectLighting

#include "./Flax/GBuffer.hlsl"
#include "./Flax/Matrix.hlsl"
#include "./Flax/Lighting.hlsl"

// GBuffer+Depth at 0-3 slots
Buffer<float4> GlobalSurfaceAtlasObjects : register(t4);
Texture3D<float> GlobalSDFTex[4] : register(t5);
Texture3D<float> GlobalSDFMip[4] : register(t9);

// Pixel shader for Global Surface Atlas shading with direct light contribution
META_PS(true, FEATURE_LEVEL_SM5)
META_PERMUTATION_1(RADIAL_LIGHT=0)
META_PERMUTATION_1(RADIAL_LIGHT=1)
float4 PS_DirectLighting(AtlasVertexOutput input) : SV_Target
{
	// Load current tile info
	GlobalSurfaceTile tile = LoadGlobalSurfaceAtlasTile(GlobalSurfaceAtlasObjects, input.TileAddress);
	float2 atlasUV = input.TileUV * tile.AtlasRectUV.zw + tile.AtlasRectUV.xy;

	// Load GBuffer sample from atlas
	GBufferData gBufferData = (GBufferData)0;
	GBufferSample gBuffer = SampleGBuffer(gBufferData, atlasUV);
	BRANCH
	if (gBuffer.ShadingModel == SHADING_MODEL_UNLIT)
	{
		// Skip unlit pixels
		discard;
		return 0;
	}

	// Reconstruct world-space position manually (from uv+depth within a tile)
	float tileDepth = SampleZ(atlasUV);
	//float tileNear = -GLOBAL_SURFACE_ATLAS_TILE_PROJ_PLANE_OFFSET;
	//float tileFar = tile.ViewBoundsSize.z + 2 * GLOBAL_SURFACE_ATLAS_TILE_PROJ_PLANE_OFFSET;
	//gBufferData.ViewInfo.zw = float2(tileFar / (tileFar - tileNear), (-tileFar * tileNear) / (tileFar - tileNear) / tileFar);
	//gBufferData.ViewInfo.zw = float2(1, 0);
	//float tileLinearDepth = LinearizeZ(gBufferData, tileDepth);
	float3 tileSpacePos = float3(input.TileUV.x - 0.5f, 0.5f - input.TileUV.y, tileDepth);
	float3 gBufferTilePos = tileSpacePos * tile.ViewBoundsSize;
	float4x4 tileLocalToWorld = Inverse(tile.WorldToLocal);
	gBuffer.WorldPos = mul(float4(gBufferTilePos, 1), tileLocalToWorld).xyz;

	// Calculate shadowing
	float3 L = Light.Direction;
#if RADIAL_LIGHT
	float3 toLight = Light.Position - gBuffer.WorldPos;
	float toLightDst = length(toLight);
	if (toLightDst >= Light.Radius)
	{
		// Skip texels outside the light influence range
		discard;
		return 0;
	}
	L = toLight / toLightDst;
#else
	float toLightDst = GLOBAL_SDF_WORLD_SIZE;
#endif
	float4 shadowMask = 1;
	if (Light.CastShadows > 0)
	{
		float NoL = dot(gBuffer.Normal, L);
		float shadowBias = 10.0f;
		float bias = 2 * shadowBias * saturate(1 - NoL) + shadowBias;
		BRANCH
		if (NoL > 0)
		{
			// TODO: try using shadow map for on-screen pixels
			// TODO: try using cone trace with Global SDF for smoother shadow (eg. for sun shadows or for area lights)

			// Shot a ray from texel into the light to see if there is any occluder
			GlobalSDFTrace trace;
			trace.Init(gBuffer.WorldPos + gBuffer.Normal * shadowBias, L, bias, toLightDst - bias);
			GlobalSDFHit hit = RayTraceGlobalSDF(GlobalSDF, GlobalSDFTex, GlobalSDFMip, trace);
			shadowMask = hit.IsHit() ? LightShadowsStrength : 1;
		}
		else
		{
			shadowMask = 0;
		}
	}

	// Calculate lighting
#if RADIAL_LIGHT
	bool isSpotLight = Light.SpotAngles.x > -2.0f;
#else
	bool isSpotLight = false;
#endif
	float4 light = GetLighting(ViewWorldPos, Light, gBuffer, shadowMask, RADIAL_LIGHT, isSpotLight);

	return light;
}

#endif

#if defined(_CS_CullObjects)

#include "./Flax/Collisions.hlsl"

RWByteAddressBuffer RWGlobalSurfaceAtlasChunks : register(u0);
RWBuffer<float4> RWGlobalSurfaceAtlasCulledObjects : register(u1);
Buffer<float4> GlobalSurfaceAtlasObjects : register(t0);

// Compute shader for culling objects into chunks
META_CS(true, FEATURE_LEVEL_SM5)
[numthreads(GLOBAL_SURFACE_ATLAS_CHUNKS_GROUP_SIZE, GLOBAL_SURFACE_ATLAS_CHUNKS_GROUP_SIZE, GLOBAL_SURFACE_ATLAS_CHUNKS_GROUP_SIZE)]
void CS_CullObjects(uint3 GroupId : SV_GroupID, uint3 DispatchThreadId : SV_DispatchThreadID, uint3 GroupThreadId : SV_GroupThreadID)
{
	uint3 chunkCoord = DispatchThreadId;
	uint chunkAddress = (chunkCoord.z * (GLOBAL_SURFACE_ATLAS_CHUNKS_RESOLUTION * GLOBAL_SURFACE_ATLAS_CHUNKS_RESOLUTION) + chunkCoord.y * GLOBAL_SURFACE_ATLAS_CHUNKS_RESOLUTION + chunkCoord.x) * 4;
	if (chunkAddress == 0)
		return; // Skip chunk at 0,0,0 (used for counter)
	float3 chunkMin = GlobalSurfaceAtlas.ViewPos + (chunkCoord - (GLOBAL_SURFACE_ATLAS_CHUNKS_RESOLUTION * 0.5f)) * GlobalSurfaceAtlas.ChunkSize;
	float3 chunkMax = chunkMin + GlobalSurfaceAtlas.ChunkSize;

	// Count objects data size in this chunk (amount of float4s)
	uint objectsSize = 0, objectAddress = 0, objectsCount = 0;
	// TODO: maybe cache 20-30 culled object indices in thread memory to skip culling them again when copying data (maybe reude chunk size to get smaller objects count per chunk)?
	LOOP
	for (uint objectIndex = 0; objectIndex < GlobalSurfaceAtlas.ObjectsCount; objectIndex++)
	{
		float4 objectBounds = LoadGlobalSurfaceAtlasObjectBounds(GlobalSurfaceAtlasObjects, objectAddress);
		uint objectSize = LoadGlobalSurfaceAtlasObjectDataSize(GlobalSurfaceAtlasObjects, objectAddress);
		if (BoxIntersectsSphere(chunkMin, chunkMax, objectBounds.xyz, objectBounds.w))
		{
			objectsSize += objectSize;
			objectsCount++;
		}
		objectAddress += objectSize;
	}
	if (objectsSize == 0)
	{
		// Empty chunk
		RWGlobalSurfaceAtlasChunks.Store(chunkAddress, 0);
		return;
	}
	objectsSize++; // Include objects count before actual objects data

	// Allocate object data size in the buffer
	uint objectsStart;
	RWGlobalSurfaceAtlasChunks.InterlockedAdd(0, objectsSize, objectsStart);
	if (objectsStart + objectsSize > CulledObjectsCapacity)
	{
		// Not enough space in the buffer
		RWGlobalSurfaceAtlasChunks.Store(chunkAddress, 0);
		return;
	}

	// Write object data start
	RWGlobalSurfaceAtlasChunks.Store(chunkAddress, objectsStart);

	// Write objects count before actual objects data
	RWGlobalSurfaceAtlasCulledObjects[objectsStart] = float4(asfloat(objectsCount), 0, 0, 0);
	objectsStart++;

	// Copy objects data in this chunk
	objectAddress = 0;
	LOOP
	for (uint objectIndex = 0; objectIndex < GlobalSurfaceAtlas.ObjectsCount; objectIndex++)
	{
		float4 objectBounds = LoadGlobalSurfaceAtlasObjectBounds(GlobalSurfaceAtlasObjects, objectAddress);
		uint objectSize = LoadGlobalSurfaceAtlasObjectDataSize(GlobalSurfaceAtlasObjects, objectAddress);
		if (BoxIntersectsSphere(chunkMin, chunkMax, objectBounds.xyz, objectBounds.w))
		{
			for (uint i = 0; i < objectSize; i++)
			{
				RWGlobalSurfaceAtlasCulledObjects[objectsStart + i] = GlobalSurfaceAtlasObjects[objectAddress + i];
			}
			objectsStart += objectSize;
		}
		objectAddress += objectSize;
	}
}

#endif

#ifdef _PS_Debug

Texture3D<float> GlobalSDFTex[4] : register(t0);
Texture3D<float> GlobalSDFMip[4] : register(t4);
ByteAddressBuffer GlobalSurfaceAtlasChunks : register(t8);
Buffer<float4> GlobalSurfaceAtlasCulledObjects : register(t9);
Texture2D GlobalSurfaceAtlasDepth : register(t10);
Texture2D GlobalSurfaceAtlasTex : register(t11);

// Pixel shader for Global Surface Atlas debug drawing
META_PS(true, FEATURE_LEVEL_SM5)
float4 PS_Debug(Quad_VS2PS input) : SV_Target
{
#if 0
	// Preview Global Surface Atlas texture
	return float4(GlobalSurfaceAtlasTex.SampleLevel(SamplerLinearClamp, input.TexCoord, 0).rgb, 1);
#endif

	// Shot a ray from camera into the Global SDF
	GlobalSDFTrace trace;
	float3 viewRay = lerp(lerp(ViewFrustumWorldRays[3], ViewFrustumWorldRays[0], input.TexCoord.x), lerp(ViewFrustumWorldRays[2], ViewFrustumWorldRays[1], input.TexCoord.x), 1 - input.TexCoord.y).xyz;
	viewRay = normalize(viewRay - ViewWorldPos);
	trace.Init(ViewWorldPos, viewRay, ViewNearPlane, ViewFarPlane);
	trace.NeedsHitNormal = true;
	GlobalSDFHit hit = RayTraceGlobalSDF(GlobalSDF, GlobalSDFTex, GlobalSDFMip, trace);
	if (!hit.IsHit())
		return float4(float3(0.4f, 0.4f, 1.0f) * saturate(hit.StepsCount / 80.0f), 1);
	//return float4(hit.HitNormal * 0.5f + 0.5f, 1);

	// Sample Global Surface Atlas at the hit location
	float surfaceThreshold = hit.HitCascade * 10.0f + 20.0f; // Scale the threshold based on the hit cascade (less precision)
	float4 surfaceColor = SampleGlobalSurfaceAtlas(GlobalSurfaceAtlas, GlobalSurfaceAtlasChunks, GlobalSurfaceAtlasCulledObjects, GlobalSurfaceAtlasDepth, GlobalSurfaceAtlasTex, hit.GetHitPosition(trace), -viewRay, surfaceThreshold);
	return float4(surfaceColor.rgb, 1);
}

#endif