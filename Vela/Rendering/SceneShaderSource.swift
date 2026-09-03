import Foundation

/// Metal source for the reactive scene: artwork backdrop, gradient control points, profile
/// accents (rings, slices, streaks), vignette, grain and the edge light in one full-screen pass,
/// plus an instanced particle pass. Compiled at runtime so no shader toolchain is required.
enum SceneShaderSource {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Keep in sync with SceneUniforms in SceneRenderer.swift.
    struct SceneUniforms {
        float4 resolutionTime;   // width, height (px), time, dt
        float4 bands;            // bass, mid, high, level
        float4 impulses;         // onset, beat, snare, hat
        float4 rhythm;           // kick, beatPhase, bpmConfidence, travelPhase
        float4 background;       // expansion, distortion, blurMix, bloom
        float4 tone;             // vignette, grain, depth, lightIntensity
        float4 motion;           // gradientSpeed, orbit, liquid, compress
        float4 style;            // slices, streaks, ring, mirror
        float4 camera;           // offsetX, offsetY, zoom, artworkFade
        float4 edge;             // thickness px, intensity, spread, cornerRadius px
        float4 edge2;            // travelAmount, breathing, reduceMotion, colorCount
        float4 flags;            // hasPrevArtwork, hasNextArtwork, energy, beatCount
        float4 notch;            // x, y, w, h (px, top-left origin)
        float4 palette[8];       // 0 bg, 1 primary, 2 highlight, 3 glow, 4..7 gradient stops
        float4 blobs[6];         // x, y, radius, colourIndex
        float4 blobIntensity[2];
        float4 particles;        // count, size px, speed, lifetime
        float4 particles2;       // streak, mirror, density, pad
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut sceneVertex(uint vid [[vertex_id]]) {
        float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        VertexOut out;
        out.position = float4(positions[vid], 0.0, 1.0);
        out.uv = float2((positions[vid].x + 1.0) * 0.5, 1.0 - (positions[vid].y + 1.0) * 0.5);
        return out;
    }

