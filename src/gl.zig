//! OpenGL ES 3 for native layers (window.setLayer): the functions a layer
//! draws with, resolved from the windows' GL (ANGLE on Windows, the system's
//! EGL on Linux) through zg_gl_get_proc_address.
//!
//! Declare the functions a layer uses as the fields of a struct, named as in
//! GL, and load() fills them in:
//!
//!     const Gl = struct {
//!         glClearColor: *const fn (f32, f32, f32, f32) callconv(.c) void,
//!         glClear: *const fn (u32) callconv(.c) void,
//!     };
//!     const gl = try plume.gl.load(Gl);     // in the layer's draw
//!     gl.glClearColor(0, 0.5, 1, 1);
//!     gl.glClear(plume.gl.COLOR_BUFFER_BIT);
//!
//! `Core` has the functions most layers need (shaders, programs, buffers,
//! uniforms, textures, drawing). Load in the layer's draw (the GL context's
//! thread), once.

const std = @import("std");
const zg = @import("zerog");

pub const Error = error{
    /// A function the struct names is not in the windows' GL.
    MissingFunction,
};

/// The struct's function pointers, each from the field's name.
pub fn load(comptime T: type) Error!T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, F| {
        const pointer = zg.zg_gl_get_proc_address(name) orelse {
            std.log.err("plume.gl: no {s}", .{name});
            return error.MissingFunction;
        };
        @field(result, name) = @ptrCast(@alignCast(pointer));
        _ = F;
    }
    return result;
}

pub const Enum = u32;
pub const Uint = u32;
pub const Int = i32;
pub const Sizei = i32;
pub const Float = f32;
pub const Boolean = u8;

/// What layers commonly use.
pub const Core = struct {
    glViewport: *const fn (Int, Int, Sizei, Sizei) callconv(.c) void,
    glClearColor: *const fn (Float, Float, Float, Float) callconv(.c) void,
    glClear: *const fn (Uint) callconv(.c) void,
    glEnable: *const fn (Enum) callconv(.c) void,
    glDisable: *const fn (Enum) callconv(.c) void,
    glBlendFunc: *const fn (Enum, Enum) callconv(.c) void,
    glCreateShader: *const fn (Enum) callconv(.c) Uint,
    glShaderSource: *const fn (Uint, Sizei, [*]const [*:0]const u8, ?[*]const Int) callconv(.c) void,
    glCompileShader: *const fn (Uint) callconv(.c) void,
    glGetShaderiv: *const fn (Uint, Enum, *Int) callconv(.c) void,
    glGetShaderInfoLog: *const fn (Uint, Sizei, ?*Sizei, [*]u8) callconv(.c) void,
    glDeleteShader: *const fn (Uint) callconv(.c) void,
    glCreateProgram: *const fn () callconv(.c) Uint,
    glAttachShader: *const fn (Uint, Uint) callconv(.c) void,
    glLinkProgram: *const fn (Uint) callconv(.c) void,
    glGetProgramiv: *const fn (Uint, Enum, *Int) callconv(.c) void,
    glGetProgramInfoLog: *const fn (Uint, Sizei, ?*Sizei, [*]u8) callconv(.c) void,
    glUseProgram: *const fn (Uint) callconv(.c) void,
    glDeleteProgram: *const fn (Uint) callconv(.c) void,
    glGetUniformLocation: *const fn (Uint, [*:0]const u8) callconv(.c) Int,
    glUniform1f: *const fn (Int, Float) callconv(.c) void,
    glUniform2f: *const fn (Int, Float, Float) callconv(.c) void,
    glUniform3f: *const fn (Int, Float, Float, Float) callconv(.c) void,
    glUniform4f: *const fn (Int, Float, Float, Float, Float) callconv(.c) void,
    glUniform1i: *const fn (Int, Int) callconv(.c) void,
    glGenBuffers: *const fn (Sizei, [*]Uint) callconv(.c) void,
    glBindBuffer: *const fn (Enum, Uint) callconv(.c) void,
    glBufferData: *const fn (Enum, isize, ?*const anyopaque, Enum) callconv(.c) void,
    glGenVertexArrays: *const fn (Sizei, [*]Uint) callconv(.c) void,
    glBindVertexArray: *const fn (Uint) callconv(.c) void,
    glEnableVertexAttribArray: *const fn (Uint) callconv(.c) void,
    glVertexAttribPointer: *const fn (Uint, Int, Enum, Boolean, Sizei, ?*const anyopaque) callconv(.c) void,
    glDrawArrays: *const fn (Enum, Int, Sizei) callconv(.c) void,
    glGenTextures: *const fn (Sizei, [*]Uint) callconv(.c) void,
    glBindTexture: *const fn (Enum, Uint) callconv(.c) void,
    glTexParameteri: *const fn (Enum, Enum, Int) callconv(.c) void,
    glTexImage2D: *const fn (Enum, Int, Int, Sizei, Sizei, Int, Enum, Enum, ?*const anyopaque) callconv(.c) void,
    glActiveTexture: *const fn (Enum) callconv(.c) void,
    glGetError: *const fn () callconv(.c) Enum,
};

