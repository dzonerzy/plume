//! Plume: desktop applications in Zig with a web frontend, on the ZeroG
//! engine (github.com/dzonerzy/ZeroG).

/// The engine's C API (include/zerog.h), as Zig sees it.
pub const zerog = @import("zerog");

/// A desktop application: its windows showing the embedded frontend, and
/// what it has of the desktop (tray, notifications, global shortcuts).
pub const App = @import("app.zig").App;
pub const Options = @import("app.zig").Options;
pub const Config = @import("app.zig").Config;
pub const Launch = @import("app.zig").Launch;
pub const Notification = @import("app.zig").Notification;
pub const NotificationAction = @import("app.zig").NotificationAction;
pub const ContextMenuChoice = @import("app.zig").ContextMenuChoice;

/// A window and its page (app.window(), app.openWindow()).
pub const Window = @import("window.zig").Window;
pub const WindowOptions = @import("window.zig").Options;
pub const WindowEvent = @import("window.zig").WindowEvent;

/// A system tray icon (app.createTray()).
pub const Tray = @import("tray.zig").Tray;
pub const TrayOptions = @import("tray.zig").Options;

/// Updates from GitHub releases, signed (app.checkForUpdate, installUpdate).
pub const update = @import("update.zig");

/// Screens, the clipboard and the system's dialogs.
pub const desktop = @import("desktop.zig");
pub const Screen = desktop.Screen;
pub const FileDialog = desktop.FileDialog;
pub const MessageBox = desktop.MessageBox;

/// Menus defined in Zig: menu bars, popup, context and tray menus.
pub const menu = @import("menu.zig");

/// Events between Zig and the pages (app.emit, app.on), and typed events.
pub const events = @import("events.zig");
pub const Events = events.Events;

/// The page's objects from Zig. A sync binding declaring a parameter of type
/// Page gets the calling page.
pub const dom = @import("dom.zig");
pub const Page = dom.Page;
pub const Ref = dom.Ref;

/// Binary data for bindings: a Uint8Array in JavaScript.
pub const Bytes = @import("codec.zig").Bytes;

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

/// UI tests without a window: the page rendered into memory, driven with
/// real input, snapshots compared (plume test).
pub const testing = @import("testing.zig");

/// PNG files of pages (captures, snapshots).
pub const png = @import("png.zig");
