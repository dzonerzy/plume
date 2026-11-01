//! One instance per user: a second launch hands its arguments to the first
//! and exits. Windows: a named mutex claims the name, a named pipe carries
//! the launches. Linux: an abstract Unix socket does both (the kernel frees
//! it with the process).
//!
//! A launch goes as JSON, {"args": [...], "cwd": "..."}, to the first
//! instance's listener thread, which hands it to `deliver`.

const std = @import("std");
const builtin = @import("builtin");

pub const Launch = struct {
    args: []const []const u8,
    cwd: []const u8,
};

pub const DeliverFn = *const fn (context: ?*anyopaque, launch_json: []const u8) void;

pub const Instance = struct {
    name: []const u8,
    lock: SpinLock = .{},
    deliver: ?DeliverFn = null,
    context: ?*anyopaque = null,
    listening: bool = false,
    /// Windows: the mutex; Linux: the listening socket.
    handle: Handle,

    const allocator = std.heap.smp_allocator;

    /// Claims `id` for this process. Null if another process holds it: then
    /// `launch` was handed to that one, and this process should exit.
    pub fn claim(id: []const u8, launch: Launch) !?*Instance {
        const name = try instanceName(id);
        errdefer allocator.free(name);
        const handle = (try platform.claim(name)) orelse {
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            const json = try std.json.Stringify.valueAlloc(arena.allocator(), launch, .{});
            platform.send(name, json) catch |err| std.log.err("plume: the running instance did not take the launch: {s}", .{@errorName(err)});
            allocator.free(name);
            return null;
        };
        const instance = try allocator.create(Instance);
        instance.* = .{ .name = name, .handle = handle };
        return instance;
    }

    /// Later launches go to `deliver(context, json)`, on the listener thread.
    pub fn listen(instance: *Instance, context: ?*anyopaque, deliver: DeliverFn) !void {
        instance.lock.lock();
        instance.context = context;
        instance.deliver = deliver;
        const start = !instance.listening;
        instance.listening = true;
        instance.lock.unlock();
        if (start) (try std.Thread.spawn(.{}, run, .{instance})).detach();
    }

    /// No more deliveries (the app is ending). The listener thread and the
    /// instance live on until the process exits: the name stays claimed.
    pub fn stop(instance: *Instance) void {
        instance.lock.lock();
        defer instance.lock.unlock();
        instance.deliver = null;
    }

    fn run(instance: *Instance) void {
        platform.serve(instance);
    }

    /// From the listener thread: one launch's JSON.
    fn received(instance: *Instance, json: []const u8) void {
        instance.lock.lock();
        defer instance.lock.unlock();
        if (instance.deliver) |deliver| deliver(instance.context, json);
    }
};

/// "plume-" and `id` made safe for a pipe or socket name.
fn instanceName(id: []const u8) ![]u8 {
    const name = try std.fmt.allocPrint(std.heap.smp_allocator, "plume-{s}", .{id});
    for (name) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '-' and c.* != '.' and c.* != '_') c.* = '_';
    }
    return name;
}

const max_launch = 1 << 20;

const Handle = if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.c.fd_t;

const platform = if (builtin.os.tag == .windows) Windows else Posix;