/// A program from two GLSL ES 3.00 sources, with Core; null after logging
/// what did not compile or link.
pub fn program(gl: Core, vertex_source: [*:0]const u8, fragment_source: [*:0]const u8) ?Uint {
    const vertex = shader(gl, VERTEX_SHADER, vertex_source) orelse return null;
    defer gl.glDeleteShader(vertex);
    const fragment = shader(gl, FRAGMENT_SHADER, fragment_source) orelse return null;
    defer gl.glDeleteShader(fragment);
    const result = gl.glCreateProgram();
    gl.glAttachShader(result, vertex);
    gl.glAttachShader(result, fragment);
    gl.glLinkProgram(result);
    var linked: Int = 0;
    gl.glGetProgramiv(result, LINK_STATUS, &linked);
    if (linked == 0) {
        var log: [1024]u8 = undefined;
        var length: Sizei = 0;
        gl.glGetProgramInfoLog(result, log.len, &length, &log);
        std.log.err("plume.gl: the program did not link: {s}", .{log[0..@intCast(length)]});
        gl.glDeleteProgram(result);
        return null;
    }
    return result;
}

fn shader(gl: Core, kind: Enum, source: [*:0]const u8) ?Uint {
    const result = gl.glCreateShader(kind);
    const sources = [_][*:0]const u8{source};
    gl.glShaderSource(result, 1, &sources, null);
    gl.glCompileShader(result);
    var compiled: Int = 0;
    gl.glGetShaderiv(result, COMPILE_STATUS, &compiled);
    if (compiled == 0) {
        var log: [1024]u8 = undefined;
        var length: Sizei = 0;
        gl.glGetShaderInfoLog(result, log.len, &length, &log);
        std.log.err("plume.gl: a shader did not compile: {s}", .{log[0..@intCast(length)]});
        gl.glDeleteShader(result);
        return null;
    }
    return result;
}

// Constants (GLES 3).
pub const COLOR_BUFFER_BIT: Uint = 0x00004000;
pub const DEPTH_BUFFER_BIT: Uint = 0x00000100;
pub const TRIANGLES: Enum = 0x0004;
pub const TRIANGLE_STRIP: Enum = 0x0005;
pub const BLEND: Enum = 0x0BE2;
pub const DEPTH_TEST: Enum = 0x0B71;
pub const SRC_ALPHA: Enum = 0x0302;
pub const ONE_MINUS_SRC_ALPHA: Enum = 0x0303;
pub const ONE: Enum = 1;
pub const FLOAT: Enum = 0x1406;
pub const UNSIGNED_BYTE: Enum = 0x1401;
pub const ARRAY_BUFFER: Enum = 0x8892;
pub const STATIC_DRAW: Enum = 0x88E4;
pub const DYNAMIC_DRAW: Enum = 0x88E8;
pub const VERTEX_SHADER: Enum = 0x8B31;
pub const FRAGMENT_SHADER: Enum = 0x8B30;
pub const COMPILE_STATUS: Enum = 0x8B81;
pub const LINK_STATUS: Enum = 0x8B82;
pub const TEXTURE_2D: Enum = 0x0DE1;
pub const TEXTURE0: Enum = 0x84C0;
pub const TEXTURE_MIN_FILTER: Enum = 0x2801;
pub const TEXTURE_MAG_FILTER: Enum = 0x2800;
pub const LINEAR: Int = 0x2601;
pub const NEAREST: Int = 0x2600;
pub const RGBA: Enum = 0x1908;
