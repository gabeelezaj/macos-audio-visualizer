#include <metal_stdlib>
using namespace metal;

// Layout must match Uniforms in Renderer.swift (24 floats, then 4 float4s).
struct Uniforms {
    float2 resolution;
    float time;
    float dt;
    float level;
    float bass;
    float mid;
    float treble;
    float beat;
    float beatPhase;
    float tempoPhase;      // continuous, one unit per beat at the tracked tempo
    float bpm;             // 0 until a tempo is established
    float sensitivity;
    float trail;
    float hue;
    float edrScale;
    float aspect;
    float stereoWidth;     // 0 = mono, 1+ = wide
    float balance;         // -1 hard left ... +1 hard right
    float idle;            // 1 while the idle animation is driving things
    float spectrogramCursor;
    float tempoConfidence;
    float pad0;
    float pad1;
    float4 palette[4];
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;      // 0...1, y up
};

// ---------------------------------------------------------------- fullscreen
vertex VertexOut fullscreen_vertex(uint vid [[vertex_id]]) {
    const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    VertexOut out;
    float2 p = corners[vid];
    out.position = float4(p, 0.0, 1.0);
    out.uv = p * 0.5 + 0.5;
    return out;
}

// ------------------------------------------------------------------- helpers
constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
/// The spectrogram is a ring buffer in its vertical axis, so time must wrap.
constexpr sampler historySampler(filter::linear, s_address::clamp_to_edge, t_address::repeat);

static inline float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    return fract(p * (p + p));
}

static inline float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

static inline float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static inline float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float fbm(float2 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    float2x2 rot = float2x2(0.8, 0.6, -0.6, 0.8);
    for (int i = 0; i < octaves; ++i) {
        value += amplitude * valueNoise(p);
        p = rot * p * 2.02;
        amplitude *= 0.5;
    }
    return value;
}

/// Four-stop gradient with wrap-around so `t` can run continuously.
static inline float3 paletteColor(float t, constant Uniforms &u) {
    t = fract(t + u.hue);
    float scaled = t * 4.0;
    int index = int(floor(scaled)) & 3;
    int next = (index + 1) & 3;
    float f = fract(scaled);
    f = f * f * (3.0 - 2.0 * f);
    return mix(u.palette[index].rgb, u.palette[next].rgb, f);
}

/// Both data textures carry left in .r and right in .g.
static inline float2 spectrumStereo(texture2d<float> spectrum, float t) {
    return spectrum.sample(linearSampler, float2(clamp(t, 0.0, 1.0), 0.5)).rg;
}

static inline float spectrumAt(texture2d<float> spectrum, float t) {
    float2 lr = spectrumStereo(spectrum, t);
    return (lr.x + lr.y) * 0.5;
}

/// Five-tap blur across neighbouring bands.
///
/// Reading one band per pixel turns the FFT's natural bin-to-bin jitter into hard
/// vertical banding wherever the spectrum is mapped across space. Anything smooth
/// and organic samples through here instead.
static inline float spectrumSmooth(texture2d<float> spectrum, float t, float radius) {
    float sum = spectrumAt(spectrum, t) * 0.34;
    sum += (spectrumAt(spectrum, t - radius) + spectrumAt(spectrum, t + radius)) * 0.22;
    sum += (spectrumAt(spectrum, t - radius * 2.0) + spectrumAt(spectrum, t + radius * 2.0)) * 0.11;
    return sum;
}

static inline float2 waveStereo(texture2d<float> wave, float t) {
    return wave.sample(linearSampler, float2(clamp(t, 0.0, 1.0), 0.5)).rg;
}

static inline float waveAt(texture2d<float> wave, float t) {
    float2 lr = waveStereo(wave, t);
    return (lr.x + lr.y) * 0.5;
}

/// Centred, aspect-corrected coordinates: y in -0.5...0.5.
static inline float2 centred(float2 uv, constant Uniforms &u) {
    float2 p = uv - 0.5;
    p.x *= u.aspect;
    return p;
}

/// Screen-space antialiasing width for a scalar field.
static inline float aaWidth(float value) {
    return max(fwidth(value), 1e-5);
}

static inline float3 glowLine(float distance, float width, float3 color) {
    float core = smoothstep(width, 0.0, distance);
    float halo = width * 2.5 / (distance + width * 2.5);
    return color * (core * 1.5 + pow(halo, 3.0) * 0.85);
}

/// Antialiased line wherever `value` crosses an integer.
static inline float gridLine(float value, float thickness) {
    float d = abs(fract(value) - 0.5);
    float w = aaWidth(value);
    return smoothstep(0.5 - thickness - w, 0.5, d);
}

