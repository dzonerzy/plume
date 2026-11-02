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

## Code signing (Windows)

With `"signing"` in `plume.json`, `plume package` signs the executable before
packaging it (so the installer, the zip and the update carry the signature),
then the installer, with the Windows SDK's `signtool`:

```json
"signing": { "certificate": "certs/notes.pfx", "timestamp_url": "http://timestamp.digicert.com" }
```

- `certificate`: a `.pfx` file; its password in the environment variable
  `password_env` names (default `PLUME_SIGN_PASSWORD`). Or `thumbprint`: a
  certificate of your Windows certificate store, by its SHA-1 thumbprint (a
  hardware token's, for instance).
- `timestamp_url`: an RFC 3161 server (default DigiCert's), so the signature
  outlives the certificate; `null` for none.
- `signtool` is found on `PATH`, in the newest Windows 10/11 SDK, or at
  `SIGNTOOL`.

Without a signature Windows SmartScreen warns about the download.
