#!/usr/bin/env bash
#
# redpanda-rpm-to-tarball.sh
#
# Converts Redpanda RPM packages into a single versioned, self-contained
# tarball suitable for unpacking multiple Redpanda versions side by side on
# one host.
#
# It downloads (or accepts locally) these three RPMs for a given version:
#     redpanda, redpanda-rpk, redpanda-tuner
# extracts each with `rpm2cpio | cpio -idmv` into one shared staging tree,
# and tars the merged tree up as redpanda-<version>.tar.gz.
#
# ---------------------------------------------------------------------------
# IMPORTANT LIMITATION -- THIS IS A FILE-CONTENT REPACKAGER, NOT AN INSTALLER
# ---------------------------------------------------------------------------
# Nothing is installed and no RPM scriptlets are executed. Everything the
# RPM's %pre/%post/%postun scriptlets would normally do is therefore NOT done,
# including but not limited to:
#
#   * creating the `redpanda` system user and group
#   * chown/chmod of /var/lib/redpanda and friends
#   * setting file capabilities on the redpanda binary
#     (e.g. cap_sys_nice, cap_ipc_lock, cap_sys_resource)
#   * registering, enabling or reloading systemd units
#   * any `rpk redpanda tune` / tuner bootstrap or sysctl tuning
#   * RPM database registration (so `rpm -q redpanda` will not see it)
#   * GPG signature verification of the downloaded RPMs
#
# Additionally, the shipped files themselves assume the RPM's absolute paths:
# /opt/redpanda/bin/* are wrapper scripts that hardcode /opt/redpanda/lib and
# /opt/redpanda/libexec, /usr/bin/{redpanda,rpk} are symlinks into /opt, and
# the systemd units reference absolute /opt, /etc and /var paths. Relocating
# the extracted tree to a per-version prefix REQUIRES editing those wrappers
# and units by hand. The printed manifest flags the files involved.
#
# The sharpest edge, worth repeating: because the bin/* wrappers exec
# /opt/redpanda/libexec/<prog> by absolute path, running an unpacked tree's
# wrapper executes whatever is installed at /opt/redpanda -- not the version
# that was unpacked -- silently and with a zero exit status. Run this
# tarball's own binaries through the bundled loader instead:
#
#   "$PREFIX/opt/redpanda/lib/ld.so" \
#       --library-path "$PREFIX/opt/redpanda/lib" \
#       "$PREFIX/opt/redpanda/libexec/redpanda" --version
#
# Consider the output a build artifact for controlled, manual side-by-side
# deployment -- not a substitute for `dnf install redpanda`.
# ---------------------------------------------------------------------------

set -euo pipefail

readonly PROGNAME=${0##*/}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

# Redpanda's public RPM repo. This is the baseurl the official
# dl.redpanda.com/public/redpanda/config.rpm.txt hands out, with packages
# stored flat under <base>/<arch>/<pkg>-<ver>-<rel>.<arch>.rpm.
#
# NOTE: the Cloudsmith vanity host linux.pkg.redpanda.com does not serve these
# paths (it returns 404), so dl.redpanda.com is used instead. Override with
# --repo-base or REDPANDA_REPO_BASE if your environment fronts the repo with a
# mirror or a proxy.
DEFAULT_REPO_BASE='https://dl.redpanda.com/public/redpanda/rpm/el'

REPO_BASE=${REDPANDA_REPO_BASE:-$DEFAULT_REPO_BASE}
EL_VERSION=9
RPM_RELEASE=1
ARCH=''
OUTPUT_DIR=$PWD
KEEP_STAGING=0
FLAT_TARBALL=0
VERSION=''
declare -a LOCAL_RPMS=()

# The package set that makes up a usable side-by-side install.
readonly PACKAGES=(redpanda redpanda-rpk redpanda-tuner)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf '%s: error: %s\n' "$PROGNAME" "$*" >&2; exit 1; }