// ================================================================== 1. AURORA
// Luminous ribbons drifting over a dark nebula — the slow "now playing" look.
fragment float4 aurora_fragment(VertexOut in [[stage_in]],
                                constant Uniforms &u [[buffer(0)]],
                                texture2d<float> spectrum [[texture(0)]],
                                texture2d<float> wave [[texture(1)]],
                                texture2d<float> history [[texture(2)]]) {
    float2 p = centred(in.uv, u);
    float t = u.time * 0.06;

    // Deep base wash so the ribbons have something to glow against.
    float3 color = mix(u.palette[0].rgb * 0.50, u.palette[0].rgb * 0.10, saturate(in.uv.y * 1.15));

    float clouds = fbm(p * 1.7 + float2(t * 0.55, -t * 0.32), 4);
    color += paletteColor(0.44 + clouds * 0.28, u) * clouds * clouds * (0.14 + u.level * 0.28);

    const int ribbonCount = 5;
    for (int i = 0; i < ribbonCount; ++i) {
        float fi = float(i);
        // Each ribbon owns a slice of the spectrum: low ribbons ride the bass.
        float band = spectrumSmooth(spectrum, 0.07 + fi * 0.20, 0.03);
        float phase = fi * 1.93;

        float y = (fi - 2.0) * 0.112 * (1.0 + u.stereoWidth * 0.35);
        y += u.balance * 0.05 * (fi - 2.0);
        y += 0.080 * sin(p.x * 2.3 + t * 2.6 + phase);
        y += 0.052 * sin(p.x * 4.1 - t * 1.7 + phase * 1.6);
        y += (fbm(float2(p.x * 1.1 + t * 0.9 + fi * 7.0, t * 0.6), 3) - 0.5)
             * (0.18 + u.bass * 0.26);

        float thickness = 0.028 + band * 0.070 + u.beat * 0.010;
        float d = abs(p.y - y);
        float glow = thickness / (d + thickness);
        glow = glow * glow * glow;

        float3 tint = paletteColor(0.18 + fi * 0.17 + band * 0.14, u);
        color += tint * glow * (0.26 + band * 1.15);
    }

    color += paletteColor(0.78, u) * u.beat * 0.14 * exp(-length(p) * 2.4);
    color *= 1.0 - 0.55 * smoothstep(0.30, 0.95, length(p * float2(0.85, 1.15)));
    return float4(color, 1.0);
}

// ==================================================================== 2. BARS
// Mirrored log-frequency spectrum with peak caps and under-glow.
fragment float4 bars_fragment(VertexOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              texture2d<float> spectrum [[texture(0)]],
                              texture2d<float> wave [[texture(1)]],
                              texture2d<float> history [[texture(2)]]) {
    const float barCount = 56.0;
    float2 uv = in.uv;

    float slot = uv.x * barCount;
    float index = floor(slot);
    float inBar = fract(slot);
    float centre = (index + 0.5) / barCount;

    // Top half draws the left channel, bottom half the right. Mono material stays
    // perfectly symmetric; anything with a stereo image visibly leans.
    float2 channels = spectrumStereo(spectrum, centre);
    float channelValue = uv.y >= 0.5 ? channels.x : channels.y;
    float value = pow(saturate(channelValue), 0.88) * 0.86;

    // Rounded ends: shrink the bar's half-width near its tip.
    float gap = smoothstep(0.0, 0.14, inBar) * smoothstep(1.0, 0.86, inBar);

    float distanceFromMid = abs(uv.y - 0.5) * 2.0;
    float edge = 3.0 / u.resolution.y;
    float bar = smoothstep(value + edge, value - edge, distanceFromMid) * gap;

    // Stay inside the saturated middle of the palette; the pale stop blows out.
    float3 tint = paletteColor(0.12 + centre * 0.58, u);
    float3 color = tint * bar * (0.42 + value * 0.85);

    float cap = smoothstep(0.030, 0.0, abs(distanceFromMid - value)) * gap;
    color += mix(tint, float3(1.0), 0.45) * cap * (0.55 + u.beat * 0.45);

    float spill = exp(-max(0.0, distanceFromMid - value) * 11.0) * gap;
    color += tint * spill * (0.20 + value * 0.35);

    color += tint * exp(-distanceFromMid * 7.0) * value * 0.16;
    color += u.palette[0].rgb * 0.10;

    color *= 1.0 - 0.35 * smoothstep(0.45, 1.0, length(centred(uv, u)));
    return float4(color, 1.0);
}

