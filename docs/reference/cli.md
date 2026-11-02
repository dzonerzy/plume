# The plume tool

Run in a project's directory (the one with `plume.json`), except `init`,
`doctor` and `version`.

## plume init

```sh
plume init <name> [--template vanilla|react|svelte|vue] [--title <text>] [--app-id <id>] [--plume <path>] [--no-install]
```

A new project in `<name>/` (alias: `plume new`). Every template uses Vite and
TypeScript, with Tailwind CSS. `--plume` uses a local checkout of Plume instead
of fetching it; `--no-install` skips `npm install`.

## plume dev

The application on the frontend's dev server, with the engine's dev profile
(F12 opens the Web Inspector). Frontend changes reload the page; changes to
`src/*.zig`, `build.zig`, `build.zig.zon` or `plume.json` rebuild the
application while it runs, then restart it. Closing the window stops it.

## plume build

```sh
plume build [--compress | --compress=best | --no-compress] [--profile minimal|standard|dev] [--debug]
```

`build/bin/<name>(.exe)`: the frontend's build (and type check), packed into
the executable with the engine. `--compress` compresses it with UPX (built into
plume); `--compress=best` is smaller and takes minutes. The defaults come from
`plume.json` (`compress`, `profile`).

## plume package

```sh
plume package [--format nsis|zip|deb|tar|appimage]... [--skip-build]
```

Builds, then packages into `build/package/` ([Packages](../guides/packaging.md)).
With `"update"` in `plume.json`, also the signed update asset
([Updates](../guides/updates.md)).

## plume update

```sh
plume update keygen                    # update.key and the public key for plume.json
plume update sign <file>... [--key <file>]
```

`sign` writes `<file>.sig` with `update.key`, the `--key` file, or the key in
`PLUME_UPDATE_KEY`.

## plume doctor

Checks Zig (0.17), Node.js, npm and git, and whether `plume` is on `PATH`.

## plume upx

UPX's own command line, as `upx` would take it.

## plume version

Plume's version, its commit, and UPX's version.

## Environment

| Variable | |
| --- | --- |
| `PLUME_ZEROG_DIR` | a directory of unpacked ZeroG packages (`windows-minimal`, ...) to build with instead of the release packages |
| `PLUME_UPDATE_KEY` | the update key, for `package` and `update sign` |
| `PLUME_SMOKE` | an application quits once its page has loaded (exit status 1 if it failed) |