    static float hash12(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    static float hash11(float p) {
        p = fract(p * 0.1031);
        p *= p + 33.33;
        p *= p + p;
        return fract(p);
    }

    static float vnoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = hash12(i);
        float b = hash12(i + float2(1.0, 0.0));
        float c = hash12(i + float2(0.0, 1.0));
        float d = hash12(i + float2(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    static float sdRoundedBox(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    static float3 sampleGradient(constant SceneUniforms &u, float t) {
        int n = max(2, int(u.edge2.w));
        float f = fract(t) * float(n);
        int i = int(floor(f)) % n;
        int j = (i + 1) % n;
        float k = smoothstep(0.0, 1.0, fract(f));
        return mix(u.palette[4 + i].rgb, u.palette[4 + j].rgb, k);
    }

    fragment float4 sceneFragment(VertexOut in [[stage_in]],
                                  constant SceneUniforms &u [[buffer(0)]],
                                  texture2d<float> prevSoft [[texture(0)]],
                                  texture2d<float> prevSharp [[texture(1)]],
                                  texture2d<float> nextSoft [[texture(2)]],
                                  texture2d<float> nextSharp [[texture(3)]],
                                  sampler s [[sampler(0)]]) {
        float2 res = u.resolutionTime.xy;
        float t = u.resolutionTime.z;
        float aspect = res.x / res.y;
        float2 uv = in.uv;

        // Camera: zoom and tiny impulses (rock), applied around the centre.
        float2 c = (uv - 0.5) / u.camera.z + u.camera.xy;

        // Restrained flowing distortion, strongest where the profile asks for it.
        float dist = u.background.y;
        float2 warp = float2(vnoise(c * 2.5 + t * 0.12), vnoise(c * 2.5 - t * 0.1 + 7.0)) - 0.5;
        c += warp * dist * 0.07 * (0.5 + u.bands.x);

        // Artwork: aspect-fill of a square texture, breathing with bass.
        float zoom = 1.12 + u.background.x * 0.07;
        float2 fill = aspect >= 1.0 ? float2(c.x, c.y / aspect) : float2(c.x * aspect, c.y);
        float2 auv = clamp(0.5 + fill / zoom, 0.002, 0.998);
        float blurMix = u.background.z;
        float3 bg = u.palette[0].rgb;
        float3 prev = mix(prevSoft.sample(s, auv).rgb, prevSharp.sample(s, auv).rgb, blurMix);
        float3 next = mix(nextSoft.sample(s, auv).rgb, nextSharp.sample(s, auv).rgb, blurMix);
        float3 artwork = mix(mix(bg, prev, u.flags.x), mix(bg, next, u.flags.y), u.camera.w);

        // Base: darkened artwork tinted by the palette background, lifted a little by loudness.
        float3 color = mix(bg, artwork, 0.78) * (0.34 + 0.2 * u.tone.w);
        color = mix(color, bg, 0.12 * u.tone.z);

        // Gradient control points: accumulate their light, cap it, then screen-blend once.
        float bloom = u.background.w;
        float3 light = float3(0.0);
        for (int i = 0; i < 6; i++) {
            float4 blob = u.blobs[i];
            float intensity = (i < 4) ? u.blobIntensity[0][i] : u.blobIntensity[1][i - 4];
            float2 d = uv - blob.xy;
            d.x *= aspect;
            float fall = smoothstep(blob.z, 0.0, length(d));
            fall *= fall;
            int ci = clamp(int(blob.w), 0, 7);
            light += u.palette[ci].rgb * intensity * (0.2 + 0.18 * bloom) * fall;
        }
        float lightLuma = dot(light, float3(0.299, 0.587, 0.114));
        if (lightLuma > 0.45) { light *= 0.45 / lightLuma; }
        color = 1.0 - (1.0 - color) * (1.0 - light);

        // Radial pulse in time with the beat (electronic).
        float ringAmount = u.style.z;
        if (ringAmount > 0.001) {
            float phase = u.rhythm.y;
            float rr = length(c * float2(aspect, 1.0));
            float radius = 0.12 + 0.7 * phase;
            float band = exp(-pow((rr - radius) * 16.0, 2.0));
            float strength = ringAmount * (1.0 - phase) * (0.3 + 0.7 * u.rhythm.z) * 0.32;
            color += u.palette[2].rgb * band * strength;
        }

        // Thin horizontal light slices on hi-hats (rap / trap).
        float slice = u.style.x * u.impulses.w;
        if (slice > 0.001) {
            float y0 = 0.15 + 0.7 * hash11(u.flags.w * 1.37 + 0.5);
            float band = exp(-pow((uv.y - y0) * 70.0, 2.0));
            float sweep = 0.5 + 0.5 * sin(uv.x * 6.283 + t * 2.0);
            color += u.palette[3].rgb * band * slice * 0.22 * sweep;
        }

        // Directional streaks on drum hits (rock / metal).
        float streak = u.style.y * max(u.impulses.z, u.rhythm.x * 0.7);
        if (streak > 0.001) {
            float n = vnoise(float2(uv.x * 1.5 + t * 1.8, uv.y * 36.0));
            float lines = smoothstep(0.7, 0.97, n);
            color += u.palette[2].rgb * lines * streak * 0.1;
        }

        // Vignette and grain.
        float2 vc = c * float2(aspect, 1.0);
        color *= 1.0 - u.tone.x * smoothstep(0.32, 1.15, length(vc) * 1.05);
        float grain = u.tone.y;
        float noise = hash12(in.uv * res + fract(t) * 97.0) - 0.5;
        color += noise * grain * 0.4;

        // Edge light.
        float2 px = in.uv * res;
        float2 halfSize = res * 0.5;
        float2 p = px - halfSize;
        float d = -sdRoundedBox(p, halfSize, u.edge.w);
        if (u.notch.z > 0.0) {
            float2 notchCenter = u.notch.xy + u.notch.zw * 0.5;
            float2 notchHalf = u.notch.zw * 0.5;
            float dn = sdRoundedBox(px - notchCenter, notchHalf, 6.0);
            d = min(d, max(dn, 0.0));
        }
        d = max(d, 0.0);
        float reduce = u.edge2.z;
        float speed = mix(0.017, 0.005, reduce);
        float angle = atan2(p.y, p.x) / (2.0 * M_PI_F);
        float wobble = (1.0 - 0.65 * reduce) * u.bands.y * 0.05 * sin(t * 0.8 + angle * 12.566);
        float travel = u.edge2.x;
        float gt = angle + t * speed * (1.0 - travel) + u.rhythm.w * travel + wobble;
        float3 glowColor = sampleGradient(u, gt);
        // Integer multiples of the angle keep the gradient continuous across the atan2 seam.
        float3 second = sampleGradient(u, gt * 2.0 + 0.37 - t * speed * 0.6);
        glowColor = mix(glowColor, second, 0.35 + 0.15 * sin(t * 0.25 + angle * 6.283));
        // A bright band that travels around the rim on the beat (electronic).
        float head = fract(angle - u.rhythm.w);
        float headDistance = min(head, 1.0 - head);
        float traveller = exp(-pow(headDistance * 9.0, 2.0)) * travel * (0.5 + 0.5 * u.impulses.y);

        float breathing = u.edge2.y;
        float breath = 0.5 + 0.5 * sin(t * 0.85);
        float bassDrive = mix(u.bands.x * 0.8 + u.rhythm.x * 0.6, breath * 0.55, breathing);
        float levelDrive = mix(u.bands.w, 0.35 + 0.3 * breath, breathing);
        float highDrive = mix(u.bands.z, 0.0, breathing);

        float thick = u.edge.x * (1.0 + 0.85 * bassDrive);
        float core = exp(-d / thick);
        float halo = exp(-d / (thick * 2.6 * u.edge.z)) * (0.22 + 0.18 * bassDrive);
        float shimmer = 1.0 + highDrive * 0.12 * sin(angle * 40.0 + t * 3.0);
        float bright = u.edge.y * (0.4 + 0.5 * levelDrive) * shimmer * (1.0 + traveller * 0.8);
        float glow = clamp((core + halo) * bright, 0.0, 1.0);
        glowColor = mix(glowColor, float3(1.0), core * 0.16 * bright);
        float gnoise = (hash12(px + fract(t) * 53.0) - 0.5) / 96.0;
        glow = clamp(glow + gnoise * glow, 0.0, 1.0);
        float alpha = clamp(core * bright * 0.85, 0.0, 1.0);
        color = color * (1.0 - alpha) + glowColor * glow;

        // Readability ceiling: whatever the music does, the area behind the lyrics stays dark
        // enough for the text. The ceiling relaxes toward the rim so the edge light keeps its
        // colour. Soft compression, so bright moments roll off instead of clipping.
        float rim = smoothstep(0.55, 1.05, length(vc));
        float ceilingLuma = mix(0.36, 0.72, rim);
        float luma = dot(color, float3(0.299, 0.587, 0.114));
        color *= 1.0 / (1.0 + max(0.0, luma - ceilingLuma) * 3.0);

        return float4(color, 1.0);
    }

    // MARK: Particles

    struct ParticleOut {
        float4 position [[position]];
        float2 local;
        float alpha;
        float3 color;
    };

    vertex ParticleOut particleVertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant SceneUniforms &u [[buffer(0)]]) {
        float2 corners[6] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0) };
        float2 corner = corners[vid];
        float t = u.resolutionTime.z;
        float size = u.particles.y;
        float speed = u.particles.z;
        float life = max(0.5, u.particles.w);
        float streak = u.particles2.x;
        float mirror = u.particles2.y;
        float fi = float(iid);
        float seed = hash11(fi * 1.618 + 0.7);
        float seedX = hash11(fi * 2.71 + 3.0);
        float seedY = hash11(fi * 0.37 + 9.0);
        float progress = fract((t * (0.35 + 0.45 * speed)) / life + seed);
        float2 dir = mix(float2(0.02, -1.0), float2(1.0, -0.12), streak);
        float2 pos = float2(seedX, seedY) + dir * progress * (0.14 + 0.3 * speed) * 0.5;
        pos.x += sin(t * 0.6 + seed * 6.283) * 0.02 * (1.0 - streak);
        pos = fract(pos);
        if (mirror > 0.5 && (iid % 2u) == 1u) { pos.x = 1.0 - pos.x; }
        float envelope = sin(progress * 3.14159);
        float aspect = u.resolutionTime.x / u.resolutionTime.y;
        float centreDistance = length((pos - 0.5) * float2(aspect, 1.0));
        float centreFade = 0.3 + 0.7 * smoothstep(0.12, 0.55, centreDistance);
        float alpha = envelope * (0.16 + 0.4 * u.flags.z) * 0.42 * centreFade;
        float2 scale = float2(size * (1.0 + streak * 4.0), size) / u.resolutionTime.xy;
        float2 ndc = (pos * 2.0 - 1.0) * float2(1.0, -1.0) + corner * scale * 2.0;
        ParticleOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.local = corner;
        out.alpha = alpha;
        int ci = 2 + int(iid % 2u);
        out.color = u.palette[ci].rgb;
        return out;
    }

    fragment float4 particleFragment(ParticleOut in [[stage_in]]) {
        float d = length(in.local);
        float a = smoothstep(1.0, 0.15, d) * in.alpha;
        return float4(in.color * a, a);
    }
    """
}
