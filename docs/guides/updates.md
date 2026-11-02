# Updates

An application can update itself from its GitHub repository's releases. The
updates are signed with a key of the publisher's, which the application
trusts.

## Set up

```sh
plume update keygen
```

It writes `update.key`, the secret key (`.gitignore` has it: keep it out of
the repository, and in CI give it as the `PLUME_UPDATE_KEY` secret), and prints
the public key for `plume.json`:

```json
"update": { "github": "owner/notes", "public_key": "<the public key>" }
```

## Publish

With `"update"` in `plume.json`, `plume package` also writes the executable as
an update asset, with its Ed25519 signature:

| | |
| --- | --- |
| Windows | `notes-1.2.0-windows-x64.exe` and `notes-1.2.0-windows-x64.exe.sig` |
| Linux | `notes-1.2.0-linux-x64` and `notes-1.2.0-linux-x64.sig` |

and the executable gzip-compressed (`notes-1.2.0-windows-x64.exe.gz`, about
40 % of its size), which applications download instead when it is there (the
signature is the uncompressed executable's). It refuses to sign with a key
that is not the one `plume.json` names. Attach the files to the GitHub release
tagged `v1.2.0` (or `1.2.0`), alongside the installers. `plume update sign
<file>` signs any file the same way.

## Check and install

```ts
const release = await Plume.updates.check();   // { version, notes, size, ... } or null
if (release && confirm(`Update to ${release.version}?`)) {
  Plume.updates.on("progress", ({ received, total }) => (bar.value = received / total));
  await Plume.updates.install(release);
  Plume.updates.restart();
}
```

The pages get `update:progress` events while `install` downloads (at most one
per percent); Zig's `app.installUpdate` sends them too.

From Zig, on a worker thread (they wait on the network):

```zig
if (try app.checkForUpdate(arena)) |release| {
    try app.installUpdate(arena, release);
    try app.restart();     // starts the new executable with the same arguments, and quits
}
```

`check` asks for the latest release, which must not be a draft or a
pre-release, with a newer version than this build's. Versions compare as
semantic versions (`1.10.0` is newer than `1.9.2`; `1.2.0-beta` is older than
`1.2.0`).

`install`:

1. downloads the asset for this system and its signature;
2. checks the signature against the public key: an update that does not match
   is refused (`plume:BadSignature`);
3. runs the new executable once with `PLUME_VERIFY` set: it must start and give
   the release's version (`plume:VerifyFailed` otherwise);
4. renames the running executable to `<name>.old` and puts the new one in its
   place; if that fails, the old one gets its name back.

The next start removes the `.old` file. The executable must be somewhere the
user can write: the per-user installer puts it there.

`update.api_url` points `check` at a GitHub Enterprise server's API instead of
`https://api.github.com`.
