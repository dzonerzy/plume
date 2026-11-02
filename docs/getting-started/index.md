# Getting started

## What you need

- [Zig 0.17](https://ziglang.org/download/)
- [Node.js](https://nodejs.org) 20.19 or 22.12 and later (what Vite 8 needs), with npm
- Windows 10 1809 or later (x64), with Visual Studio's C++ build tools for the
  system libraries; or Linux x86_64 with glibc 2.28 or later

The engine is not something you install: `zig build` fetches ZeroG's release
package for the target and the engine profile being built, once, into Zig's
cache.

## The plume tool

Download it for your system from the
[releases](https://github.com/dzonerzy/plume/releases) and rename it `plume`
(`plume.exe` on Windows; on Linux, `chmod +x` it): projects call it by that
name. `SHA256SUMS` has the checksums. Or build it from a clone:

```sh
git clone https://github.com/dzonerzy/plume
cd plume
zig build cli -Doptimize=ReleaseSmall    # zig-out/bin/plume
```

Put it on your `PATH`, then check what it needs:

```sh
plume doctor
```

It checks Zig's version, Node.js, npm and git, and whether `plume` itself is on
`PATH` (a project's `npm run dev` and `npm run build` call it by name).

Next: [your first app](first-app.md).
