# plume.json

A project's settings. The application reads some (embedded at build time), the
plume tool and the build the rest.

```json
{
  "name": "notes",
  "title": "Notes",
  "app_id": "com.example.notes",
  "version": "1.2.0",
  "window": { "width": 1024, "height": 768, "resizable": true, "frameless": false, "transparent": false, "hidden": false },
  "color_scheme": "system",
  "single_instance": true,
  "profile": "minimal",
  "compress": false,
  "frontend": { "dir": "frontend", "dev_url": "http://localhost:5173" },
  "publisher": "Example Inc.",
  "description": "Notes, in Markdown",
  "copyright": "Copyright (C) 2026 Example Inc.",
  "file_associations": [{ "ext": "note", "name": "Note" }],
  "protocols": ["notes"],
  "categories": "Office;",
  "update": { "github": "owner/notes", "public_key": "..." }
}
```

## The application

| Key | Default | |
| --- | --- | --- |
| `name` | | the executable's and packages' name; identifies the application when there is no `app_id` |
| `title` | `name` | the main window's title, the name shown to users |
| `app_id` | none | reverse-DNS (`com.example.notes`): where the pages' data (cookies, localStorage, IndexedDB) is kept, the notifications' sender, the start-at-login entry, the Linux window class. Without it nothing is kept between runs. |
| `version` | `"0.1.0"` | the executable's version information, the packages', what updates compare with |
| `window.width`, `window.height` | 1024, 768 | logical pixels |
| `window.resizable` | true | |
| `window.frameless` | false | no system frame: the page draws one ([Windows](../guides/windows.md#frameless-and-transparent-windows)) |
| `window.transparent` | false | what the page leaves transparent shows the desktop |
| `window.hidden` | false | the main window starts hidden (a tray application's) |
| `color_scheme` | `"system"` | `"system"`, `"light"` or `"dark"` |
| `single_instance` | false | a second launch hands its arguments to the first |

## The build

| Key | Default | |
| --- | --- | --- |
| `profile` | `"minimal"` | the engine's profile for `plume build`: `minimal`, `standard`, `dev` |
| `compress` | false | `true` or `"best"`: `plume build` compresses with UPX |
| `frontend.dir` | `"frontend"` | the Vite project |
| `frontend.dev_url` | `"http://localhost:5173"` | where `plume dev` runs Vite |

## Packages

| Key | Default | |
| --- | --- | --- |
| `publisher` | `name` | the installer's and the version information's company |
| `description` | `title` | |
| `copyright` | `Copyright (C) <publisher>` | |
| `file_associations` | none | `{ "ext", "name", "mime" }`: files the application opens |
| `protocols` | none | URL schemes the application handles |
| `categories` | `"Utility;"` | the Linux `.desktop` file's categories |

## Updates

| Key | |
| --- | --- |
| `update.github` | `owner/repo`, whose releases are the updates |
| `update.public_key` | the Ed25519 public key (`plume update keygen`) |
| `update.api_url` | GitHub's API; another for GitHub Enterprise |

See [Packages](../guides/packaging.md) and [Updates](../guides/updates.md).