// ================================================================ 3. WAVEFORM
// Triggered oscilloscope with chromatic offset copies.
fragment float4 waveform_fragment(VertexOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(0)]],
                                  texture2d<float> spectrum [[texture(0)]],
                                  texture2d<float> wave [[texture(1)]],
                                texture2d<float> history [[texture(2)]]) {
    float2 uv = in.uv;
    float amplitude = 0.16 + u.level * 0.22;
    float thickness = 0.0030 + 0.005 * u.level + u.beat * 0.003;

    float3 color = float3(0.0);
    // Three copies pulled apart in colour and position — a scope with fringing.
    for (int i = 0; i < 3; ++i) {
        float slot = float(i) - 1.0;
        float offset = slot * (0.004 + u.treble * 0.014);
        float sample = waveAt(wave, uv.x + offset * 0.4);
        float y = 0.5 + sample * amplitude + offset * 0.5;
        float d = abs(uv.y - y);
        float3 tint = paletteColor(0.20 + float(i) * 0.30, u);
        color += glowLine(d, thickness, tint) * (i == 1 ? 1.0 : 0.5);
    }

    float ghostSample = waveAt(wave, 1.0 - uv.x);
    float ghostY = 0.5 - ghostSample * amplitude * 0.55;
    color += glowLine(abs(uv.y - ghostY), thickness * 1.7, paletteColor(0.66, u)) * 0.14;

    color += paletteColor(0.5, u) * 0.045 * exp(-abs(uv.y - 0.5) * 16.0);

    // Smoothed spectrum haze so the backdrop doesn't turn into a picket fence.
    float haze = spectrumSmooth(spectrum, uv.x, 0.02);
    color += paletteColor(0.10 + uv.x * 0.45, u) * haze * haze * 0.14
             * smoothstep(0.9, 0.1, abs(uv.y - 0.5) * 2.0);

    color += u.palette[0].rgb * 0.07;
    color *= 1.0 - 0.45 * smoothstep(0.35, 0.95, length(centred(uv, u)));
    return float4(color, 1.0);
}

// =================================================================== 4. RADIAL
// Polar spectrum: a pulsing flower with rays and beat shockwaves.
fragment float4 radial_fragment(VertexOut in [[stage_in]],
                                constant Uniforms &u [[buffer(0)]],
                                texture2d<float> spectrum [[texture(0)]],
                                texture2d<float> wave [[texture(1)]],
                                texture2d<float> history [[texture(2)]]) {
    float2 p = centred(in.uv, u);
    float r = length(p);
    float angle = atan2(p.y, p.x);
    float spin = u.time * 0.04 + u.beatPhase * 0.02;

    // Mirrored mapping: symmetric petals, and continuous across atan2's branch cut.
    float t = abs(fract((angle + spin) / (2.0 * M_PI_F) + 0.5) * 2.0 - 1.0);
    float value = spectrumSmooth(spectrum, t, 0.010);

    float inner = 0.150 + u.bass * 0.045 + u.beat * 0.018;
    float petal = inner + value * 0.30;
    float aa = aaWidth(r) * 1.5;

    float3 tint = paletteColor(0.12 + t * 0.55, u);
    float3 color = float3(0.0);

    float body = smoothstep(petal + aa, petal - aa, r);
    color += tint * body * (0.16 + value * 0.65);

    color += mix(tint, float3(1.0), 0.40)
           * smoothstep(aa * 4.0, 0.0, abs(r - petal)) * (0.45 + value * 0.8);

    float rays = pow(saturate(value), 2.0) * exp(-max(0.0, r - petal) * 6.5);
    color += tint * rays * 0.30;

    // Hot core, blended over the filled body rather than cut out of it.
    float coreFalloff = r / (inner * 0.55);
    float core = exp(-coreFalloff * coreFalloff);
    color += mix(paletteColor(0.34, u), float3(1.0), 0.45) * core * (0.65 + u.level * 1.25);

    float shockRadius = inner + (1.0 - u.beat) * 0.48;
    color += paletteColor(0.80, u) * smoothstep(0.022, 0.0, abs(r - shockRadius)) * u.beat * 0.45;

    color += u.palette[0].rgb * 0.09;
    color *= 1.0 - 0.4 * smoothstep(0.45, 1.0, r);
    return float4(color, 1.0);
}

