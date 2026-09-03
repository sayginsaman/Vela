import Foundation

/// Metal source for the edge glow. Compiled at runtime with `MTLDevice.makeLibrary(source:)` so
/// the project builds on Macs without the Metal shader toolchain installed; the compile happens
/// once, at first use, and takes a few milliseconds.
enum EdgeGlowShaderSource {
    static let source = """
#include <metal_stdlib>
using namespace metal;

// Keep in sync with GlowUniforms in EdgeGlowRenderer.swift.
struct GlowUniforms {
    float2 resolution;
    float time;
    float bass;
    float mid;
    float high;
    float level;
    float thickness;
    float intensity;
    float spread;
    float cornerRadius;
    float motion;
    float reduceMotion;
    float breathing;
    float colorCount;
    float pad0;
    float4 notch;        // x, y, width, height in pixels (top-left origin); width 0 = none
    float4 colors[6];
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut glowVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = float2((positions[vid].x + 1.0) * 0.5, 1.0 - (positions[vid].y + 1.0) * 0.5);
    return out;
}

static float sdRoundedBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float3 sampleGradient(constant GlowUniforms &u, float t) {
    int n = max(2, int(u.colorCount));
    float f = fract(t) * float(n);
    int i = int(floor(f)) % n;
    int j = (i + 1) % n;
    float k = smoothstep(0.0, 1.0, fract(f));
    return mix(u.colors[i].rgb, u.colors[j].rgb, k);
}

fragment float4 glowFragment(VertexOut in [[stage_in]], constant GlowUniforms &u [[buffer(0)]]) {
    float2 px = in.uv * u.resolution;
    float2 halfSize = u.resolution * 0.5;
    float2 p = px - halfSize;

    // Distance inward from the (rounded) display edge.
    float d = -sdRoundedBox(p, halfSize, u.cornerRadius);
    if (u.notch.z > 0.0) {
        float2 notchCenter = u.notch.xy + u.notch.zw * 0.5;
        float2 notchHalf = u.notch.zw * 0.5;
        float dn = sdRoundedBox(px - notchCenter, notchHalf, 6.0);
        d = min(d, max(dn, 0.0));
    }
    d = max(d, 0.0);

    float reduce = u.reduceMotion;
    float motion = u.motion * (1.0 - 0.65 * reduce);
    float speed = mix(0.017, 0.005, reduce);
    float angle = atan2(p.y, p.x) / (2.0 * M_PI_F);
    float wobble = motion * u.mid * 0.05 * sin(u.time * 0.8 + angle * 12.566);
    float t = angle + u.time * speed + wobble;

    float3 color = sampleGradient(u, t);
    float3 second = sampleGradient(u, t * 0.5 + 0.37 - u.time * speed * 0.6);
    color = mix(color, second, 0.35 + 0.15 * sin(u.time * 0.25 + angle * 6.283));

    // Drivers: real audio, or a slow breath when no audio is available.
    float breath = 0.5 + 0.5 * sin(u.time * 0.85);
    float bassDrive = mix(u.bass * motion, breath * 0.55, u.breathing);
    float levelDrive = mix(u.level, 0.35 + 0.3 * breath, u.breathing);
    float highDrive = mix(u.high * motion, 0.0, u.breathing);

    float thick = u.thickness * (1.0 + 0.85 * bassDrive);
    float core = exp(-d / thick);
    float halo = exp(-d / (thick * 2.6 * u.spread)) * (0.30 + 0.25 * bassDrive);
    float shimmer = 1.0 + highDrive * 0.12 * sin(angle * 40.0 + u.time * 3.0);
    float bright = u.intensity * (0.42 + 0.58 * levelDrive) * shimmer;
    float glow = clamp((core + halo) * bright, 0.0, 1.0);

    // A touch of white at the very rim keeps saturated palettes from looking flat.
    color = mix(color, float3(1.0), core * 0.16 * bright);

    // Dither to avoid banding in the halo.
    float noise = (hash12(px + fract(u.time) * 97.0) - 0.5) / 96.0;
    glow = clamp(glow + noise * glow, 0.0, 1.0);

    // Only the dense core occludes the backdrop; the wide halo is purely additive light, so the
    // artwork keeps showing through instead of being replaced by a flat band.
    float alpha = clamp(core * bright * 0.85, 0.0, 1.0);
    return float4(color * glow, alpha);
}
"""
}
