//! Plume: desktop applications in Zig with a web frontend, on the ZeroG
//! engine (github.com/dzonerzy/ZeroG).

/// The engine's C API (include/zerog.h), as Zig sees it.
pub const zerog = @import("zerog");

/// Binds a type's methods into a view's pages (bindings.zig, methods.zig):
/// `try plume.bind(view, "App", App, &app)` makes `App.greet(...)` callable
/// from JavaScript.
pub const bind = @import("bindings.zig").bind;

/// Zig values as JSON and back, as bindings pass them.
pub const codec = @import("codec.zig");

/// The TypeScript of a binding type (bindings.ts, bindings.d.ts).
pub const typescript = @import("typescript.zig");