// =================================================================== 5. TUNNEL
// Infinite corridor; bass drives flight speed, treble lights the rings.
fragment float4 tunnel_fragment(VertexOut in [[stage_in]],
                                constant Uniforms &u [[buffer(0)]],
                                texture2d<float> spectrum [[texture(0)]],
                                texture2d<float> wave [[texture(1)]],
                                texture2d<float> history [[texture(2)]]) {
    float2 p = centred(in.uv, u);
    p += float2(sin(u.time * 0.21), cos(u.time * 0.17)) * 0.03 * (0.4 + u.mid);

    float r = max(length(p), 1e-4);
    float angle = atan2(p.y, p.x);
    // Mirrored so the band lookup has no seam along the branch cut.
    float mirrored = abs(fract(angle / (2.0 * M_PI_F) + 0.5) * 2.0 - 1.0);

    float speed = u.time * (0.35 + u.bass * 0.85) + u.beatPhase * 0.05;
    float depth = 0.30 / r + speed;

    float band = spectrumSmooth(spectrum, mirrored, 0.012);

    // Depth rings, antialiased so distant ones dissolve instead of aliasing.
    float rings = gridLine(depth * 2.0, 0.28);
    // Offset by half a period: floor() must flip in the dark gap between rings,
    // not at the bright ring itself, or every ring edge shows as a hard circle.
    float ringIndex = floor(depth * 2.0 + 0.5);
    // Wall staves; the multiplier is even so they wrap cleanly at ±pi.
    float staves = 0.42 + 0.58 * sin(angle * 16.0 + ringIndex * 1.7 + u.time * 0.25);

    // Dark at the vanishing point, and softly darkening again as the nearest ring
    // sweeps past the camera — without that outer falloff the last ring extends
    // forever and terminates in a hard circle.
    float fog = smoothstep(0.0, 0.16, r) * exp(-max(0.0, r - 0.34) * 2.6);
    // Each ring takes its own step through the palette, which sells the depth.
    float3 tint = paletteColor(0.08 + fract(ringIndex * 0.085) * 0.5 + band * 0.18, u);

    float3 color = tint * rings * (0.25 + staves * 0.75) * fog * (0.32 + band * 1.4 + u.beat * 0.3);
    color += tint * 0.045 * fog;
    color += paletteColor(0.30, u) * exp(-r * 7.0) * (0.28 + u.level * 1.1 + u.beat * 0.55);

    color += u.palette[0].rgb * 0.08;
    color *= 1.0 - 0.4 * smoothstep(0.62, 1.2, r);
    return float4(color, 1.0);
}

// ================================================================ 6. PARTICLES
// Layered starfield; each mote is lit by its own slice of the spectrum.
fragment float4 particles_fragment(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]],
                                   texture2d<float> spectrum [[texture(0)]],
                                   texture2d<float> wave [[texture(1)]],
                                texture2d<float> history [[texture(2)]]) {
    float2 p = centred(in.uv, u);
    float3 color = float3(0.0);

    for (int layer = 0; layer < 3; ++layer) {
        float depth = 1.0 + float(layer) * 0.85;
        float scale = 6.0 * depth;
        float drift = u.time * (0.06 + 0.05 * float(layer)) * (0.5 + u.bass * 1.4);

        // Beat nudges every mote outward from the centre.
        float2 q = p * (1.0 - u.beat * 0.10 / depth);
        q += float2(drift * 0.4, drift * 0.15);

        float2 grid = q * scale;
        float2 cell = floor(grid);
        float2 local = fract(grid) - 0.5;

        for (int oy = -1; oy <= 1; ++oy) {
            for (int ox = -1; ox <= 1; ++ox) {
                float2 neighbour = float2(float(ox), float(oy));
                float2 id = cell + neighbour;
                float2 rnd = hash22(id + float2(float(layer) * 17.0, 0.0));
                float band = spectrumAt(spectrum, rnd.x);
                float twinkle = 0.55 + 0.45 * sin(u.time * (1.2 + rnd.y * 2.4) + rnd.x * 20.0);

                float2 offset = (rnd - 0.5) * 0.7;
                offset += float2(sin(u.time * 0.5 + rnd.x * 12.0),
                                 cos(u.time * 0.4 + rnd.y * 9.0)) * 0.12;
                float d = length(local - neighbour - offset);

                // A tenth of the motes are "hero" stars with a wider halo.
                float hero = step(0.90, hash21(id + 3.7));
                float brightness = band * band * twinkle * (1.0 / depth) * (1.0 + hero * 1.6);
                float radius = 0.016 + brightness * 0.055 + u.beat * 0.008;
                float mote = radius / (d * d + radius * 0.35);
                color += paletteColor(0.10 + rnd.x * 0.62, u) * mote * brightness * 0.55;
            }
        }
    }

    float clouds = fbm(p * 2.2 + float2(u.time * 0.03, -u.time * 0.02), 4);
    color += paletteColor(0.30 + clouds * 0.4, u) * clouds * clouds * (0.06 + u.level * 0.16);
    color += paletteColor(0.85, u) * exp(-length(p) * 4.0) * u.beat * 0.30;

    color += u.palette[0].rgb * 0.08;
    color *= 1.0 - 0.4 * smoothstep(0.45, 1.05, length(p));
    return float4(color, 1.0);
}

