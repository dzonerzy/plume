//! A native layer: a field of flowing color drawn by Zig with OpenGL ES 3
//! under the page, every frame, and an HTML panel over it whose sliders set
//! the shader's parameters through a binding. `zig build layer`.
//!
//! `layer --smoke`: quits once the layer has drawn a few frames and a capture
//! shows it under the page.

const std = @import("std");
const plume = @import("plume");
const gl = plume.gl;

/// What the page sets, read by the layer on the compositor thread.
const Scene = struct {
    window: *plume.Window,
    hue: Param = .init(0.58),
    speed: Param = .init(1.0),
    warp: Param = .init(4.0),
    frames: std.atomic.Value(u32) = .init(0),
    /// The compositor thread's own.
    context: ?Context = null,

    const Param = struct {
        bits: std.atomic.Value(u32),
        fn init(value: f32) Param {
            return .{ .bits = .init(@bitCast(value)) };
        }
        fn get(p: *const Param) f32 {
            return @bitCast(p.bits.load(.monotonic));
        }
        fn set(p: *Param, value: f32) void {
            p.bits.store(@bitCast(value), .monotonic);
        }
    };

    const Context = struct {
        gl: gl.Core,
        program: gl.Uint,
        size: gl.Int,
        time: gl.Int,
        hue: gl.Int,
        warp: gl.Int,
        clock: f64 = 0,
        last: f64 = 0,
    };

    /// The layer: on the compositor thread, the window's GL context current.
    fn draw(scene: *Scene, frame: plume.LayerFrame) void {
        const c = scene.prepare() orelse return;
        // The scene's own clock, faster or slower as the page asks.
        if (c.last != 0) c.clock += (frame.time_ms - c.last) / 1000.0 * scene.speed.get();
        c.last = frame.time_ms;
        c.gl.glViewport(0, 0, @intCast(frame.width), @intCast(frame.height));
        c.gl.glUseProgram(c.program);
        c.gl.glUniform2f(c.size, @floatFromInt(frame.width), @floatFromInt(frame.height));
        c.gl.glUniform1f(c.time, @floatCast(c.clock));
        c.gl.glUniform1f(c.hue, scene.hue.get());
        c.gl.glUniform1f(c.warp, scene.warp.get());
        c.gl.glBindVertexArray(0);
        c.gl.glDrawArrays(gl.TRIANGLES, 0, 3);
        _ = scene.frames.fetchAdd(1, .monotonic);
        // Continuous: the next frame.
        scene.window.invalidateLayer();
    }

    fn prepare(scene: *Scene) ?*Context {
        if (scene.context) |*c| return c;
        const core = gl.load(gl.Core) catch return null;
        const program = gl.program(core, vertex_source, fragment_source) orelse return null;
        scene.context = .{
            .gl = core,
            .program = program,
            .size = core.glGetUniformLocation(program, "size"),
            .time = core.glGetUniformLocation(program, "time"),
            .hue = core.glGetUniformLocation(program, "hue"),
            .warp = core.glGetUniformLocation(program, "warp"),
        };
        return &scene.context.?;
    }
};

/// One triangle covering the window, from the vertex's index.
const vertex_source =
    \\#version 300 es
    \\void main() {
    \\  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    \\  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

/// Domain-warped noise, colored by a cosine palette turned by `hue`.
const fragment_source =
    \\#version 300 es
    \\precision highp float;
    \\uniform vec2 size;
    \\uniform float time;
    \\uniform float hue;
    \\uniform float warp;
    \\out vec4 color;
    \\float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
    \\float noise(vec2 p) {
    \\  vec2 i = floor(p), f = fract(p), u = f * f * (3.0 - 2.0 * f);
    \\  return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
    \\}
    \\float fbm(vec2 p) {
    \\  float v = 0.0, a = 0.5;
    \\  for (int i = 0; i < 5; i++) { v += a * noise(p); p = p * 2.03 + vec2(1.7, 9.2); a *= 0.5; }
    \\  return v;
    \\}
    \\void main() {
    \\  vec2 uv = (gl_FragCoord.xy - 0.5 * size) / size.y * 2.2;
    \\  vec2 q = vec2(fbm(uv + time * 0.06), fbm(uv + vec2(5.2, 1.3) - time * 0.05));
    \\  vec2 r = vec2(fbm(uv + warp * q + vec2(1.7, 9.2) + time * 0.09), fbm(uv + warp * q + vec2(8.3, 2.8) - time * 0.08));
    \\  float f = fbm(uv + warp * r);
    \\  vec3 c = 0.5 + 0.5 * cos(6.28318 * (f * 0.9 + length(q) * 0.35 + vec3(hue, hue + 0.18, hue + 0.36)));
    \\  c *= 0.25 + 0.95 * f * f;
    \\  color = vec4(c, 1.0);
    \\}
;

/// What the page calls.
pub const Field = struct {
    scene: *Scene,
    smoke: bool,
    app: *plume.App,

    pub const Param = enum { hue, speed, warp };

    pub fn set(self: *Field, param: Param, value: f64) void {
        const v: f32 = @floatCast(value);
        switch (param) {
            .hue => self.scene.hue.set(v),
            .speed => self.scene.speed.set(v),
            .warp => self.scene.warp.set(v),
        }
    }

    /// Frames the layer has drawn so far.
    pub fn frames(self: *Field) u32 {
        return self.scene.frames.load(.monotonic);
    }

    /// The page's checks under --smoke.
    pub fn report(self: *Field, passed: bool, summary: []const u8) void {
        std.debug.print("{s}\n", .{summary});
        if (self.smoke) {
            if (!passed) std.process.exit(1);
            self.app.quit();
        }
    }

    pub fn isSmoke(self: *Field) bool {
        return self.smoke;
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    const app = try plume.App.init(.{
        .title = "Field",
        .width = 1100,
        .height = 700,
        .native_layer = true,
        .assets = @embedFile("frontend"),
        .io = init.io,
        .args = args,
        .color_scheme = .dark,
    });
    defer app.deinit();

    var scene: Scene = .{ .window = app.window() };
    try app.window().setLayer(&scene, Scene.draw);
    var field: Field = .{ .scene = &scene, .smoke = smoke, .app = app };
    try app.bind("Field", Field, &field);
    app.run();
}
