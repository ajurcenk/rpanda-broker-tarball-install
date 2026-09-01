# redpanda-rpm-to-tarball

Turns Redpanda RPM packages into a single versioned, self-contained tarball
(`redpanda-<version>.tar.gz`) so several Redpanda versions can be unpacked
side by side on one host.

It downloads (or accepts locally) the three RPMs that make up a usable
install — `redpanda`, `redpanda-rpk`, `redpanda-tuner` — extracts each with
`rpm2cpio | cpio -idmv` into one merged staging tree, tars that tree up, then
verifies the result and prints a manifest of the paths that matter.

## This is a repackager, not an installer

**No RPM scriptlets are run.** Nothing the `%pre`/`%post`/`%postun` scriptlets
would normally do is done, including:

- creating the `redpanda` system user and group
- `chown`/`chmod` of `/var/lib/redpanda` and friends
- setting file capabilities on the `redpanda` binary (`cap_sys_nice`,
  `cap_ipc_lock`, `cap_sys_resource`)
- registering, enabling or reloading systemd units
- any `rpk redpanda tune` / tuner bootstrap or sysctl tuning
- RPM database registration (`rpm -q redpanda` will not see it)
- GPG signature verification of the downloaded RPMs

All of that stays your responsibility. Treat the output as a build artifact for
controlled, manual deployment — not as a substitute for `dnf install redpanda`.

