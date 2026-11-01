//! The unit tests that need no engine (zig build test).

test {
    _ = @import("assets.zig");
    _ = @import("codec.zig");
    _ = @import("methods.zig");
    _ = @import("typescript.zig");
}

test "cli" {
    _ = @import("cli/init.zig");
}