// =================================================================== 7. LIQUID
// Metaballs whose radii track the bands — thick, glossy, slow.
fragment float4 liquid_fragment(VertexOut in [[stage_in]],
                                constant Uniforms &u [[buffer(0)]],
                                texture2d<float> spectrum [[texture(0)]],
                                texture2d<float> wave [[texture(1)]],
                                texture2d<float> history [[texture(2)]]) {
    float2 p = centred(in.uv, u);
    float field = 0.0;
    float3 accent = float3(0.0);

    const int blobCount = 8;
    for (int i = 0; i < blobCount; ++i) {
        float fi = float(i);
        float seed = hash11(fi * 3.17 + 1.0);
        float band = spectrumSmooth(spectrum, fi / float(blobCount) + 0.04, 0.03);

        float speed = 0.18 + seed * 0.25;
        float2 centre = float2(sin(u.time * speed + fi * 2.1) * (0.30 + seed * 0.12),
                               cos(u.time * speed * 0.82 + fi * 1.7) * (0.22 + seed * 0.10));
        centre *= 1.0 + u.beat * 0.09;

        float radius = 0.042 + band * 0.080 + u.bass * 0.026;
        float d = length(p - centre);
        float contribution = radius * radius / (d * d + 0.0008);
        field += contribution;
        accent += paletteColor(0.10 + fi / float(blobCount) * 0.60, u) * contribution;
    }

    accent /= max(field, 1e-3);

    // Tight, antialiased surface: the wide transition was what washed it out.
    float aa = aaWidth(field) * 0.8 + 0.02;
    float surface = smoothstep(1.0 - aa, 1.0 + aa, field);
    float rim = smoothstep(1.0 - aa * 3.0, 1.0, field) * smoothstep(1.0 + aa * 7.0, 1.0 + aa, field);

    float3 color = accent * surface * (0.40 + u.level * 0.55);
    color += mix(accent, float3(1.0), 0.55) * rim * (0.35 + u.beat * 0.5);   // wet edge
    color += accent * smoothstep(0.35, 1.0, field) * 0.10;                   // inner falloff
    color += accent * exp(-max(0.0, 1.0 - field) * 6.0) * 0.08;              // outer halo
    color += u.palette[0].rgb * 0.09;

    color *= 1.0 - 0.4 * smoothstep(0.45, 1.05, length(p));
    return float4(color, 1.0);
}

