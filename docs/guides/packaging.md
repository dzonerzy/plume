# Packages

`plume package` builds the application (as `plume build`), then packages it for
users into `build/package/`:

| | |
| --- | --- |
| Windows | `nsis`: a per-user installer, made with [NSIS](https://nsis.sourceforge.io)'s `makensis`: no administrator rights, installed in the user's `AppData\Local\Programs`, a Start menu shortcut, an uninstaller in Settings' apps list, file associations and URL protocols in the user's registry. `zip`: the executable alone. Default: `nsis`, or `zip` without NSIS. |
| Linux | `deb`: `/usr/bin/<name>`, a `.desktop` file with the application's MIME types and URL schemes, the icon, and MIME definitions for its own file types. `tar`: the same tree as a `.tar.gz`. `appimage`: an AppImage, with `appimagetool`. Default: all three (`appimage` when `appimagetool` is installed). |

```sh
plume package                        # the defaults
plume package --format zip           # some of them (repeatable)
plume package --skip-build           # what build/bin has
```

Packages are made on the system they are for.

## What plume.json gives them

```json
{
  "name": "notes",
  "title": "Notes",
  "app_id": "com.example.notes",
  "version": "1.2.0",
  "publisher": "Example Inc.",
  "description": "Notes, in Markdown",
  "copyright": "Copyright (C) 2026 Example Inc.",
  "file_associations": [
    { "ext": "note", "name": "Note" },
    { "ext": "md", "name": "Markdown document", "mime": "text/markdown" }
  ],
  "protocols": ["notes"],
  "categories": "Office;"
}
```

- `version`, `publisher`, `description`, `copyright`: the installer, the
  package's metadata, and on Windows the executable's version information
  (Explorer's Details), which every build has.
- `file_associations`: the application is offered for these files. A type
  without `mime` gets one of its own (`application/x-notes-note`), defined by
  the Linux packages.
- `protocols`: `notes://...` links open the application.
- `categories`: the Linux `.desktop` file's.

## Opened with a file or a link

The file's path or the link is an argument of the launch: `app.args`. With
`"single_instance": true` and the application already running, it goes to the
running one instead, as `app.onSecondInstance`'s `Launch` (and the pages'
`instance:launched` event).

## Signing

The installer and the executable are not code-signed by Plume. Sign them with
your certificate (`signtool sign`) before publishing; Windows SmartScreen warns
about unsigned downloads.
