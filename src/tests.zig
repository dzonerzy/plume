//! The unit tests that need no engine (zig build test).

test {
    _ = @import("assets.zig");
    _ = @import("codec.zig");
    _ = @import("methods.zig");
    _ = @import("typescript.zig");
    _ = @import("single_instance.zig");
    _ = @import("menu.zig");
    _ = @import("icon.zig");
    _ = @import("update.zig");
    _ = @import("png.zig");
}

test "cli" {
    _ = @import("cli/init.zig");
}