// ===================================================================== 8. GRID
// Synthwave horizon: a rolling ground plane under a spectrum-sliced sun.
fragment float4 grid_fragment(VertexOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              texture2d<float> spectrum [[texture(0)]],
                              texture2d<float> wave [[texture(1)]],
                              texture2d<float> history [[texture(2)]]) {
    float2 uv = in.uv;
    float2 p = centred(uv, u);
    const float horizon = 0.42;
    float3 color = float3(0.0);

    if (uv.y < horizon) {
        // Perspective projection of a ground plane.
        float depth = horizon - uv.y;
        float z = 0.16 / max(depth, 1e-3);
        float x = p.x * z;
        float roll = u.time * (0.55 + u.bass * 1.2);

        // fwidth-aware lines: distant rows fade out rather than shimmer.
        float rows = gridLine(z - roll, 0.02);
        float columns = gridLine(x, 0.02);

        float band = spectrumSmooth(spectrum, saturate(abs(x) * 0.20), 0.02);
        float3 tint = paletteColor(0.28 + band * 0.30, u);
        float fade = smoothstep(0.0, 0.05, depth) * exp(-depth * 3.0) * 2.2;

        color += tint * (rows * 0.8 + columns) * fade * (0.35 + band * 1.2);
        color += tint * fade * 0.05;
        color += paletteColor(0.55, u) * exp(-depth * 9.0) * 0.25;   // glow off the horizon
    } else {
        // Sun disc sliced by horizontal bands.
        float2 sunP = float2(p.x, uv.y - horizon - 0.155);
        float sunR = length(sunP * float2(1.0, 1.12));
        float sunEdge = 0.195 + u.bass * 0.02;
        float sunAA = aaWidth(sunR) * 1.5;

        float slice = fract((uv.y - horizon) * 24.0 - u.time * 0.35);
        float sliceMask = max(step(0.34, slice), step(uv.y, horizon + 0.085));
        float sun = smoothstep(sunEdge + sunAA, sunEdge - sunAA, sunR) * sliceMask;
        float3 sunColor = mix(paletteColor(0.14, u), paletteColor(0.42, u),
                              saturate((uv.y - horizon) * 2.6));
        color += sunColor * sun * (0.85 + u.level * 0.5);
        color += sunColor * exp(-max(0.0, sunR - sunEdge) * 10.0) * (0.28 + u.beat * 0.35);

        // Small round stars on a jittered lattice.
        float2 starGrid = uv * float2(52.0, 34.0);
        float2 starID = floor(starGrid);
        float2 starLocal = fract(starGrid) - 0.5;
        float2 jitter = (hash22(starID + 5.0) - 0.5) * 0.72;
        float present = step(0.88, hash21(starID + 11.0));
        float starDistance = length((starLocal - jitter) * float2(1.0, 52.0 / 34.0));
        float twinkle = 0.45 + 0.55 * sin(u.time * 2.0 + hash21(starID + 3.0) * 20.0);
        float star = present * (0.0016 / (starDistance * starDistance + 0.0016));
        color += float3(0.85, 0.90, 1.0) * star * twinkle * 0.5
               * smoothstep(horizon, horizon + 0.35, uv.y);

        // Smoothed spectrum ridge sitting on the horizon.
        float band = spectrumSmooth(spectrum, saturate(abs(p.x) * 1.5), 0.02);
        float ridge = horizon + band * 0.115;
        color += paletteColor(0.72, u) * smoothstep(aaWidth(uv.y) * 2.0, 0.0, abs(uv.y - ridge))
               * (0.4 + band * 0.8);
        color += paletteColor(0.66, u) * smoothstep(ridge, horizon, uv.y) * 0.10;
    }

    color += paletteColor(0.38, u) * exp(-abs(uv.y - horizon) * 30.0) * (0.30 + u.level * 0.7);
    color += u.palette[0].rgb * 0.07;
    color *= 1.0 - 0.45 * smoothstep(0.45, 1.05, length(p));
    return float4(color, 1.0);
}


// ============================================================== 9. SPECTROGRAM
// Scrolling waterfall: frequency up the screen, time flowing right to left.
fragment float4 spectrogram_fragment(VertexOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     texture2d<float> spectrum [[texture(0)]],
                                     texture2d<float> wave [[texture(1)]],
                                     texture2d<float> history [[texture(2)]]) {
    float2 uv = in.uv;
    // uv.x = 1 is now; walking left walks backwards through the ring buffer. A full
    // sweep covers every row, so the oldest and newest samples meet at the left
    // edge — which is faded out below, hiding the seam.
    float age = 1.0 - uv.x;
    float row = u.spectrogramCursor - age;
    float value = history.sample(historySampler, float2(uv.y, row)).r;

    float shaped = pow(saturate(value), 0.80);
    float3 color = paletteColor(0.06 + shaped * 0.62, u) * shaped * (0.55 + shaped * 1.15);

    // Quiet cells shouldn't be pure black or the plot loses its shape.
    color += u.palette[0].rgb * 0.16;

    // Bright playhead at the right edge, showing the current instant.
    float2 live = spectrumStereo(spectrum, uv.y);
    float now = (live.x + live.y) * 0.5;
    float edge = smoothstep(0.985, 1.0, uv.x);
    color += mix(paletteColor(0.55, u), float3(1.0), 0.35) * edge * (0.25 + now * 1.3);

    // Octave guides, so the frequency axis is readable.
    float guide = gridLine(uv.y * 8.0, 0.004);
    color += float3(0.7, 0.78, 0.9) * guide * 0.035;

    color *= smoothstep(0.0, 0.10, uv.x);          // fade the wrap seam
    color *= 1.0 - 0.25 * smoothstep(0.5, 1.1, length(centred(uv, u)));
    return float4(color, 1.0);
}

