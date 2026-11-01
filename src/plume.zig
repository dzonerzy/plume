//! Plume: desktop applications in Zig with a web frontend, on the ZeroG
//! engine (github.com/dzonerzy/ZeroG).

/// The engine's C API (include/zerog.h), as Zig sees it.
pub const zerog = @import("zerog");

/// A desktop application: a window showing the embedded frontend.
pub const App = @import("app.zig").App;
pub const Options = @import("app.zig").Options;
pub const Config = @import("app.zig").Config;

/// Events between Zig and the page (app.emit, app.on), and typed events.
pub const events = @import("events.zig");
pub const Events = events.Events;

/// The page's objects from Zig. A sync binding declaring a parameter of type
/// Page gets the calling page.
pub const dom = @import("dom.zig");
pub const Page = dom.Page;
pub const Ref = dom.Ref;

/// ZeroG asset archives (the frontend embedded in the binary).
pub const assets = @import("assets.zig");

/// Binds a type's methods into a view's pages (bindings.zig, methods.zig):
/// `try plume.bind(view, "App", App, &app)` makes `App.greet(...)` callable
/// from JavaScript.
pub const bind = @import("bindings.zig").bind;

/// Zig values as JSON and back, as bindings pass them.
pub const codec = @import("codec.zig");

/// The TypeScript of a binding type (bindings.ts, bindings.d.ts).
pub const typescript = @import("typescript.zig");