const Windows = struct {
    const windows = std.os.windows;
    const HANDLE = windows.HANDLE;
    const BOOL = windows.BOOL;
    const DWORD = u32;
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

    extern "kernel32" fn CreateMutexW(attributes: ?*anyopaque, initial_owner: BOOL, name: [*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
    extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateNamedPipeW(name: [*:0]const u16, open_mode: DWORD, pipe_mode: DWORD, max_instances: DWORD, out_size: DWORD, in_size: DWORD, timeout: DWORD, attributes: ?*anyopaque) callconv(.winapi) HANDLE;
    extern "kernel32" fn ConnectNamedPipe(pipe: HANDLE, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn DisconnectNamedPipe(pipe: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, attributes: ?*anyopaque, disposition: DWORD, flags: DWORD, template: ?HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn ReadFile(file: HANDLE, buffer: [*]u8, size: DWORD, read: *DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(file: HANDLE, buffer: [*]const u8, size: DWORD, written: *DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitNamedPipeW(name: [*:0]const u16, timeout: DWORD) callconv(.winapi) BOOL;

    const ERROR_ALREADY_EXISTS = 183;
    const ERROR_PIPE_BUSY = 231;
    const ERROR_PIPE_CONNECTED = 535;
    const PIPE_ACCESS_INBOUND = 0x1;
    const PIPE_TYPE_BYTE = 0x0;
    const PIPE_WAIT = 0x0;
    const PIPE_REJECT_REMOTE_CLIENTS = 0x8;
    const GENERIC_WRITE = 0x40000000;
    const OPEN_EXISTING = 3;

    fn wide(comptime prefix: []const u8, name: []const u8) ![:0]u16 {
        const full = try std.mem.concat(std.heap.smp_allocator, u8, &.{ prefix, name });
        defer std.heap.smp_allocator.free(full);
        return std.unicode.utf8ToUtf16LeAllocZ(std.heap.smp_allocator, full);
    }

    fn claim(name: []const u8) !?HANDLE {
        const mutex_name = try wide("Local\\", name);
        defer std.heap.smp_allocator.free(mutex_name);
        const mutex = CreateMutexW(null, .FALSE, mutex_name.ptr) orelse return error.SystemResources;
        if (GetLastError() == ERROR_ALREADY_EXISTS) {
            _ = CloseHandle(mutex);
            return null;
        }
        return mutex;
    }

    fn send(name: []const u8, json: []const u8) !void {
        const pipe_name = try wide("\\\\.\\pipe\\", name);
        defer std.heap.smp_allocator.free(pipe_name);
        // The first instance may be starting its listener, or serving another launch.
        var attempt: usize = 0;
        const pipe = while (attempt < 50) : (attempt += 1) {
            const handle = CreateFileW(pipe_name.ptr, GENERIC_WRITE, 0, null, OPEN_EXISTING, 0, null);
            if (handle != INVALID_HANDLE_VALUE) break handle;
            if (GetLastError() == ERROR_PIPE_BUSY) _ = WaitNamedPipeW(pipe_name.ptr, 200) else sleep(100);
        } else return error.NoListener;
        defer _ = CloseHandle(pipe);
        var written: DWORD = 0;
        if (WriteFile(pipe, json.ptr, @intCast(json.len), &written, null) == .FALSE or written != json.len) return error.WriteFailed;
    }

    fn serve(instance: *Instance) void {
        const pipe_name = wide("\\\\.\\pipe\\", instance.name) catch return;
        defer std.heap.smp_allocator.free(pipe_name);
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(std.heap.smp_allocator);
        while (true) {
            const pipe = CreateNamedPipeW(pipe_name.ptr, PIPE_ACCESS_INBOUND, PIPE_TYPE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 0, 64 * 1024, 0, null);
            if (pipe == INVALID_HANDLE_VALUE) return;
            if (ConnectNamedPipe(pipe, null) != .FALSE or GetLastError() == ERROR_PIPE_CONNECTED) {
                buffer.clearRetainingCapacity();
                var chunk: [4096]u8 = undefined;
                while (buffer.items.len < max_launch) {
                    var read: DWORD = 0;
                    if (ReadFile(pipe, &chunk, chunk.len, &read, null) == .FALSE or read == 0) break;
                    buffer.appendSlice(std.heap.smp_allocator, chunk[0..read]) catch break;
                }
                if (buffer.items.len > 0) instance.received(buffer.items);
            }
            _ = DisconnectNamedPipe(pipe);
            _ = CloseHandle(pipe);
        }
    }

    extern "kernel32" fn Sleep(milliseconds: DWORD) callconv(.winapi) void;
    fn sleep(milliseconds: DWORD) void {
        Sleep(milliseconds);
    }
};

const Posix = struct {
    const c = std.c;

    fn address(name: []const u8) !struct { c.sockaddr.un, c.socklen_t } {
        var addr = std.mem.zeroes(c.sockaddr.un);
        addr.family = c.AF.UNIX;
        // Abstract: a leading NUL, no file.
        if (name.len + 1 > addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[1 .. 1 + name.len], name);
        const length = @offsetOf(c.sockaddr.un, "path") + 1 + name.len;
        return .{ addr, @intCast(length) };
    }

    fn claim(name: []const u8) !?c.fd_t {
        const addr, const length = try address(name);
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
        if (fd < 0) return error.SystemResources;
        if (c.bind(fd, @ptrCast(&addr), length) != 0) {
            _ = c.close(fd);
            return null; // taken: another instance
        }
        if (c.listen(fd, 8) != 0) {
            _ = c.close(fd);
            return error.SystemResources;
        }
        return fd;
    }

    fn send(name: []const u8, json: []const u8) !void {
        const addr, const length = try address(name);
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
        if (fd < 0) return error.SystemResources;
        defer _ = c.close(fd);
        if (c.connect(fd, @ptrCast(&addr), length) != 0) return error.NoListener;
        var sent: usize = 0;
        while (sent < json.len) {
            const n = c.write(fd, json[sent..].ptr, json.len - sent);
            if (n <= 0) return error.WriteFailed;
            sent += @intCast(n);
        }
    }

    fn serve(instance: *Instance) void {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(std.heap.smp_allocator);
        while (true) {
            const client = c.accept(instance.handle, null, null);
            if (client < 0) continue;
            defer _ = c.close(client);
            buffer.clearRetainingCapacity();
            var chunk: [4096]u8 = undefined;
            while (buffer.items.len < max_launch) {
                const n = c.read(client, &chunk, chunk.len);
                if (n <= 0) break;
                buffer.appendSlice(std.heap.smp_allocator, chunk[0..@intCast(n)]) catch break;
            }
            if (buffer.items.len > 0) instance.received(buffer.items);
        }
    }
};

const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

test "instance names are safe" {
    const name = try instanceName("com.example/notes app");
    defer std.heap.smp_allocator.free(name);
    try std.testing.expectEqualStrings("plume-com.example_notes_app", name);
}