// ============================================================= 10. KALEIDOSCOPE
// Six-fold mirrored symmetry over a tumbling field of warped noise.
fragment float4 kaleidoscope_fragment(VertexOut in [[stage_in]],
                                      constant Uniforms &u [[buffer(0)]],
                                      texture2d<float> spectrum [[texture(0)]],
                                      texture2d<float> wave [[texture(1)]],
                                      texture2d<float> history [[texture(2)]]) {
    float2 p = centred(in.uv, u);
    float r = length(p);
    float angle = atan2(p.y, p.x) + u.time * 0.045 + u.tempoPhase * 0.03;

    // Fold the full turn into one mirrored wedge — the kaleidoscope itself.
    const float segments = 6.0;
    const float wedge = 2.0 * M_PI_F / segments;
    float folded = abs(fract(angle / wedge + 0.5) - 0.5) * wedge;
    float2 q = float2(cos(folded), sin(folded)) * r;

    // Drift the sampling point away from the origin before reading the noise.
    // Sampling centred on the origin makes every feature radially symmetric, which
    // collapses the whole effect into concentric rings; the offset is what turns it
    // into tumbling shards of glass.
    float2 field = q * 2.9 + float2(sin(u.time * 0.13) * 1.6 + 3.0,
                                    cos(u.time * 0.11) * 1.6 + 5.0);
    field /= 1.0 + u.bass * 0.22 + u.beat * 0.08;

    float base = fbm(field * 1.6, 4);
    float warped = fbm(field * 2.7 + base * 1.8 + float2(u.time * 0.05, -u.time * 0.03), 4);

    // Hard-edged facets: the fractional part of the warped field, ridged.
    float facets = abs(fract(warped * 5.0) * 2.0 - 1.0);
    float polish = smoothstep(0.42, 0.98, facets);
    float veins = smoothstep(0.12, 0.0, facets);

    float band = spectrumSmooth(spectrum, saturate(warped * 0.7 + r * 0.4), 0.02);

    float focus = 1.0 - 0.55 * smoothstep(0.15, 0.75, r);
    float3 color = paletteColor(warped * 0.75 + band * 0.22 + 0.04, u)
                 * (0.16 + polish * 0.95) * (0.30 + band * 1.35) * focus;
    // Bright seams between facets, lit by the highs.
    color += mix(paletteColor(0.62, u), float3(1.0), 0.45) * veins * (0.15 + u.treble * 0.55) * focus;

    // Faint glint along the mirror lines, and a hot core.
    float mirrorLine = smoothstep(0.012, 0.0, min(folded, wedge * 0.5 - folded));
    color += paletteColor(0.5, u) * mirrorLine * (0.04 + u.mid * 0.10);
    color += mix(paletteColor(0.35, u), float3(1.0), 0.3) * exp(-r * 10.0) * (0.30 + u.level * 0.95);
    color += paletteColor(0.85, u) * u.beat * 0.22 * smoothstep(0.30, 0.0, abs(r - 0.26));
    color += u.palette[0].rgb * 0.07;

    color *= 1.0 - 0.60 * smoothstep(0.30, 1.0, r);
    return float4(color, 1.0);
}

// ============================================================== 11. VECTORSCOPE
// Backdrop for the stereo point cloud: reference rings and the mono/anti-phase axes.
fragment float4 vectorscope_fragment(VertexOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     texture2d<float> spectrum [[texture(0)]],
                                     texture2d<float> wave [[texture(1)]],
                                     texture2d<float> history [[texture(2)]]) {
    float2 p = centred(in.uv, u);
    float r = length(p);
    float3 color = u.palette[0].rgb * 0.14;

    // Reference rings, like a hardware scope's graticule.
    for (int i = 1; i <= 3; ++i) {
        float radius = 0.13 * float(i);
        color += paletteColor(0.5, u) * smoothstep(0.0018, 0.0, abs(r - radius)) * 0.16;
    }
    // Vertical axis is mono; horizontal is anti-phase.
    color += paletteColor(0.58, u) * smoothstep(0.0014, 0.0, abs(p.x)) * 0.20;
    color += paletteColor(0.58, u) * smoothstep(0.0014, 0.0, abs(p.y)) * 0.10;

    // The wedge opens as the stereo image widens.
    float angle = abs(atan2(p.x, abs(p.y) + 1e-4));
    float spread = 0.20 + u.stereoWidth * 0.85;
    float inside = smoothstep(spread + 0.10, spread - 0.10, angle) * smoothstep(0.55, 0.15, r);
    color += paletteColor(0.30, u) * inside * (0.015 + u.level * 0.045);

    color += mix(paletteColor(0.4, u), float3(1.0), 0.2) * exp(-r * 13.0) * (0.06 + u.level * 0.20);
    color *= 1.0 - 0.4 * smoothstep(0.45, 1.05, r);
    return float4(color, 1.0);
}

// One additive sprite per waveform sample, plotting left against right.
struct PointOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
};

