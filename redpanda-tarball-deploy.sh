#!/usr/bin/env bash
#
# redpanda-tarball-deploy.sh
#
# Deploy an official Redpanda self-contained tarball
# (redpanda-<version>-<arch>.tar.gz) into its own directory so that several
# Redpanda versions can be installed side by side on one host.
#
# The tarball's bin/* wrappers hardcode the absolute path /opt/redpanda/...,
# so an unpacked tree does NOT run its own binaries until those wrappers are
# rewritten. This script extracts the tree, rewrites the wrappers to the
# chosen prefix, writes a per-version redpanda.yaml, and then verifies that
# the wrappers really do resolve inside the prefix.
#
# It does NOT create the redpanda user, set file capabilities, install
# systemd units, or run rpk tuners.

set -euo pipefail

PROGNAME=${0##*/}

VERSIONS_ROOT=${REDPANDA_VERSIONS_ROOT:-/opt/redpanda-versions}
PREFIX=""
VERSION=""
DATA_DIR=""
TARBALL=""
FORCE=0
DRY_RUN=0
DO_VERIFY=1
DO_PREFLIGHT=1
ENABLE_FIPS=0

# ---------------------------------------------------------------- output ----

die()  { printf '%s: error: %s\n' "$PROGNAME" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$PROGNAME" "$*" >&2; }
info() { printf '\n==> %s\n' "$*"; }
step() { printf '    %s\n' "$*"; }

run() {
    if (( DRY_RUN )); then
        printf '    [dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

usage() {
    cat <<EOF
Usage: $PROGNAME [options] <redpanda-<version>-<arch>.tar.gz>

Deploys an official Redpanda self-contained tarball into its own prefix and
rewrites the bin/* wrappers so the tree runs its own binaries.

Options:
  -p, --prefix DIR        Install root. Default: <versions-root>/<version>
  -r, --versions-root DIR Parent for the default prefix.
                          Default: $VERSIONS_ROOT  (\$REDPANDA_VERSIONS_ROOT)
  -V, --version VER       Version string. Default: parsed from the filename.
  -d, --data-dir DIR      Per-version data root written into redpanda.yaml.
                          Default: <prefix>/var/lib/redpanda
  -f, --force             Replace an existing prefix, and allow an
                          architecture mismatch with this host.
  -n, --dry-run           Print the actions without performing them.
      --enable-fips       Add the "activate = 1" line that upstream's
                          fipsmodule.cnf is missing, so rpk-fips works.
                          Off by default: it changes the tree's crypto
                          posture, which is a decision for you to make.
      --no-verify         Skip running rpk/redpanda after deployment.
      --no-preflight      Skip the listing/space/checksum pass (faster).
  -h, --help              Show this help.

Examples:
  sudo $PROGNAME redpanda-25.2.7-amd64.tar.gz
  $PROGNAME -r ./redpanda-versions redpanda-25.2.7-amd64.tar.gz
  $PROGNAME -p /srv/rp/25.2.7 -d /data/rp/25.2.7 redpanda-25.2.7-amd64.tar.gz
EOF
}

# ------------------------------------------------------------ arguments ----

while (( $# )); do
    case $1 in
        -p|--prefix)         [[ ${2-} ]] || die "$1 needs a value"; PREFIX=$2; shift 2 ;;
        -r|--versions-root)  [[ ${2-} ]] || die "$1 needs a value"; VERSIONS_ROOT=$2; shift 2 ;;
        -V|--version)        [[ ${2-} ]] || die "$1 needs a value"; VERSION=$2; shift 2 ;;
        -d|--data-dir)       [[ ${2-} ]] || die "$1 needs a value"; DATA_DIR=$2; shift 2 ;;
        -f|--force)          FORCE=1; shift ;;
        -n|--dry-run)        DRY_RUN=1; shift ;;
        --enable-fips)       ENABLE_FIPS=1; shift ;;
        --no-verify)         DO_VERIFY=0; shift ;;
        --no-preflight)      DO_PREFLIGHT=0; shift ;;
        -h|--help)           usage; exit 0 ;;
        -*)                  die "unknown option: $1 (try --help)" ;;
        *)
            [[ -z $TARBALL ]] || die "only one tarball may be given (got '$TARBALL' and '$1')"
            TARBALL=$1; shift ;;
    esac
done

[[ -n $TARBALL ]] || { usage >&2; exit 2; }

for tool in tar gzip sed awk grep df uname; do
    command -v "$tool" >/dev/null || die "required tool not found: $tool"
done

SHA256_CMD=""
if command -v sha256sum >/dev/null; then SHA256_CMD="sha256sum"
elif command -v shasum   >/dev/null; then SHA256_CMD="shasum -a 256"
fi

# --------------------------------------------------------------- tarball ----

[[ -e $TARBALL ]] || die "no such file: $TARBALL"
[[ -f $TARBALL ]] || die "not a regular file: $TARBALL"
[[ -r $TARBALL ]] || die "not readable: $TARBALL"

TARBALL_ABS=$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")
TARBALL_BASE=${TARBALL_ABS##*/}

# Version and architecture from the filename: redpanda-<version>-<arch>.tar.gz
FILE_ARCH=""
if [[ $TARBALL_BASE =~ ^redpanda-([0-9]+\.[0-9]+\.[0-9]+[^/]*)-(amd64|x86_64|arm64|aarch64)\.tar\.gz$ ]]; then
    [[ -n $VERSION ]] || VERSION=${BASH_REMATCH[1]}
    FILE_ARCH=${BASH_REMATCH[2]}
fi

[[ -n $VERSION ]] || die "cannot parse a version from '$TARBALL_BASE'; pass --version"

case $FILE_ARCH in
    amd64|x86_64)   WANT_ARCH=x86_64 ;;
    arm64|aarch64)  WANT_ARCH=aarch64 ;;
    *)              WANT_ARCH="" ;;
