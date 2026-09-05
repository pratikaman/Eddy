#include <metal_stdlib>
using namespace metal;

// Stam-style stable fluids on ping-pong textures, structured after Dobryakov's
// WebGL fluid sim. Velocity is stored in sim-texels per second.

constexpr sampler lin(coord::normalized, address::clamp_to_edge, filter::linear);

struct Splat { float2 point; float2 aspectRadius; float4 value; };
struct Sim   { float2 texel; float dt; float k; };

#define GRID(t) uint2 size = uint2(t.get_width(), t.get_height()); \
                if (any(gid >= size)) return; \
                int2 m = int2(size) - 1; int2 g = int2(gid); (void)m; (void)g;
#define AT(t, x, y) t.read(uint2(clamp(int2(x, y), int2(0), m)))

kernel void splat(texture2d<float, access::read_write> tex [[texture(0)]],
                  constant Splat& s [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    GRID(tex)
    float2 d = (float2(gid) + 0.5) / float2(size) - s.point;
    d.x *= s.aspectRadius.x;
    tex.write(tex.read(gid) + s.value * exp(-dot(d, d) / s.aspectRadius.y), gid);
}

kernel void advect(texture2d<float> velocity [[texture(0)]],
                   texture2d<float> src [[texture(1)]],
                   texture2d<float, access::write> dst [[texture(2)]],
                   constant Sim& p [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    GRID(dst)
    float2 uv = (float2(gid) + 0.5) / float2(size);
    float2 back = uv - p.dt * velocity.sample(lin, uv).xy * p.texel;
    dst.write(src.sample(lin, back) * p.k, gid);
}

kernel void divergence(texture2d<float> vel [[texture(0)]],
                       texture2d<float, access::write> out [[texture(1)]],
                       constant Sim& p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    GRID(out)
    float2 C = vel.read(gid).xy;
    float L = g.x > 0   ? AT(vel, g.x - 1, g.y).x : -C.x;   // solid walls
    float R = g.x < m.x ? AT(vel, g.x + 1, g.y).x : -C.x;
    float B = g.y > 0   ? AT(vel, g.x, g.y - 1).y : -C.y;
    float T = g.y < m.y ? AT(vel, g.x, g.y + 1).y : -C.y;
    out.write(float4(0.5 * (R - L + T - B), 0, 0, 0), gid);
}

kernel void jacobi(texture2d<float> pressure [[texture(0)]],
                   texture2d<float> div [[texture(1)]],
                   texture2d<float, access::write> out [[texture(2)]],
                   constant Sim& p [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    GRID(out)
    float L = AT(pressure, g.x - 1, g.y).x, R = AT(pressure, g.x + 1, g.y).x;
    float B = AT(pressure, g.x, g.y - 1).x, T = AT(pressure, g.x, g.y + 1).x;
    out.write(float4((L + R + B + T - div.read(gid).x) * 0.25, 0, 0, 0), gid);
}

kernel void gradientSubtract(texture2d<float> pressure [[texture(0)]],
                             texture2d<float, access::read_write> vel [[texture(1)]],
                             constant Sim& p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    GRID(vel)
    float L = AT(pressure, g.x - 1, g.y).x, R = AT(pressure, g.x + 1, g.y).x;
    float B = AT(pressure, g.x, g.y - 1).x, T = AT(pressure, g.x, g.y + 1).x;
    float4 v = vel.read(gid);
    v.xy -= 0.5 * float2(R - L, T - B);
    vel.write(v, gid);
}

kernel void curl(texture2d<float> vel [[texture(0)]],
                 texture2d<float, access::write> out [[texture(1)]],
                 constant Sim& p [[buffer(0)]],
                 uint2 gid [[thread_position_in_grid]]) {
    GRID(out)
    float L = AT(vel, g.x - 1, g.y).y, R = AT(vel, g.x + 1, g.y).y;
    float B = AT(vel, g.x, g.y - 1).x, T = AT(vel, g.x, g.y + 1).x;
    out.write(float4(0.5 * ((R - L) - (T - B)), 0, 0, 0), gid);
}

kernel void vorticity(texture2d<float> curlTex [[texture(0)]],
                      texture2d<float, access::read_write> vel [[texture(1)]],
                      constant Sim& p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    GRID(vel)
    float L = AT(curlTex, g.x - 1, g.y).x, R = AT(curlTex, g.x + 1, g.y).x;
    float B = AT(curlTex, g.x, g.y - 1).x, T = AT(curlTex, g.x, g.y + 1).x;
    float C = curlTex.read(gid).x;
    float2 force = 0.5 * float2(abs(T) - abs(B), abs(R) - abs(L));
    force = force / (length(force) + 1e-4) * p.k * C;
    force.y = -force.y;
    float4 v = vel.read(gid);
    v.xy += force * p.dt;
    vel.write(v, gid);
}

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut fullscreen(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2 - 1, 0, 1);
    o.uv = float2(p.x, 1 - p.y);
    return o;
}

fragment float4 display(VOut in [[stage_in]], texture2d<float> dye [[texture(0)]]) {
    return float4(dye.sample(lin, in.uv).rgb, 1);
}

// ───────────────────────── single-pass scenes ─────────────────────────
// Every scene below is one fullscreen fragment shader fed by `Uniforms` (mirrored in Renderer.swift).

struct Uniforms {
    float2 resolution;   // pixels
    float time;
    float beat;          // 1 on a beat, fading to 0
    float4 audio;        // bass, mid, high, gain
    float4 palette;      // hue base, hue span, saturation, beat phase (+1 per beat, gliding)
};

inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1, 0)), c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