vertex PointOut stereo_point_vertex(uint vid [[vertex_id]],
                                    constant Uniforms &u [[buffer(0)]],
                                    texture2d<float> wave [[texture(1)]]) {
    // Oversampled against the 512-sample texture; linear filtering fills the gaps,
    // so the plot reads as a continuous trace rather than a dotted line.
    const float sampleCount = 2048.0;
    float t = (float(vid) + 0.5) / sampleCount;
    float2 lr = waveStereo(wave, t);

    // Rotate into mid/side axes: mono collapses to a vertical line, anti-phase
    // spreads horizontally — the convention every hardware vectorscope uses.
    float2 midSide = float2(lr.x - lr.y, lr.x + lr.y) * 0.70710678;
    float2 world = midSide * 0.38;

    PointOut out;
    out.position = float4(world.x / (u.aspect * 0.5), world.y * 2.0, 0.0, 1.0);
    out.pointSize = max(2.0, u.resolution.y * 0.0050 * (0.7 + u.level * 0.8));

    float amplitude = saturate(length(midSide));
    float3 tint = paletteColor(0.15 + t * 0.45 + amplitude * 0.2, u);
    // Newer samples burn brighter, giving the trace a visible head.
    float recency = 0.35 + 0.65 * t;
    out.color = float4(tint, recency * (0.18 + amplitude * 0.80) * (0.5 + u.beat * 0.5));
    return out;
}

fragment float4 stereo_point_fragment(PointOut in [[stage_in]],
                                      float2 coordinate [[point_coord]]) {
    float d = length(coordinate - 0.5) * 2.0;
    float falloff = saturate(1.0 - d);
    falloff = falloff * falloff * falloff;
    return float4(in.color.rgb * falloff * in.color.a, 1.0);
}

// ================================================================= composite
struct CompositeUniforms {
    float trail;
    float edrScale;
    float time;
    float grain;
    float transition;   // 0 = incoming scene only, 1 = outgoing scene only
    float3 pad;
};

fragment float4 trail_fragment(VertexOut in [[stage_in]],
                               constant CompositeUniforms &c [[buffer(0)]],
                               texture2d<float> scene [[texture(0)]],
                               texture2d<float> history [[texture(1)]],
                               texture2d<float> outgoing [[texture(2)]]) {
    float2 flipped = float2(in.uv.x, 1.0 - in.uv.y);
    float3 incoming = scene.sample(linearSampler, flipped).rgb;
    float3 leaving = outgoing.sample(linearSampler, flipped).rgb;
    // `transition` runs 0 -> 1 as a newly selected mode takes over.
    float3 current = mix(leaving, incoming, c.transition);
    // Zoom the history a hair so trails bloom outward instead of smearing in place.
    float2 warped = (in.uv - 0.5) * (1.0 - 0.004 * c.trail) + 0.5;
    float3 previous = history.sample(linearSampler, float2(warped.x, 1.0 - warped.y)).rgb;
    // trail 0 -> no history at all; 1 -> very long, film-like smear.
    float decay = pow(max(c.trail, 0.0), 0.6) * 0.95;
    float3 result = max(current, previous * decay);
    return float4(result, 1.0);
}

/// Hue-preserving tone map.
///
/// Running ACES per channel pulls every bright pixel toward white, which is death
/// for neon. Tone-map the peak channel instead and keep the colour ratio, then
/// whiten only where the result is genuinely near clipping.
static inline float3 tonemap(float3 color) {
    float peak = max(max(color.r, color.g), color.b);
    if (peak < 1e-5) return color;
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    float mapped = saturate((peak * (a * peak + b)) / (peak * (c * peak + d) + e));
    float3 ratio = color / peak;
    ratio = mix(ratio, float3(1.0), pow(mapped, 5.0) * 0.4);
    return ratio * mapped;
}

fragment float4 present_fragment(VertexOut in [[stage_in]],
                                 constant CompositeUniforms &c [[buffer(0)]],
                                 texture2d<float> scene [[texture(0)]]) {
    float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
    float3 color = scene.sample(linearSampler, uv).rgb;

    color = tonemap(color * 1.08);

    // Fixed-size dither breaks up banding in the big smooth gradients.
    float grain = (hash21(in.uv * 1024.0 + fract(c.time) * 37.0) - 0.5) * c.grain;
    color = saturate(color + grain);

    // The framebuffer is extended-linear: undo sRGB, then push into XDR headroom.
    float3 linearColor = pow(color, float3(2.2)) * c.edrScale;
    return float4(linearColor, 1.0);
}