usage() {
    cat <<HELPTEXT
$PROGNAME - repackage Redpanda RPMs into a versioned, self-contained tarball

USAGE
    $PROGNAME [options] <version>
    $PROGNAME [options] <package.rpm> [package.rpm ...]

DESCRIPTION
    Given a Redpanda version (e.g. 25.3.14), downloads the redpanda,
    redpanda-rpk and redpanda-tuner RPMs for that version, extracts all three
    with 'rpm2cpio | cpio -idmv' into one merged staging tree, and packages
    that tree as redpanda-<version>.tar.gz.

    Alternatively, pass local .rpm file paths instead of a version to
    repackage RPMs you already have on disk (no network access needed).

    The tarball is verified to exist and be non-empty, and its size and
    SHA256 checksum are printed. A manifest of the important paths -- the
    redpanda and rpk binaries, default configs under etc/, and any systemd
    units -- is printed and also written next to the tarball as
    redpanda-<version>.manifest.txt.

    !! THIS DOES NOT INSTALL ANYTHING AND RUNS NO RPM SCRIPTLETS !!

    No %pre/%post scriptlet work is performed. In particular the script does
    NOT create the 'redpanda' system user or group, does NOT chown data
    directories, does NOT set file capabilities (cap_sys_nice, cap_ipc_lock,
    cap_sys_resource) on the redpanda binary, does NOT enable or reload any
    systemd unit, does NOT run any 'rpk redpanda tune' / tuner or sysctl
    tuning, does NOT register anything in the RPM database, and does NOT
    verify RPM GPG signatures. All of that remains your responsibility.

    The extracted files also hardcode the RPM's absolute paths: the
    /opt/redpanda/bin/* wrappers point at /opt/redpanda/lib and
    /opt/redpanda/libexec, /usr/bin/{redpanda,rpk} are symlinks into /opt,
    and the systemd units reference absolute /opt, /etc and /var paths.
    Unpacking this tarball under a per-version prefix therefore requires
    editing those wrappers and units by hand. The manifest flags them.

    Most importantly: opt/redpanda/bin/* exec /opt/redpanda/libexec/<prog>
    by absolute path, so running an unpacked tree's wrapper silently runs
    whichever Redpanda is installed at /opt/redpanda -- NOT the version you
    unpacked, and with no error to tell you so. To run this tarball's own
    binaries from a prefix without editing anything, call the bundled loader:

        "\$PREFIX/opt/redpanda/lib/ld.so" \\
            --library-path "\$PREFIX/opt/redpanda/lib" \\
            "\$PREFIX/opt/redpanda/libexec/redpanda" --version

    and always pass an explicit --config so the per-version redpanda.yaml is
    used rather than /etc/redpanda/redpanda.yaml.

OPTIONS
    -h, --help              Show this help and exit.
        --keep-staging      Do not delete the extracted staging tree (and the
                            downloaded RPMs) after creating the tarball, so
                            the merged file tree can be inspected.
    -o, --output-dir DIR    Where to write the tarball, manifest, staging tree
                            and downloads. Default: current directory.
        --arch ARCH         Package architecture to download (x86_64,
                            aarch64). Default: derived from 'uname -m'.
        --el-version N      Enterprise Linux major version in the repo path.
                            Default: $EL_VERSION.
        --rpm-release N     RPM release field used to build filenames
                            (<pkg>-<ver>-<rel>.<arch>.rpm). Default: $RPM_RELEASE.
        --repo-base URL     Repo base URL, without the trailing
                            /<el-version>/<arch>. Default:
                            $DEFAULT_REPO_BASE
                            (Also settable via \$REDPANDA_REPO_BASE.)
        --version VER       Version string to use when naming the tarball.
                            Only needed with local .rpm inputs whose filenames
                            do not carry a parseable version.
        --flat              Pack the tree at the tarball root (./usr, ./etc,
                            ./opt) instead of under a top-level
                            redpanda-<version>/ directory. Extracting a flat
                            tarball splatters into the current directory --
                            the default top-level directory is safer for
                            side-by-side use.

EXAMPLES
    # Download and repackage 25.3.14 for this machine's architecture
    $PROGNAME 25.3.14

    # Keep the extracted tree for inspection, write everything to /tmp/build
    $PROGNAME --keep-staging -o /tmp/build 25.3.14

    # Build an aarch64 tarball from an x86_64 workstation
    $PROGNAME --arch aarch64 25.3.14

    # Repackage RPMs already on disk
    $PROGNAME ./redpanda-25.3.14-1.x86_64.rpm \\
              ./redpanda-rpk-25.3.14-1.x86_64.rpm \\
              ./redpanda-tuner-25.3.14-1.x86_64.rpm

EXIT STATUS
    0 on success. Non-zero, with a message on stderr, for missing
    dependencies, failed or missing downloads, an empty extraction, or a
    missing/empty tarball.
HELPTEXT
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

declare -a positional=()

while (( $# )); do
    case $1 in
        -h|--help)      usage; exit 0 ;;
        --keep-staging) KEEP_STAGING=1; shift ;;
        --flat)         FLAT_TARBALL=1; shift ;;
        -o|--output-dir) [[ ${2:-} ]] || die "--output-dir requires a value"; OUTPUT_DIR=$2; shift 2 ;;
        --arch)          [[ ${2:-} ]] || die "--arch requires a value";        ARCH=$2; shift 2 ;;
        --el-version)    [[ ${2:-} ]] || die "--el-version requires a value";  EL_VERSION=$2; shift 2 ;;
        --rpm-release)   [[ ${2:-} ]] || die "--rpm-release requires a value"; RPM_RELEASE=$2; shift 2 ;;
        --repo-base)     [[ ${2:-} ]] || die "--repo-base requires a value";   REPO_BASE=${2%/}; shift 2 ;;
        --version)       [[ ${2:-} ]] || die "--version requires a value";     VERSION=$2; shift 2 ;;
        --)             shift; positional+=("$@"); break ;;
        -*)             die "unknown option: $1 (try --help)" ;;
        *)              positional+=("$1"); shift ;;
    esac
done

(( ${#positional[@]} )) || { usage >&2; die "no version or .rpm file given"; }

# Decide between "download a version" mode and "use local RPMs" mode.
# Mixing the two is rejected rather than guessed at.
rpm_count=0
for arg in "${positional[@]}"; do
    [[ $arg == *.rpm ]] && (( ++rpm_count )) || true
done

if (( rpm_count == 0 )); then
    (( ${#positional[@]} == 1 )) || die "expected a single version argument, got ${#positional[@]}: ${positional[*]}"
    arg=${positional[0]}
    [[ $arg =~ ^[0-9]+(\.[0-9]+)*([.-][A-Za-z0-9]+)*$ ]] \
        || die "'$arg' does not look like a Redpanda version (e.g. 25.3.14) or a .rpm path"
    [[ -z $VERSION || $VERSION == "$arg" ]] \
        || die "--version '$VERSION' conflicts with positional version '$arg'"
    VERSION=$arg
    MODE=download
elif (( rpm_count == ${#positional[@]} )); then
    LOCAL_RPMS=("${positional[@]}")
    MODE=local
else
    die "cannot mix a version argument with .rpm file paths"
fi

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

require_cmd() {
    command -v "$1" >/dev/null 2>&1 \
        || die "required command '$1' not found in PATH${2:+ ($2)}"
}

check_dependencies() {
    require_cmd rpm2cpio "provided by the 'rpm' package on RPM distros, or 'rpm2cpio'/'rpm' on Debian/Ubuntu"
    require_cmd cpio     "provided by the 'cpio' package"
    require_cmd tar
    require_cmd gzip
    [[ $MODE == download ]] && require_cmd curl

    if command -v sha256sum >/dev/null 2>&1; then
        SHA256_CMD=(sha256sum)
    elif command -v shasum >/dev/null 2>&1; then
        SHA256_CMD=(shasum -a 256)
    else
        die "no SHA256 tool found: install coreutils (sha256sum) or perl (shasum)"
    fi

    # rpm2cpio on some systems is a shell script that shells out to rpm.
    if [[ $(head -c 2 "$(command -v rpm2cpio)" 2>/dev/null || true) == '#!' ]]; then
        command -v rpm >/dev/null 2>&1 \
            || die "rpm2cpio is a wrapper script but 'rpm' is not in PATH; install the 'rpm' package"
    fi
}

# ---------------------------------------------------------------------------
# Version / architecture resolution
# ---------------------------------------------------------------------------

resolve_arch() {
    [[ -n $ARCH ]] && return 0
    local machine
    machine=$(uname -m)
    case $machine in
        x86_64|amd64)  ARCH=x86_64 ;;
        aarch64|arm64) ARCH=aarch64 ;;
        *) die "cannot map host architecture '$machine' to a Redpanda package arch; pass --arch" ;;
    esac
}

# Best-effort version discovery from a local RPM: ask rpm if it is available,
# otherwise parse the conventional <name>-<version>-<release>.<arch>.rpm name.
version_from_rpm() {
    local path=$1 base ver
    if command -v rpm >/dev/null 2>&1; then
        ver=$(rpm -qp --queryformat '%{VERSION}' "$path" 2>/dev/null || true)
        [[ -n $ver && $ver != '(none)' ]] && { printf '%s\n' "$ver"; return 0; }
    fi
    base=${path##*/}
    base=${base%.rpm}
    base=${base%.*}          # strip .<arch>
    if [[ $base =~ -([0-9][^-]*)-[^-]+$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

resolve_local_inputs() {
    local rpm
    for rpm in "${LOCAL_RPMS[@]}"; do
        [[ -f $rpm ]] || die "no such .rpm file: $rpm"
        [[ -r $rpm ]] || die "cannot read .rpm file: $rpm"
        [[ -s $rpm ]] || die "empty .rpm file: $rpm"
    done

    if [[ -z $VERSION ]]; then
        local candidate=''
        for rpm in "${LOCAL_RPMS[@]}"; do
            case ${rpm##*/} in
                redpanda-[0-9]*) candidate=$(version_from_rpm "$rpm" || true) ;;
            esac
            [[ -n $candidate ]] && break
        done
        [[ -z $candidate ]] && candidate=$(version_from_rpm "${LOCAL_RPMS[0]}" || true)
        [[ -n $candidate ]] \
            || die "could not determine the Redpanda version from the given .rpm files; pass --version"
        VERSION=$candidate
    fi

    # Warn (do not fail) if the usual three-package set is incomplete: a
    # partial tarball is a legitimate thing to ask for, but a silent one is not.
    local pkg found
    for pkg in "${PACKAGES[@]}"; do
        found=0
        for rpm in "${LOCAL_RPMS[@]}"; do
            [[ ${rpm##*/} == "$pkg"-[0-9]* ]] && { found=1; break; }
        done
        (( found )) || warn "no '$pkg' RPM among the given files; the tarball will be missing its contents"
    done
}

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

rpm_url() {
    printf '%s/%s/%s/%s-%s-%s.%s.rpm\n' \
        "${REPO_BASE%/}" "$EL_VERSION" "$ARCH" "$1" "$VERSION" "$RPM_RELEASE" "$ARCH"
}

# Best-effort: on a 404, look in the repo metadata for versions that do exist
# so the failure message is actionable instead of just "not found".
suggest_versions() {
    local pkg=$1 repo="${REPO_BASE%/}/$EL_VERSION/$ARCH" primary versions
    command -v gunzip >/dev/null 2>&1 || return 0
    primary=$(curl -sSLf --max-time 30 "$repo/repodata/repomd.xml" 2>/dev/null \
        | grep -oE 'repodata/[0-9a-f]+-primary\.xml\.gz' | head -1) || return 0
    [[ -n $primary ]] || return 0
    versions=$(curl -sSLf --max-time 120 "$repo/$primary" 2>/dev/null \
        | gunzip -c 2>/dev/null \
        | grep -oE "<location href=\"${pkg}-[0-9][^\"]*\"" \
        | sed -E "s|.*\"${pkg}-||; s|-[^-]*\.rpm\"$||" \
        | sort -Vu | tail -8 | tr '\n' ' ') || return 0
    [[ -n ${versions// } ]] && info "versions of '$pkg' currently in the repo: $versions"
    return 0
}

download_rpms() {
    local pkg url dest code progress=(--silent)
    [[ -t 1 ]] && progress=(--progress-bar)

    log "Downloading ${#PACKAGES[@]} RPMs for Redpanda $VERSION ($ARCH, el$EL_VERSION)"
    info "repo: ${REPO_BASE%/}/$EL_VERSION/$ARCH"

    for pkg in "${PACKAGES[@]}"; do
        url=$(rpm_url "$pkg")
        dest="$DOWNLOAD_DIR/${url##*/}"

        # Probe first so a missing package produces a clear message rather
        # than a truncated or HTML-error-page "RPM".
        code=$(curl -sIL --max-time 60 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)
        case $code in
            200) ;;
            404)
                warn "not found: $url"
                suggest_versions "$pkg"
                die "package '$pkg' version $VERSION is not available for $ARCH/el$EL_VERSION" ;;
            000)
                die "could not reach ${REPO_BASE%/} (network, DNS or TLS failure); check connectivity or pass --repo-base" ;;
            *)
                die "unexpected HTTP $code for $url" ;;
        esac

        info "fetching ${url##*/}"
        curl -fSL "${progress[@]}" --retry 3 --retry-delay 2 --max-time 1800 \
            -o "$dest.part" "$url" \
            || die "download failed: $url"
        [[ -s $dest.part ]] || die "downloaded file is empty: $url"
        mv -f "$dest.part" "$dest"
        RPMS+=("$dest")
    done
}

# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

count_files() { find "$1" -mindepth 1 \( -type f -o -type l \) -printf . 2>/dev/null | wc -c; }

extract_rpms() {
    local rpm before after added log_file
    log "Extracting into staging tree: $STAGING_DIR"

    for rpm in "${RPMS[@]}"; do
        before=$(count_files "$STAGING_DIR")
        log_file="$WORK_DIR/cpio-${rpm##*/}.log"

        # rpm2cpio | cpio -idmv, per the requirement. Paths inside an RPM's
        # cpio payload are relative ('./usr/bin/redpanda'), so all three
        # packages merge into one tree here. --no-absolute-filenames is a
        # guard against a payload that tries to escape the staging directory.
        # cpio's -v listing is verbose; it goes to a log rather than the
        # console, and is summarised below.
        if ! ( cd "$STAGING_DIR" && rpm2cpio "$rpm" | cpio -idmv --no-absolute-filenames ) \
                >"$log_file" 2>&1; then
            warn "cpio/rpm2cpio output follows:"
            sed 's/^/    /' "$log_file" >&2 || true
            die "failed to extract $rpm (is it a valid, complete RPM?)"
        fi

        after=$(count_files "$STAGING_DIR")
        added=$(( after - before ))
        (( added > 0 )) || die "extracting ${rpm##*/} added no files to the staging tree; refusing to build a broken tarball"
        info "$(printf '%-44s %5d files' "${rpm##*/}" "$added")"
    done

    TOTAL_FILES=$(count_files "$STAGING_DIR")
    (( TOTAL_FILES > 0 )) || die "staging tree is empty after extraction; refusing to build an empty tarball"
    log "Extracted $TOTAL_FILES files/symlinks total"
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

is_elf() {
    [[ -f $1 ]] || return 1
    [[ $(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n') == 7f454c46 ]]
}

# Describe one path relative to the staging tree: symlink target, ELF binary,
# script interpreter, or plain file with its size.
describe() {
    local rel=$1 abs="$STAGING_DIR/$1" shebang
    if [[ -L $abs ]]; then
        printf '%s -> %s (symlink)' "$rel" "$(readlink "$abs")"
    elif is_elf "$abs"; then
        printf '%s (ELF binary, %s bytes)' "$rel" "$(wc -c <"$abs" | tr -d ' ')"
    elif [[ -f $abs ]]; then
        shebang=$(head -c 128 "$abs" 2>/dev/null | head -1)
        if [[ $shebang == '#!'* ]]; then
            printf '%s (script, %s)' "$rel" "${shebang#\#!}"
        else
            printf '%s (%s bytes)' "$rel" "$(wc -c <"$abs" | tr -d ' ')"
        fi
    else
        printf '%s (missing)' "$rel"
    fi
}

# Executable files and symlinks in the tree with the given basename, relative
# to staging. The executable filter keeps non-binaries that merely share the
# name (e.g. etc/sysconfig/redpanda) out of the binary sections.
find_named() {
    ( cd "$STAGING_DIR" \
        && find . \( \( -type f -perm -u+x \) -o -type l \) -name "$1" -printf '%P\n' 2>/dev/null \
        | sort )
}

# All files/symlinks under the given relative directory.
find_under() {
    local rel=$1
    [[ -d "$STAGING_DIR/$rel" ]] || return 0
    ( cd "$STAGING_DIR" && find "$rel" \( -type f -o -type l \) -printf '%P\n' 2>/dev/null \
        | sed "s|^|$rel/|" | sort )
}

print_manifest() {
    local p paths config_dirs=(etc/redpanda etc/redpanda.d etc/sysconfig) any

    printf '\n'
    printf '===========================================================================\n'
    printf ' MANIFEST -- redpanda %s (%s)\n' "$VERSION" "$ARCH"
    printf '===========================================================================\n'

    # --- redpanda binary ---------------------------------------------------
    printf '\nredpanda binary:\n'
    paths=$(find_named redpanda || true)
    if [[ -z $paths ]]; then
        printf '  !! no file named "redpanda" found in the tree\n'
    else
        while IFS= read -r p; do
            [[ -n $p ]] || continue
            if is_elf "$STAGING_DIR/$p"; then
                printf '  MAIN  %s\n' "$(describe "$p")"
            else
                printf '        %s\n' "$(describe "$p")"
            fi
        done <<<"$paths"
    fi

    # --- rpk binary --------------------------------------------------------
    printf '\nrpk binary:\n'
    paths=$(find_named rpk || true)
    if [[ -z $paths ]]; then
        printf '  !! no file named "rpk" found in the tree (was redpanda-rpk included?)\n'
    else
        while IFS= read -r p; do
            [[ -n $p ]] || continue
            if is_elf "$STAGING_DIR/$p"; then
                printf '  MAIN  %s\n' "$(describe "$p")"
            else
                printf '        %s\n' "$(describe "$p")"
            fi
        done <<<"$paths"
    fi

    # --- default configuration --------------------------------------------
    printf '\nDefault configuration files:\n'
    any=0
    for p in "${config_dirs[@]}"; do
        while IFS= read -r f; do
            [[ -n $f ]] || continue
            printf '        %s\n' "$f"
            any=1
        done < <(find_under "$p" || true)
    done
    (( any )) || printf '        (none found under %s)\n' "${config_dirs[*]}"

    # --- systemd units, flagged -------------------------------------------
    printf '\nsystemd units and presets:\n'
    any=0
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        printf '  UNIT  %s\n' "$f"
        any=1
    done < <( { find_under usr/lib/systemd; find_under lib/systemd; find_under etc/systemd; } 2>/dev/null | sort -u )

    if (( any )); then
        cat <<'UNITWARN'

  ***********************************************************************
  *  ATTENTION: these unit files came straight out of the RPM and refer
  *  to ABSOLUTE system paths (/opt/redpanda/..., /etc/redpanda/...,
  *  /var/lib/redpanda/...), a `redpanda` user that this script does NOT
  *  create, and file capabilities this script does NOT set.
  *
  *  For a side-by-side install they MUST be edited by hand before use:
  *  give each version its own unit name, rewrite ExecStart / config and
  *  data paths to the per-version prefix, and review User=, Slice= and
  *  the AmbientCapabilities / LimitMEMLOCK settings. Do not `systemctl
  *  enable` them as-is -- two versions' units will collide.
  ***********************************************************************
UNITWARN
    else
        printf '        (none found)\n'
    fi

    # --- relocation hazards ------------------------------------------------
    printf '\nPaths hardcoded for relocation review:\n'
    any=0
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        printf '        %s\n' "$(describe "$f")"
        any=1
    done < <( { find_under opt/redpanda/bin; find_under usr/bin; } 2>/dev/null | sort -u )
    (( any )) || printf '        (none found)\n'

    cat <<RELOCWARN

  ***********************************************************************
  *  ATTENTION: the wrappers and symlinks above embed ABSOLUTE paths.
  *  opt/redpanda/bin/* exec /opt/redpanda/libexec/<prog> literally, so
  *  running them from an unpacked tree does NOT run this tarball's
  *  binaries -- it runs whatever is installed at /opt/redpanda, silently
  *  and with no error. That is the opposite of what a side-by-side
  *  install needs. Verified behaviour, not a theoretical concern.
  *
  *  To run THIS version's binaries out of an unpacked tree at \$PREFIX
  *  without editing anything, invoke the bundled loader directly:
  *
  *    "\$PREFIX/opt/redpanda/lib/ld.so" \\
  *        --library-path "\$PREFIX/opt/redpanda/lib" \\
  *        "\$PREFIX/opt/redpanda/libexec/redpanda" --help
  *
  *  (same shape for libexec/rpk). Otherwise rewrite the bin/* wrappers
  *  to point at \$PREFIX, and always pass an explicit --config so the
  *  per-version redpanda.yaml is used instead of /etc/redpanda.
  ***********************************************************************
RELOCWARN

    printf '\nTotal files/symlinks in tree: %s\n' "$TOTAL_FILES"
    printf '===========================================================================\n'
}

# ---------------------------------------------------------------------------
# Tarball
# ---------------------------------------------------------------------------

create_tarball() {
    local -a tar_opts=(--create --gzip)

    # Normalise ownership and entry order so the artifact does not carry the
    # build user's uid/gid and lists predictably. (File mtimes come from the
    # RPM payload, but freshly created directories get the build time, so the
    # gzip stream is not bit-for-bit reproducible across runs.) GNU tar only.
    if tar --version 2>/dev/null | head -1 | grep -q GNU; then
        tar_opts+=(--numeric-owner --owner=0 --group=0)
        tar --help 2>/dev/null | grep -q -- '--sort' && tar_opts+=(--sort=name)
    fi

    log "Creating $TARBALL"
    # The staging tree already lives inside $STAGING_ROOT/$TOP_DIR, so the
    # top-level directory comes for free -- no path rewriting needed. --flat
    # instead packs the tree's own contents at the archive root.
    if (( FLAT_TARBALL )); then
        info "layout: flat (./etc, ./opt, ./usr at the tarball root)"
        tar "${tar_opts[@]}" --file "$TARBALL" --directory "$STAGING_DIR" . \
            || die "failed to create tarball $TARBALL"
    else
        info "layout: everything under top-level directory $TOP_DIR/"
        tar "${tar_opts[@]}" --file "$TARBALL" --directory "$STAGING_ROOT" "$TOP_DIR" \
            || die "failed to create tarball $TARBALL"
    fi
}

validate_tarball() {
    local size human entries sha

    [[ -f $TARBALL ]] || die "tarball was not created: $TARBALL"
    size=$(wc -c <"$TARBALL" | tr -d ' ')
    (( size > 0 )) || die "tarball is empty: $TARBALL"

    # Read it back so a corrupt or truncated archive is caught here.
    entries=$(tar --list --file "$TARBALL" 2>/dev/null | wc -l | tr -d ' ') \
        || die "tarball is not readable by tar: $TARBALL"
    (( entries > 0 )) || die "tarball contains no entries: $TARBALL"

    if command -v numfmt >/dev/null 2>&1; then
        human=$(numfmt --to=iec --suffix=B "$size")
    else
        human=$(du -h "$TARBALL" | cut -f1)
    fi

    sha=$("${SHA256_CMD[@]}" "$TARBALL" | awk '{print $1}')

    printf '\n'
    log "Tarball verified"
    info "path:     $TARBALL"
    info "size:     $size bytes ($human)"
    info "entries:  $entries (files, symlinks and directories)"
    info "sha256:   $sha"

    SHA256_VALUE=$sha
    TARBALL_SIZE=$size
    TARBALL_ENTRIES=$entries
}

write_manifest_file() {
    {
        printf 'Redpanda side-by-side tarball manifest\n'
        printf 'Generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'Version:   %s\n' "$VERSION"
        printf 'Arch:      %s\n' "$ARCH"
        printf 'Source:    %s\n' "$SOURCE_DESC"
        printf 'Tarball:   %s\n' "${TARBALL##*/}"
        printf 'Size:      %s bytes\n' "$TARBALL_SIZE"
        printf 'Entries:   %s\n' "$TARBALL_ENTRIES"
        printf 'SHA256:    %s\n' "$SHA256_VALUE"
        printf '\nInput RPMs:\n'
        printf '  %s\n' "${RPMS[@]##*/}"
        printf '\nNOT PERFORMED (no RPM scriptlets were run): redpanda user/group\n'
        printf 'creation, data directory ownership, file capabilities on the redpanda\n'
        printf 'binary, systemd unit registration/reload, rpk tuning, RPM database\n'
        printf 'registration, GPG signature verification.\n'
        print_manifest
    } >"$MANIFEST_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

cleanup() {
    local rc=$?
    if (( KEEP_STAGING )); then
        [[ -d ${WORK_DIR:-} ]] && {
            printf '\n'
            log "Kept for inspection (--keep-staging):"
            info "staging tree: $STAGING_DIR"
            [[ -d ${DOWNLOAD_DIR:-} ]] && info "input RPMs:   $DOWNLOAD_DIR"
            info "cpio logs:    $WORK_DIR/cpio-*.log"
        }
    elif [[ -n ${WORK_DIR:-} && -d ${WORK_DIR:-} ]]; then
        rm -rf -- "$WORK_DIR"
    fi
    return $rc
}

main() {
    check_dependencies
    resolve_arch

    if [[ $MODE == local ]]; then
        resolve_local_inputs
    fi

    mkdir -p -- "$OUTPUT_DIR" || die "cannot create output directory: $OUTPUT_DIR"
    OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

    TOP_DIR="redpanda-$VERSION"
    TARBALL="$OUTPUT_DIR/redpanda-$VERSION.tar.gz"
    MANIFEST_FILE="$OUTPUT_DIR/redpanda-$VERSION.manifest.txt"

    WORK_DIR="$OUTPUT_DIR/.redpanda-$VERSION.build"
    STAGING_ROOT="$WORK_DIR/staging"
    STAGING_DIR="$STAGING_ROOT/$TOP_DIR"
    DOWNLOAD_DIR="$WORK_DIR/rpms"
    TOTAL_FILES=0
    declare -ga RPMS=()

    rm -rf -- "$WORK_DIR"
    mkdir -p -- "$STAGING_DIR" "$DOWNLOAD_DIR"
    trap cleanup EXIT

    log "Redpanda $VERSION -> ${TARBALL##*/}"

    if [[ $MODE == download ]]; then
        SOURCE_DESC="${REPO_BASE%/}/$EL_VERSION/$ARCH"
        download_rpms
    else
        SOURCE_DESC="local files"
        RPMS=("${LOCAL_RPMS[@]}")
        log "Using ${#RPMS[@]} local RPM(s) for version $VERSION"
        printf '    %s\n' "${RPMS[@]}"
    fi

    extract_rpms
    print_manifest
    create_tarball
    validate_tarball
    write_manifest_file

    printf '\n'
    log "Done. Manifest written to ${MANIFEST_FILE##*/}"
    warn "no RPM scriptlets were run: the 'redpanda' user was not created, no file capabilities were set, and systemd units are unmodified. See --help."
}

main "$@"
