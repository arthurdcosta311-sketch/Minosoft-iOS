#include <metal_stdlib>
using namespace metal;

// Nio's slice: the world pass. Vertices arrive already shaded and lit
// (ChunkMeshBuilder bakes the face shade and section light), so this shader
// only projects, applies the light, and fogs toward the sky colour.

struct WorldVertex {
    packed_float3 position;
    packed_float4 color;
    float light;
};

struct WorldUniforms {
    float4x4 viewProjection;
    float4 cameraPosition;
    float4 fogColour;
    float2 fogRange;
};

struct WorldVertexOut {
    float4 position [[position]];
    float4 color;
    float distance;
};

vertex WorldVertexOut world_vertex(const device WorldVertex *vertices [[buffer(0)]],
                                   constant WorldUniforms &uniforms [[buffer(1)]],
                                   uint vertexId [[vertex_id]]) {
    const WorldVertex worldVertex = vertices[vertexId];
    const float3 position = float3(worldVertex.position);

    WorldVertexOut out;
    out.position = uniforms.viewProjection * float4(position, 1.0);
    out.color = float4(worldVertex.color.rgb * worldVertex.light, worldVertex.color.a);
    out.distance = length(position - uniforms.cameraPosition.xyz);
    return out;
}

fragment float4 world_fragment(WorldVertexOut in [[stage_in]],
                               constant WorldUniforms &uniforms [[buffer(1)]]) {
    const float start = uniforms.fogRange.x;
    const float end = max(uniforms.fogRange.y, start + 1.0);
    const float fog = saturate((in.distance - start) / (end - start));
    const float3 rgb = mix(in.color.rgb, uniforms.fogColour.rgb, fog);
    return float4(rgb, in.color.a);
}