There is one more sharp edge that matters enormously for side-by-side use; see
[Deploying side by side](#deploying-side-by-side) before you unpack anything.

## Requirements

| Tool | Provided by | Needed for |
| --- | --- | --- |
| `rpm2cpio` | `rpm` (RPM distros), `rpm2cpio`/`rpm` (Debian/Ubuntu) | extraction |
| `cpio` | `cpio` | extraction |
| `tar`, `gzip` | base system | packaging |
| `curl` | `curl` | downloading only |
| `sha256sum` or `shasum` | `coreutils` / `perl` | checksum |

GNU `find` and GNU `tar` are assumed (this is a Linux/RPM-targeted tool). The
script checks each dependency up front and fails with a message naming the
package to install. If `rpm2cpio` is the shell-wrapper variant, it also checks
that `rpm` itself is on `PATH`.

No root privileges are needed, and nothing outside the output directory is
touched.

## Quick start

```bash
# Download and repackage 25.3.14 for this machine's architecture
./redpanda-rpm-to-tarball.sh 25.3.14

# Keep the extracted tree for inspection, write everything to /tmp/build
./redpanda-rpm-to-tarball.sh --keep-staging -o /tmp/build 25.3.14

# Build an aarch64 tarball from an x86_64 workstation
./redpanda-rpm-to-tarball.sh --arch aarch64 25.3.14

# Repackage RPMs already on disk (no network access needed)
./redpanda-rpm-to-tarball.sh \
    ./redpanda-25.3.14-1.x86_64.rpm \
    ./redpanda-rpk-25.3.14-1.x86_64.rpm \
    ./redpanda-tuner-25.3.14-1.x86_64.rpm
```

A full run for 25.3.14 takes roughly 20 seconds and produces a ~98 MB tarball.

## Usage

```
redpanda-rpm-to-tarball.sh [options] <version>
redpanda-rpm-to-tarball.sh [options] <package.rpm> [package.rpm ...]
```

Pass either a single version (`25.3.14`) to download, or one or more local
`.rpm` paths. Mixing the two is rejected rather than guessed at. If a local
input set is missing one of the three packages you get a warning, not a silent
partial tarball.

### Options

| Option | Description |
| --- | --- |
| `-h`, `--help` | Show the built-in help, including the full limitations text. |
| `--keep-staging` | Keep the extracted staging tree, the input RPMs and the `cpio` logs after tarring, instead of deleting them. |
| `-o`, `--output-dir DIR` | Where to write the tarball, manifest and build directory. Default: current directory. |
| `--arch ARCH` | Package architecture (`x86_64`, `aarch64`). Default: derived from `uname -m`. |
| `--el-version N` | Enterprise Linux major version in the repo path. Default: `9`. |
| `--rpm-release N` | RPM release field used to build filenames (`<pkg>-<ver>-<rel>.<arch>.rpm`). Default: `1`. |
| `--repo-base URL` | Repo base URL, without the trailing `/<el-version>/<arch>`. Also settable via `$REDPANDA_REPO_BASE`. |
| `--version VER` | Version string for naming, when local `.rpm` filenames carry no parseable version. |
| `--flat` | Pack the tree at the archive root (`./etc`, `./opt`, `./usr`) instead of under a top-level `redpanda-<version>/` directory. |

### About the package repo URL

The default base is:

```
https://dl.redpanda.com/public/redpanda/rpm/el/<el-version>/<arch>
```

with packages stored flat as `<pkg>-<version>-1.<arch>.rpm`. This is the
`baseurl` that Redpanda's own repo config
(`dl.redpanda.com/public/redpanda/config.rpm.txt`) hands out.

Note that the Cloudsmith vanity host `linux.pkg.redpanda.com` does **not**
serve these paths — every variant tried returns HTTP 404, including the
repodata and the GPG key — so `dl.redpanda.com` is used instead. Use
`--repo-base` or `$REDPANDA_REPO_BASE` if your environment fronts the repo
with an internal mirror or proxy.

## Output

Written to the output directory (default: the current directory):

| File | Contents |
| --- | --- |
| `redpanda-<version>.tar.gz` | The merged file tree, under a top-level `redpanda-<version>/` directory. |
| `redpanda-<version>.manifest.txt` | Build provenance (version, arch, source, size, SHA256, input RPMs) plus the printed manifest. |
| `.redpanda-<version>.build/` | Staging tree, downloaded RPMs and `cpio` logs. Deleted at exit unless `--keep-staging`. |

The tarball defaults to a top-level directory so extracting it does not
splatter `usr/ etc/ opt/ var/` into the current directory — safer for
side-by-side use. Use `--flat` for the bare tree.

Symlinks are preserved as symlinks, and ownership is normalised to `0/0` so the
artifact does not carry the build user's uid/gid:

```
-rwxr-xr-x 0/0    196946600  redpanda-25.3.14/opt/redpanda/libexec/redpanda
lrwxrwxrwx 0/0            0  redpanda-25.3.14/usr/bin/redpanda -> ../../opt/redpanda/bin/redpanda
```

File mtimes come from the RPM payload, but freshly created directories get the
build time, so the gzip stream is not bit-for-bit reproducible between runs.

### Validation

Before reporting success the script confirms the tarball exists, is non-empty,
and can be read back by `tar` with at least one entry, then prints its size and
SHA256:

```
==> Tarball verified
    path:     /home/you/redpanda-25.3.14.tar.gz
    size:     101804032 bytes (98MB)
    entries:  128 (files, symlinks and directories)
    sha256:   9a53e94148e47f5899aa31643ddaea6206119c765ac3d5e078e64f183559dac4
```

## The manifest

Printed at the end of every run and saved alongside the tarball. For 25.3.14 it
reports:

```
redpanda binary:
        opt/redpanda/bin/redpanda (script, /usr/bin/env bash)
  MAIN  opt/redpanda/libexec/redpanda (ELF binary, 196946600 bytes)
        usr/bin/redpanda -> ../../opt/redpanda/bin/redpanda (symlink)

rpk binary:
        opt/redpanda/bin/rpk (script, /usr/bin/env bash)
  MAIN  opt/redpanda/libexec/rpk (ELF binary, 94158744 bytes)
        usr/bin/rpk -> ../../opt/redpanda/bin/rpk (symlink)

Default configuration files:
        etc/redpanda/redpanda.yaml
        etc/redpanda.d/cpuset.conf
        etc/sysconfig/redpanda

systemd units and presets:
  UNIT  usr/lib/systemd/system-preset/50-redpanda.preset
  UNIT  usr/lib/systemd/system-preset/50-redpanda-tuner.preset
  UNIT  usr/lib/systemd/system/redpanda.service
  UNIT  usr/lib/systemd/system/redpanda.slice
  UNIT  usr/lib/systemd/system/redpanda-tuner.service
```

`MAIN` marks the real ELF executable, detected by magic bytes rather than by
path. `/usr/bin/*` are symlinks and `/opt/redpanda/bin/*` are shell wrappers.
`UNIT` lines and the wrapper/symlink list each come with a prominent warning
block explaining what must be edited before reuse.

The config section deliberately covers `etc/redpanda.d/` and `etc/sysconfig/`
as well as `etc/redpanda/`, because the RPM ships real configuration in all
three.

## Deploying side by side

### The trap

`opt/redpanda/bin/*` are wrapper scripts that exec an **absolute** path:

```bash
export LD_LIBRARY_PATH="/opt/redpanda/lib"
export PATH="/opt/redpanda/bin:${PATH}"
exec -a "$0" "/opt/redpanda/libexec/redpanda" "$@"
```

So running an unpacked tree's wrapper does not run that tree's binaries — it
runs whatever Redpanda is installed at `/opt/redpanda`, silently and with a
zero exit status. Unpacking the 25.3.14 tarball on a host with 26.1.8 installed
and running its own `bin/rpk` prints:

```
$ /tmp/prefix/opt/redpanda/bin/rpk version
rpk version: v26.1.8      # <-- the host's install, NOT the tarball's
```

That is the exact opposite of what side-by-side installs need, so verify the
version you actually invoked before trusting any result.

### Option 1: call the bundled loader (no edits)

Every version ships its own `ld.so` and libraries, so a tree can be run in
place:

```bash
PREFIX=/opt/redpanda-versions/25.3.14

"$PREFIX/opt/redpanda/lib/ld.so" \
    --library-path "$PREFIX/opt/redpanda/lib" \
    "$PREFIX/opt/redpanda/libexec/redpanda" --version
```

```
v25.3.14 - b6e62de74d7146fc94d430cd0db2aed3e328b481
```

`rpk` is a static Go binary and can be run directly:

```bash
"$PREFIX/opt/redpanda/libexec/rpk" version
```

### Option 2: rewrite the wrappers (one `sed`)

Point each wrapper at its own prefix. Every absolute reference in
`opt/redpanda/bin/*` is a quoted `"/opt/redpanda/..."`, so one expression
covers `LD_LIBRARY_PATH`, `PATH` and the `exec` target:

```bash
PREFIX=/opt/redpanda-versions/25.3.14

mkdir -p "$(dirname "$PREFIX")"
tar -xzf redpanda-25.3.14.tar.gz -C "$(dirname "$PREFIX")"
mv "$(dirname "$PREFIX")/redpanda-25.3.14" "$PREFIX"

sed -i "s|\"/opt/redpanda/|\"$PREFIX/opt/redpanda/|g" "$PREFIX"/opt/redpanda/bin/*

"$PREFIX/opt/redpanda/bin/rpk" version        # -> rpk version: v25.3.14
"$PREFIX/opt/redpanda/bin/redpanda" --version # -> v25.3.14 - b6e62de7...
```

Confirm nothing was missed:

```bash
grep -o '"/opt/redpanda[^"]*"' "$PREFIX"/opt/redpanda/bin/*   # expect no output
```

`$PREFIX/usr/bin/{redpanda,rpk}` are relative symlinks (`../../opt/...`) and so
resolve correctly inside the prefix once the wrappers are fixed — but only if
you invoke them through the prefix, not via `/usr/bin`.

### Per-version configuration

Always pass an explicit `--config`, or `rpk` falls back to
`/etc/redpanda/redpanda.yaml` and every version shares one config and one data
directory:

```bash
"$PREFIX/opt/redpanda/bin/rpk" redpanda config set \
    redpanda.data_directory /var/lib/redpanda-25.3.14/data \
    --config "$PREFIX/etc/redpanda/redpanda.yaml"
```

Give each version its own `data_directory` and its own set of listener ports —
two brokers cannot share either.

### systemd units

The shipped units are unusable as-is for side-by-side installs. `redpanda.service`
contains:

```ini
EnvironmentFile=/etc/sysconfig/redpanda
EnvironmentFile=-/etc/redpanda.d/*.conf
ExecStart=/usr/bin/rpk redpanda start $START_ARGS $CPUSET
ExecStop=/usr/bin/rpk redpanda stop --timeout 5s
User=redpanda
Slice=redpanda.slice
AmbientCapabilities=CAP_SYS_NICE
```

Before enabling anything, work through this checklist — none of it is done for
you, and none of it is exercised by this script:

1. **Rename the unit** (`redpanda-25.3.14.service`). Two versions installed as
   `redpanda.service` will collide.
2. **Rewrite `ExecStart`/`ExecStop`** to `$PREFIX/opt/redpanda/bin/rpk`, and add
   `--config $PREFIX/etc/redpanda/redpanda.yaml`.
3. **Repoint both `EnvironmentFile=` lines** at the per-version `etc/sysconfig/redpanda`
   and `etc/redpanda.d/`, or drop them and set the variables inline.
4. **Create the `redpanda` user and group** yourself (`User=redpanda`), and
   `chown` the per-version data directory to it.
5. **Review `Slice=`** — either ship a renamed slice or remove the line.
6. **Set file capabilities** on `libexec/redpanda` if you need them
   (`cap_sys_nice`, `cap_ipc_lock`, `cap_sys_resource`); `AmbientCapabilities`
   in the unit does not replace them.
7. **Ignore the `system-preset` files.** They enable `redpanda.service` by name.

## Errors

Every failure mode exits non-zero with a message on stderr rather than
producing a broken tarball. Missing dependencies, unreachable repo, HTTP
errors, an empty download, a corrupt RPM, an extraction that adds no files, and
a missing or unreadable tarball are all fatal.

A missing package additionally reports what the repo does have:

```
$ ./redpanda-rpm-to-tarball.sh 99.9.9
WARNING: not found: https://dl.redpanda.com/.../redpanda-99.9.9-1.x86_64.rpm
    versions of 'redpanda' currently in the repo: 26.1.12 26.1.13 ... 26.2.1 26.2.2
redpanda-rpm-to-tarball.sh: error: package 'redpanda' version 99.9.9 is not available for x86_64/el9
```

If a version exists but not for your platform, check `--arch` and
`--el-version`; if the filename convention differs, check `--rpm-release`.

## Inspecting a build

`--keep-staging` retains the merged tree, the input RPMs and the per-package
`cpio` logs, and prints where they are:

```bash
./redpanda-rpm-to-tarball.sh --keep-staging -o /tmp/build 25.3.14
find /tmp/build/.redpanda-25.3.14.build/staging -type f | head
```

The per-package file counts printed during extraction are a quick sanity check
that all three payloads landed (70 + 18 + 11 = 99 files for 25.3.14).
