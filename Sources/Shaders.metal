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