inline float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    float2x2 rot = float2x2(0.8, 0.6, -0.6, 0.8);
    for (int i = 0; i < 5; i++) { v += a * vnoise(p); p = rot * p * 2.03 + 7.7; a *= 0.5; }
    return v;
}

inline float3 hsv2rgb(float3 c) {
    float3 p = abs(fract(c.xxx + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

/// Sparse round twinkling points: one per `cell` px cell with probability 1-threshold, placed at random inside it.
inline float stars(float2 px, float cell, float threshold, float time) {
    float2 id = floor(px / cell), f = fract(px / cell);
    float h = hash21(id);
    float2 c = float2(hash21(id + 1.3), hash21(id + 7.1));
    float d = length(f - c) * cell;
    float twinkle = 0.55 + 0.45 * sin(time * (2.0 + 6.0 * hash21(id + 9.0)) + h * 50.0);
    return step(threshold, h) * exp(-d * d * 0.6) * twinkle;
}

/// The user's palette: `t` sweeps the chosen slice of the colour wheel.
inline float3 pal(float t, constant Uniforms& u) {
    return hsv2rgb(float3(fract(u.palette.x + u.palette.y * fract(t)), u.palette.z, 1.0));
}

// Curtains of light. Bass fattens them, highs sprinkle dust, beats flash.
fragment float4 scene_aurora(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = float2(in.uv.x * u.resolution.x / u.resolution.y, 1.0 - in.uv.y);
    float t = u.time * 0.08;
    float bass = u.audio.x * u.audio.w, high = u.audio.z * u.audio.w;
    float3 col = float3(0.01, 0.01, 0.03);
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float x = p.x * (1.2 + 0.35 * fi) + t * (0.6 + 0.3 * fi) + fi * 3.1;
        float h = fbm(float2(x, t * 0.7 + fi * 5.0));
        float dy = p.y - (0.35 + 0.15 * fi + (h - 0.5) * 0.8);
        // crisp upper edge, soft trail hanging below it
        float shape = dy > 0.0 ? exp(-dy * dy * (90.0 - 40.0 * bass)) : exp(dy * (9.0 - 4.0 * bass)) * 0.6;
        float streak = pow(0.5 + 0.5 * fbm(float2(x * 14.0, t * 2.0 + fi)), 2.0);
        col += pal(h * 0.6 + fi * 0.25 + t * 0.2, u) * shape * streak * (0.3 + 0.7 * h) * (0.3 + 1.0 * bass);
    }
    col *= 1.0 + u.beat * 0.8;
    col += stars(in.uv * u.resolution, 9.0, 0.97, u.time * 3.0) * (0.15 + 1.2 * high);
    return float4(col, 1);
}

// A lava lamp. Blobs swell with bass and blink on the beat.
fragment float4 scene_lava(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = (in.uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0);
    p.y = -p.y;
    float t = u.time * 0.25;
    float bass = u.audio.x * u.audio.w;
    float field = 0.0, hue = 0.0;
    for (int i = 0; i < 7; i++) {
        float fi = float(i);
        float2 c = float2(sin(t * (0.31 + 0.07 * fi) + fi * 1.7) * 0.7, cos(t * (0.23 + 0.05 * fi) + fi * 2.3) * 0.4);
        float r = 0.09 + 0.03 * sin(t * 0.9 + fi) + 0.06 * bass;
        float contrib = r * r / (dot(p - c, p - c) + 1e-4);
        field += contrib;
        hue += contrib * fi / 7.0;
    }
    hue /= max(field, 1e-3);
    float body = smoothstep(0.8, 1.1, field);
    float rim = smoothstep(0.5, 0.9, field) * (1.0 - body);
    float3 blob = pal(hue + t * 0.1, u);
    float3 col = float3(0.02, 0.01, 0.02) + pal(t * 0.1 + 0.5, u) * 0.04;
    col += blob * body * (0.55 + 0.3 * bass + 0.3 * u.beat);
    col += blob * rim * 0.35;
    return float4(col, 1);
}

// Deep-space clouds with twinkling stars. Bass brightens the gas, highs make the stars flicker.
fragment float4 scene_nebula(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = (in.uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0);
    float t = u.time * 0.03;
    float bass = u.audio.x * u.audio.w, mid = u.audio.y, high = u.audio.z * u.audio.w;
    float2 q = p * 1.6 + float2(t, -t * 0.7);
    float n1 = fbm(q);
    float n2 = fbm(q + float2(n1 * 1.8, t * 2.0) + 5.2);
    float n = fbm(q + n2 * 2.2 * (1.0 + 0.4 * mid));
    float density = smoothstep(0.35, 0.85, n);
    float3 col = pal(n2 + t * 0.6, u) * density * density * (0.8 + 2.2 * bass + 0.6 * u.beat);
    col += pal(n + 0.4, u) * pow(n1, 3.0) * 0.4;
    col += float3(0.01, 0.01, 0.03);
    col += stars(in.uv * u.resolution, 8.0, 0.985, u.time) * (0.6 + 3.0 * high) * (1.0 + u.beat);
    return float4(col, 1);
}

// Rings that step outward on every beat, spokes that spin with the highs.
fragment float4 scene_pulse(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = (in.uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0);
    float d = length(p), a = atan2(p.y, p.x);
    float bass = u.audio.x * u.audio.w, mid = u.audio.y, high = u.audio.z * u.audio.w;
    float phase = u.palette.w + u.time * 0.15;
    float rings = pow(0.5 + 0.5 * cos((d * 5.0 - phase) * 6.2832), 6.0);
    float3 col = pal(d * 0.8 - phase * 0.1, u) * rings * (0.35 + 0.9 * bass) * exp(-d * 1.4);
    float spokes = pow(0.5 + 0.5 * cos(a * 10.0 + u.time * 0.5 + phase * 0.7), 24.0);
    col += pal(a / 6.2832 + phase * 0.05, u) * spokes * (0.15 + 1.2 * high) * exp(-d * 2.0) * smoothstep(0.0, 0.3, d);
    col += pal(phase * 0.1, u) * exp(-d * d * 30.0) * (0.3 + 2.0 * u.beat);
    col += float3(0.01, 0.01, 0.02) + mid * 0.03;
    return float4(col, 1);
}