esac

HOST_ARCH=$(uname -m)
if [[ -n $WANT_ARCH && $WANT_ARCH != "$HOST_ARCH" ]]; then
    if (( FORCE )); then
        warn "tarball is $FILE_ARCH ($WANT_ARCH) but this host is $HOST_ARCH; continuing due to --force"
    else
        die "tarball is $FILE_ARCH ($WANT_ARCH) but this host is $HOST_ARCH.
       The binaries will not run here. Use --force to deploy anyway (e.g. to
       stage a tree for another machine)."
    fi
fi

# ---------------------------------------------------------------- prefix ----

[[ -n $PREFIX ]] || PREFIX=$VERSIONS_ROOT/$VERSION
PREFIX=${PREFIX%/}

[[ $PREFIX == /* ]] || die "--prefix must be an absolute path (the wrappers embed it): $PREFIX"

# The prefix is substituted into sed expressions and into shell scripts, and it
# must not collide with the stock install path that is being rewritten away.
case $PREFIX in
    *[\|\&\\\"\'\$\`]*|*' '*) die "--prefix contains a character that would break the wrapper rewrite: $PREFIX" ;;
esac
case $PREFIX in
    /opt/redpanda|/opt/redpanda/*)
        die "--prefix must not be /opt/redpanda or below it: $PREFIX
       That is the path the wrappers hardcode; rewriting into it is neither
       idempotent nor side-by-side. Use something like $VERSIONS_ROOT/$VERSION." ;;
esac

[[ -n $DATA_DIR ]] || DATA_DIR=$PREFIX/var/lib/redpanda
DATA_DIR=${DATA_DIR%/}
[[ $DATA_DIR == /* ]] || die "--data-dir must be an absolute path: $DATA_DIR"

PARENT=$(dirname "$PREFIX")

info "Deploying Redpanda $VERSION"
step "tarball:   $TARBALL_ABS"
step "prefix:    $PREFIX"
step "data root: $DATA_DIR"
step "host arch: $HOST_ARCH"

# ------------------------------------------------------------- preflight ----

if (( DO_PREFLIGHT )); then
    info "Preflight"

    LISTING=$(mktemp "${TMPDIR:-/tmp}/rp-deploy-list.XXXXXX")
    trap 'rm -f "$LISTING"' EXIT

    tar -tzvf "$TARBALL_ABS" > "$LISTING" 2>/dev/null \
        || die "cannot read '$TARBALL_BASE' as a gzip tar archive (corrupt or truncated?)"

    ENTRIES=$(wc -l < "$LISTING" | tr -d ' ')
    step "archive is readable, $ENTRIES entries"

    NAMES=$(awk '{print $NF}' "$LISTING")

    # Reject the RPM-repackaged layout, which nests everything under
    # redpanda-<version>/opt/redpanda/ and needs a different rewrite.
    if printf '%s\n' "$NAMES" | grep -qE '^redpanda-[^/]+/opt/redpanda/'; then
        die "'$TARBALL_BASE' is an RPM-repackaged tarball (redpanda-<version>/opt/redpanda/...),
       not an official self-contained one. Its layout and its wrapper paths
       differ; deploy it with redpanda-rpm-to-tarball.sh's documented steps."
    fi

    for required in bin/redpanda libexec/redpanda bin/rpk libexec/rpk conf/redpanda.yaml; do
        printf '%s\n' "$NAMES" | grep -qxF "$required" \
            || die "'$TARBALL_BASE' is missing '$required'; this does not look like an
       official Redpanda self-contained tarball."
    done
    step "layout looks right (bin/, libexec/, lib/, conf/ at the archive root)"

    NEED=$(awk '{s+=$3} END {print s+0}' "$LISTING")
    NEED_MARGIN=$(( NEED + NEED / 20 ))
    step "uncompressed size: $(( NEED / 1024 / 1024 )) MiB"

    SPACE_CHECK_DIR=$PARENT
    while [[ ! -d $SPACE_CHECK_DIR && $SPACE_CHECK_DIR != / ]]; do
        SPACE_CHECK_DIR=$(dirname "$SPACE_CHECK_DIR")
    done
    AVAIL=$(df -P -k "$SPACE_CHECK_DIR" | awk 'NR==2 {print $4 * 1024}')
    if [[ -n $AVAIL ]] && (( AVAIL < NEED_MARGIN )); then
        die "not enough free space on the filesystem holding $SPACE_CHECK_DIR:
       need ~$(( NEED_MARGIN / 1024 / 1024 )) MiB, have $(( AVAIL / 1024 / 1024 )) MiB."
    fi
    step "free space: $(( AVAIL / 1024 / 1024 )) MiB available at $SPACE_CHECK_DIR"

    if [[ -n $SHA256_CMD ]]; then
        SHA256_VALUE=$($SHA256_CMD "$TARBALL_ABS" | awk '{print $1}')
        step "sha256: $SHA256_VALUE"
    else
        SHA256_VALUE="(no sha256 tool available)"
        warn "neither sha256sum nor shasum found; skipping checksum"
    fi

    rm -f "$LISTING"
    trap - EXIT
else
    SHA256_VALUE="(preflight skipped)"
fi

# --------------------------------------------------------------- extract ----

info "Preparing $PREFIX"

if [[ -e $PREFIX ]]; then
    if (( FORCE )); then
        [[ -d $PREFIX ]] || die "$PREFIX exists and is not a directory; refusing to --force"
        step "removing existing $PREFIX (--force)"
        run rm -rf -- "$PREFIX"
    else
        die "$PREFIX already exists. Use --force to replace it, or pick another --prefix."
    fi
fi

if (( ! DRY_RUN )); then
    mkdir -p -- "$PARENT" 2>/dev/null \
        || die "cannot create $PARENT (permission denied?). Re-run with sudo or pick a
       writable --prefix / --versions-root."
    [[ -w $PARENT ]] || die "$PARENT is not writable. Re-run with sudo or pick a writable prefix."
else
    step "[dry-run] mkdir -p $PARENT"
fi

run mkdir -p -- "$PREFIX"

info "Extracting"
step "this unpacks a few GiB and takes a moment"
run tar -xzf "$TARBALL_ABS" -C "$PREFIX"

if (( ! DRY_RUN )); then
    [[ -f $PREFIX/bin/redpanda && -f $PREFIX/libexec/redpanda ]] \
        || die "extraction did not produce $PREFIX/bin/redpanda and $PREFIX/libexec/redpanda"
    step "extracted into $PREFIX"
fi

# ------------------------------------------------ rewrite bin/* wrappers ----

info "Rewriting the bin/* wrappers to $PREFIX"

# The wrappers reference /opt/redpanda/... in three ways, and two of them do
# NOT map onto the shipped layout by a plain prefix substitution:
#
#   /opt/redpanda/rpk-fips/openssl/  -> shipped at openssl/
#   /opt/redpanda/rpk-fips/lib/...   -> shipped at lib/rpk-fips/ and lib/ossl-modules/
#   /opt/redpanda/<rest>             -> shipped at <rest>
#
# The specific rules must therefore run before the general one. Every pattern
# is anchored on the opening double quote, so each rule matches only a quoted
# absolute path, and a rewritten file no longer matches any of them (the text
# then reads "<prefix>/..., never "/opt/redpanda/...). Re-running is a no-op.

if (( DRY_RUN )); then
    step "[dry-run] sed -i (4 rules) over $PREFIX/bin/*"
else
    WRAPPERS=()
    for f in "$PREFIX"/bin/*; do
        [[ -f $f ]] || continue
        # Only touch text files; never rewrite a binary in place.
        if grep -Iq . "$f" 2>/dev/null; then
            WRAPPERS+=("$f")
        else
            warn "skipping non-text file $f"
        fi
    done
    (( ${#WRAPPERS[@]} )) || die "no wrapper scripts found in $PREFIX/bin"

    sed -i \
        -e "s|\"/opt/redpanda/rpk-fips/openssl/|\"$PREFIX/openssl/|g" \
        -e "s|\"/opt/redpanda/rpk-fips/lib/ossl-modules/|\"$PREFIX/lib/ossl-modules/|g" \
        -e "s|\"/opt/redpanda/rpk-fips/lib\"|\"$PREFIX/lib/rpk-fips\"|g" \
        -e "s|\"/opt/redpanda/|\"$PREFIX/|g" \
        "${WRAPPERS[@]}"

    step "rewrote ${#WRAPPERS[@]} wrappers"

    # Hard assertion: nothing may still point at the stock install.
    if LEFTOVER=$(grep -l '"/opt/redpanda/' "${WRAPPERS[@]}" 2>/dev/null); then
        die "these wrappers still reference /opt/redpanda after the rewrite:
$(printf '       %s\n' $LEFTOVER)"
    fi

    # ---- route every dynamic binary through its own bundled loader ------
    #
    # The libexec binaries hardcode their ELF interpreter as
    # /opt/redpanda/lib/ld.so (and /opt/redpanda/rpk-fips/lib/ld.so for the
    # two FIPS binaries). That path lives in the ELF program header, not in
    # the wrapper, so no amount of sed can fix it. Consequences if it is left
    # alone: on a host with no stock install every dynamic binary dies with
    # "cannot execute: required file not found", and on a host that has one
    # they silently run under THAT install's loader.
    #
    # The fix is to invoke the bundled loader explicitly. Each wrapper
    # already names the directory holding its own ld.so in LD_LIBRARY_PATH,
    # and exactly those wrappers that set LD_LIBRARY_PATH are the ones whose
    # binary is dynamic -- rpk is statically linked and sets none.

    ARGV0_OK=0
    if [[ -x $PREFIX/lib/ld.so ]] && "$PREFIX/lib/ld.so" --help 2>&1 | grep -q -- '--argv0'; then
        ARGV0_OK=1
    else
        warn "the bundled loader has no --argv0; programs will see their libexec path as argv[0]"
    fi

    SHIMMED=0
    STATIC=0
    for f in "${WRAPPERS[@]}"; do
        target=$(sed -n 's|^exec \(-a "$0" \)\?"\([^"]*\)".*|\2|p' "$f" | head -1)
        [[ -n $target ]] || die "$f: no exec target found"
        [[ $target == "$PREFIX"/* ]] || die "$f: exec target outside prefix: $target"
        [[ -f $target ]] || die "$f: exec target does not exist: $target"

        libdir=$(sed -n 's|^export LD_LIBRARY_PATH="\([^"]*\)".*|\1|p' "$f" | head -1)
        if [[ -z $libdir ]]; then
            STATIC=$(( STATIC + 1 ))          # static binary, no loader needed
            continue
        fi
        [[ $libdir == "$PREFIX"/* ]] || die "$f: LD_LIBRARY_PATH outside prefix: $libdir"

        loader=$libdir/ld.so
        [[ -x $loader ]] || die "$f: expected a bundled loader at $loader but found none.
       Cannot make this tree self-contained; deploy would depend on
       /opt/redpanda existing."

        tmp=$f.deploy-tmp
        {
            grep -v '^exec ' "$f"
            if (( ARGV0_OK )); then
                printf 'exec "%s" --argv0 "$0" --library-path "%s" "%s" "$@"\n' \
                    "$loader" "$libdir" "$target"
            else
                printf 'exec -a "$0" "%s" --library-path "%s" "%s" "$@"\n' \
                    "$loader" "$libdir" "$target"
            fi
        } > "$tmp"
        chmod --reference="$f" "$tmp" 2>/dev/null || chmod 755 "$tmp"
        mv -- "$tmp" "$f"
        SHIMMED=$(( SHIMMED + 1 ))
    done

    step "$SHIMMED wrappers now call the bundled loader; $STATIC static binary left as-is"
    step "every exec target and loader resolves inside $PREFIX and exists"
fi

# ------------------------------------------------- per-version config ----

info "Writing a per-version configuration"

CONFIG=$PREFIX/etc/redpanda/redpanda.yaml

if (( DRY_RUN )); then
    step "[dry-run] write $CONFIG with data_directory $DATA_DIR/data"
else
    mkdir -p -- "$PREFIX/etc/redpanda"
    if [[ -f $PREFIX/conf/redpanda.yaml ]]; then
        cp -- "$PREFIX/conf/redpanda.yaml" "$CONFIG"
    else
        die "$PREFIX/conf/redpanda.yaml is missing; cannot build a per-version config"
    fi

    # Point the data and coredump directories at this version's own tree, so
    # two versions never share state.
    sed -i \
        -e "s|^\( *data_directory: *\)\".*\"|\1\"$DATA_DIR/data\"|" \
        -e "s|^\( *coredump_dir: *\)\".*\"|\1\"$DATA_DIR/coredump\"|" \
        "$CONFIG"

    grep -q "\"$DATA_DIR/data\"" "$CONFIG" \
        || die "failed to rewrite data_directory in $CONFIG"

    mkdir -p -- "$DATA_DIR/data" "$DATA_DIR/coredump"
    step "config:    $CONFIG"
    step "data dirs: $DATA_DIR/{data,coredump}"
fi

# ------------------------------------------- relocate openssl config ----

# openssl/*.cnf carry unquoted absolute .include paths
# (/opt/redpanda/openssl/... and /opt/redpanda/rpk-fips/openssl/...), both of
# which point at the single fipsmodule.cnf this tarball ships at openssl/.
# They are configuration, not wrappers, so the bin/* pass above never sees
# them -- but the FIPS binaries read them at startup.

info "Relocating the OpenSSL configuration"

if (( DRY_RUN )); then
    step "[dry-run] sed -i over $PREFIX/openssl/*.cnf"
elif compgen -G "$PREFIX/openssl/*.cnf" >/dev/null; then
    sed -i \
        -e "s|/opt/redpanda/rpk-fips/openssl/|$PREFIX/openssl/|g" \
        -e "s|/opt/redpanda/|$PREFIX/|g" \
        "$PREFIX"/openssl/*.cnf

    if grep -l '/opt/redpanda' "$PREFIX"/openssl/*.cnf >/dev/null 2>&1; then
        die "an openssl .cnf still references /opt/redpanda after the rewrite"
    fi
    step "rewrote the .include paths in $PREFIX/openssl/*.cnf"

    # Upstream's fipsmodule.cnf declares [fips_sect] but omits
    # "activate = 1", so the FIPS provider is never activated and rpk-fips
    # panics with "FIPS mode requested (GOFIPS) but not available". This is
    # true of the tarball as shipped, not a consequence of relocating it.
    FIPSMOD=$PREFIX/openssl/fipsmodule.cnf
    if [[ -f $FIPSMOD ]] && ! grep -qE '^ *activate *= *1' "$FIPSMOD"; then
        if (( ENABLE_FIPS )); then
            sed -i 's|^\[fips_sect\]$|[fips_sect]\nactivate = 1|' "$FIPSMOD"
            grep -qE '^activate = 1' "$FIPSMOD" \
                || die "failed to add 'activate = 1' to $FIPSMOD"
            step "added 'activate = 1' to fipsmodule.cnf (--enable-fips)"
        else
            step "note: fipsmodule.cnf has no 'activate = 1'; rpk-fips will not"
            step "      run. Re-deploy with --enable-fips if you need it."
        fi
    fi
else
    step "no openssl/*.cnf in this tarball; nothing to relocate"
fi

# --------------------------------------------------- activate + receipt ----

if (( DRY_RUN )); then
    step "[dry-run] write $PREFIX/activate.sh and $PREFIX/.deploy-info"
else
    cat > "$PREFIX/activate.sh" <<EOF
# Source this to put Redpanda $VERSION first on PATH:
#     . "$PREFIX/activate.sh"
PATH="$PREFIX/bin:\$PATH"
export PATH
REDPANDA_CONFIG="$CONFIG"
export REDPANDA_CONFIG
EOF

    cat > "$PREFIX/.deploy-info" <<EOF
version:      $VERSION
prefix:       $PREFIX
data_root:    $DATA_DIR
config:       $CONFIG
source:       $TARBALL_ABS
source_sha256: $SHA256_VALUE
arch:         ${FILE_ARCH:-unknown}
host_arch:    $HOST_ARCH
deployed_at:  $(date -u +%Y-%m-%dT%H:%M:%SZ)
deployed_by:  $PROGNAME
EOF
    step "receipt:  $PREFIX/.deploy-info"
fi

# ---------------------------------------------------------------- verify ----

if (( DO_VERIFY )) && (( ! DRY_RUN )); then
    info "Verifying"

    RPK_OUT=$("$PREFIX/bin/rpk" version 2>&1) || die "rpk failed to run:
$RPK_OUT"
    step "rpk:      $(printf '%s' "$RPK_OUT" | head -1)"

    RP_OUT=$("$PREFIX/bin/redpanda" --version 2>&1) || die "redpanda failed to run:
$RP_OUT"
    step "redpanda: $(printf '%s' "$RP_OUT" | head -1)"

    if ! printf '%s %s' "$RPK_OUT" "$RP_OUT" | grep -qF "$VERSION"; then
        warn "neither rpk nor redpanda reported version '$VERSION'; check the output above"
    else
        step "both report $VERSION"
    fi

    # The FIPS pair is the pair most likely to break: it has its own loader,
    # its own lib directory and its own openssl config, and upstream ships
    # all three at paths the stock wrappers do not point at.
    if [[ -x $PREFIX/bin/rpk-fips ]]; then
        if FIPS_OUT=$("$PREFIX/bin/rpk-fips" --version 2>&1); then
            step "rpk-fips: $(printf '%s' "$FIPS_OUT" | head -1)"
        else
            if printf '%s' "$FIPS_OUT" | grep -q 'FIPS mode requested'; then
                warn "rpk-fips cannot enter FIPS mode: upstream's fipsmodule.cnf omits
         'activate = 1', so the FIPS provider never activates. Re-deploy
         with --enable-fips to add that line. Harmless if you do not use
         FIPS -- plain rpk is unaffected."
            else
                warn "rpk-fips failed to run (non-fatal unless you need FIPS mode):
$(printf '%s' "$FIPS_OUT" | head -3)"
            fi
        fi
    fi

    # A version string alone cannot prove the tree is self-contained: a stock
    # install of the same version would print exactly the same thing. Assert
    # instead that no wrapper still names /opt/redpanda, so nothing outside
    # the prefix can be reached.
    if grep -rq '/opt/redpanda' "$PREFIX/bin" 2>/dev/null; then
        die "a wrapper in $PREFIX/bin still references /opt/redpanda"
    fi
    step "no wrapper references /opt/redpanda; the tree is self-contained"
elif (( DO_VERIFY )); then
    step "[dry-run] would run rpk version, redpanda --version and rpk-fips --version"
fi

# --------------------------------------------------------------- summary ----

cat <<EOF

==> Deployed Redpanda $VERSION to $PREFIX

    Run this version:
      "$PREFIX/bin/rpk" version
      "$PREFIX/bin/redpanda" --version

    Or put it first on PATH:
      . "$PREFIX/activate.sh"

    Start a broker with this version's own config (always pass --config;
    the default path is compiled in as /etc/redpanda/redpanda.yaml):
      "$PREFIX/bin/redpanda" --redpanda-cfg "$CONFIG"

    The bin/* wrappers were rewritten twice: the hardcoded /opt/redpanda
    paths were repointed at this prefix, and each dynamic binary now runs
    under this tree's own bundled loader, because the ELF interpreter path
    baked into the binaries also said /opt/redpanda.

    NOT done by this script: redpanda user/group, file capabilities on the
    binary, systemd units, and rpk tuners. Review the config's ports before
    starting a second version on the same host -- two brokers cannot share
    9092, 9644, 33145, 8081 or 8082.
EOF
