#!/bin/sh
# Tether CLI installer (POSIX sh) — #635.
#
# Detects OS + arch, resolves the latest release, downloads the matching
# tarball + its SHA256SUMS, VERIFIES the checksum (fail-closed), installs the
# `tether` binary into a writable bin dir, ensures that dir is on PATH
# idempotently, and finally hands off to `tether onboard` (sign in → workspace →
# bootstrap) unless --no-login / TETHER_NO_ONBOARD / CI / no attached terminal.
#
# Canonical install (once #643 provisions the host):
#   curl -fsSL https://get.tether.sh | sh
# Until then, install via the GitHub-hosted raw URL of this script.
# TODO(#634): canonical host get.tether.sh not provisioned; install via the
#             GitHub-hosted script URL for now.
#
# SECURITY (this is a pipe-to-shell installer — treat as security-critical):
#   * The checksum is verified BEFORE the binary is installed or run, and any
#     mismatch / missing checksum line aborts (fail closed). There is no
#     --skip-checksum escape hatch.
#   * Nothing downloaded is ever `eval`'d or `source`'d — fetched bytes only
#     ever land in files.
#   * Every variable expansion is quoted; the resolved download host is fixed to
#     the ${GITHUB}/${TETHER_REPO} constant and the version is shape-validated
#     before it is interpolated into any URL.
#   * PATH edits are idempotent (sentinel-guarded) and scoped to the user's rc.
#
# POSIX sh: no bashisms, no `pipefail`, no `local` outside functions, no arrays.

set -eu

# ── Constants ───────────────────────────────────────────────────────────────

# TODO(#634): confirm canonical owner/repo slug before the public launch.
TETHER_REPO="${TETHER_REPO:-tetherlab/install}"
GITHUB="https://github.com"

# Indirection so the test harness can mock all network reads. This is a TEST
# SEAM ONLY: it is honored exclusively when the script is sourced by the harness
# (TETHER_INSTALL_SOURCED=1). In a normal `curl … | sh` run it is inert, so a
# stray TETHER_DOWNLOAD_CMD already in the user's environment can NOT redirect
# the security-critical download path to an arbitrary command. Read live (not
# cached at source time) so a test can export TETHER_DOWNLOAD_CMD after sourcing
# and have every fetch honor it.
download_cmd() {
    case "${TETHER_INSTALL_SOURCED:-}" in
        1) printf '%s' "${TETHER_DOWNLOAD_CMD:-}" ;;
        *) printf '' ;;
    esac
}

# ── Output helpers ──────────────────────────────────────────────────────────

info() { printf '%s\n' "tether-install: $*" >&2; }
err() { printf '%s\n' "tether-install: error: $*" >&2; }
die() {
    err "$*"
    exit 1
}

# ── OS / arch detection (injectable via TETHER_UNAME_S / TETHER_UNAME_M) ─────

# Echo "macos" | "linux"; die on anything else.
detect_os() {
    uname_s="${TETHER_UNAME_S:-$(uname -s)}"
    case "$uname_s" in
        Darwin) echo "macos" ;;
        Linux) echo "linux" ;;
        *) die "unsupported OS: ${uname_s} (tether ships macOS and Linux builds)" ;;
    esac
}

# Echo a normalized arch: "x86_64" | "arm64"; die on anything else.
detect_arch() {
    uname_m="${TETHER_UNAME_M:-$(uname -m)}"
    case "$uname_m" in
        x86_64 | amd64) echo "x86_64" ;;
        arm64 | aarch64) echo "arm64" ;;
        *) die "unsupported architecture: ${uname_m} (tether ships x86_64 and arm64 builds)" ;;
    esac
}

# The Rust target triple for a Linux os/arch (macOS uses a universal build, so
# it has no per-arch triple). Echoes the triple; die on a non-linux os.
target_triple() {
    _os="$1"
    _arch="$2"
    case "$_os" in
        linux)
            case "$_arch" in
                x86_64) echo "x86_64-unknown-linux-gnu" ;;
                arm64) echo "aarch64-unknown-linux-gnu" ;;
                *) die "no linux triple for arch ${_arch}" ;;
            esac
            ;;
        *) die "target_triple is linux-only (got ${_os})" ;;
    esac
}

# The release artifact filename for os/arch/version. Mirrors release.yml exactly:
#   linux  → tether-${v}-${triple}.tar.gz       (one `tether` binary at root)
#   macos  → tether-${v}-universal-macos.tar.gz  (BOTH arches → one universal)
artifact_name() {
    _os="$1"
    _arch="$2"
    _version="$3"
    case "$_os" in
        macos)
            # macOS ships a single universal binary; both arches map to it.
            echo "tether-${_version}-universal-macos.tar.gz"
            ;;
        linux)
            _triple="$(target_triple "$_os" "$_arch")"
            echo "tether-${_version}-${_triple}.tar.gz"
            ;;
        *) die "no artifact for os ${_os}" ;;
    esac
}

# ── URL construction (host-pinned) ──────────────────────────────────────────

# Reject a TETHER_REPO slug that isn't a plain `owner/repo`. The host is pinned
# to the ${GITHUB} constant, but an unvalidated slug (e.g. `a/b/../../c`) could
# still path-traverse within github.com, so shape-check it before it reaches any
# URL.
validate_repo() {
    case "$1" in
        */*/*) die "TETHER_REPO must be a plain owner/repo slug, got: $1" ;;
        */*)
            case "$1" in
                # No `.` segment, traversal, whitespace, or other URL-escaping chars.
                *[!A-Za-z0-9._/-]* | *..* | */ | /*)
                    die "TETHER_REPO contains illegal characters: $1"
                    ;;
                *) : ;;
            esac
            ;;
        *) die "TETHER_REPO must be a plain owner/repo slug, got: $1" ;;
    esac
}

# Reject a version that isn't a plain semver (optionally with a -pre / +build
# suffix). This keeps a poisoned "latest" redirect from injecting an arbitrary
# host/path into the URLs below.
validate_version() {
    case "$1" in
        # digits.digits.digits with an optional [-+]suffix.
        [0-9]*.[0-9]*.[0-9]*) : ;;
        *) die "refusing to use a malformed version string: $1" ;;
    esac
    # Reject any character that could escape the URL (slashes, spaces, etc.).
    case "$1" in
        *[!0-9A-Za-z.+-]*) die "version contains illegal characters: $1" ;;
        *) : ;;
    esac
}

download_url() {
    _version="$1"
    _artifact="$2"
    echo "${GITHUB}/${TETHER_REPO}/releases/download/v${_version}/${_artifact}"
}

checksums_url() {
    _version="$1"
    echo "${GITHUB}/${TETHER_REPO}/releases/download/v${_version}/SHA256SUMS"
}

# Parse the bare version out of a /releases/tag/vX.Y.Z URL. Pure — factored out
# of the network call below so the harness can test it directly. FAILS CLOSED:
# a URL with no `/tag/v` segment echoes nothing (empty) rather than the whole
# input, so a redirect that didn't land on a tag page can't launder its target
# through validate_version.
parse_version_from_tag_url() {
    case "$1" in
        */tag/v*)
            # Strip everything up to and including the LAST ".../tag/v"; what
            # remains is the version (possibly with a trailing slash, dropped).
            _tail="${1##*/tag/v}"
            _tail="${_tail%/}"
            echo "$_tail"
            ;;
        *)
            # No tag segment — echo nothing so the caller fails closed.
            echo ""
            ;;
    esac
}

# ── Networking (single injectable seam) ─────────────────────────────────────

# Fetch a URL to stdout. All network reads route through here so the test
# harness can override the whole thing by exporting TETHER_DOWNLOAD_CMD (or
# redefining fetch()).
fetch() {
    _dl="$(download_cmd)"
    if [ -n "$_dl" ]; then
        # shellcheck disable=SC2086 # intentional word-split of the configured cmd
        $_dl "$1"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$1"
    else
        die "neither curl nor wget found — install curl and re-run"
    fi
}

# Fetch a URL to a file (preserving the non-2xx → failure contract). Downloads
# to a `.part` sibling and renames into place only on success, so a mid-transfer
# failure (which `curl -f -o` cleans up but `wget`/the injected cmd would leave
# truncated) never leaves a partial file that later reads as a checksum mismatch.
fetch_to_file() {
    _url="$1"
    _dest="$2"
    _part="${_dest}.part"
    rm -f "$_part"
    _dl="$(download_cmd)"
    if [ -n "$_dl" ]; then
        # shellcheck disable=SC2086 # intentional word-split of the test-seam cmd
        $_dl "$_url" >"$_part" || {
            rm -f "$_part"
            return 1
        }
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL "$_url" -o "$_part" || {
            rm -f "$_part"
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$_part" "$_url" || {
            rm -f "$_part"
            return 1
        }
    else
        die "neither curl nor wget found — install curl and re-run"
    fi
    mv "$_part" "$_dest" || {
        rm -f "$_part"
        return 1
    }
}

# Resolve the latest published version by following the /releases/latest
# redirect to its /tag/vX.Y.Z target and parsing the version out.
# TODO(#634): no version manifest endpoint; resolving latest via the
#             releases/latest redirect.
resolve_latest_version() {
    _redirect_url="${GITHUB}/${TETHER_REPO}/releases/latest"
    if [ -n "$(download_cmd)" ]; then
        # In tests, TETHER_LATEST_TAG_URL stands in for the effective URL curl
        # would resolve, so the parse path is exercised without a network.
        _effective="${TETHER_LATEST_TAG_URL:-$_redirect_url}"
    elif command -v curl >/dev/null 2>&1; then
        _effective="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$_redirect_url")"
    else
        die "resolving the latest version needs curl — pass --version <X.Y.Z> instead"
    fi
    # Defense in depth: the version is rebuilt from the pinned ${GITHUB}/
    # ${TETHER_REPO} constants regardless, but assert the redirect actually
    # landed on our own releases path before trusting anything parsed off it, so
    # a hijacked redirect can never even reach the version parser.
    _expected_prefix="${GITHUB}/${TETHER_REPO}/releases/"
    case "$_effective" in
        "${_expected_prefix}"*) : ;;
        *) die "latest-release redirect went somewhere unexpected (${_effective}) — refusing it; pass --version <X.Y.Z>" ;;
    esac
    parse_version_from_tag_url "$_effective"
}

# ── Checksum verification (fail-closed) ─────────────────────────────────────

# Compute the SHA-256 of a file, echoing the bare hex digest. Tries the three
# common tools in order; dies if none is present (a checksum we can't compute
# is a checksum we can't verify, so we never silently proceed).
compute_sha256() {
    _file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$_file" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$_file" | cut -d' ' -f1
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$_file" | sed 's/.*= *//'
    else
        die "no SHA-256 tool found (need sha256sum, shasum, or openssl) — cannot verify download"
    fi
}

# Lowercase a hex string (portable; the SHA tools differ in output case).
lower_hex() { printf '%s' "$1" | tr 'A-F' 'a-f'; }

# Verify $file's SHA-256 against the line for $artifact in $sums_file.
# Returns 0 on a match; returns non-zero (fails closed) on a mismatch, a
# missing line, OR a malformed hash field. NEVER installs on failure — the
# caller aborts.
verify_checksum() {
    _file="$1"
    _artifact="$2"
    _sums_file="$3"

    # The SHA256SUMS file must exist and be readable before we trust anything
    # parsed from it. main() already fails closed if the download 404s, but
    # guard here too (defense in depth) so a missing/unreadable sums file is a
    # clean "fail closed" message rather than a raw awk file-open error that
    # `set -e` would propagate as an opaque non-zero — and so the function is
    # safely callable on its own (e.g. the test harness).
    if [ ! -r "$_sums_file" ]; then
        err "SHA256SUMS not found or unreadable (${_sums_file}) — cannot verify, refusing to install (fail closed)"
        return 1
    fi

    # Pull the expected hash from the SHA256SUMS line for this artifact. The
    # standard format is "<hex>  <filename>" or "<hex> *<filename>" (binary
    # marker). Anchor the filename to an EXACT field-2 match (with or without the
    # leading `*`) so a line for a different file can't be mistaken for ours.
    _expected="$(awk -v f="$_artifact" '$2 == f || $2 == "*" f {print $1; exit}' "$_sums_file")"
    if [ -z "$_expected" ]; then
        err "no checksum line for ${_artifact} in SHA256SUMS — refusing to install (fail closed)"
        return 1
    fi

    # The hash field must be exactly 64 hex chars; anything else is a corrupt /
    # crafted SHA256SUMS and we refuse it rather than compare garbage.
    case "$_expected" in
        *[!0-9A-Fa-f]* | "")
            err "malformed checksum for ${_artifact} in SHA256SUMS — refusing to install (fail closed)"
            return 1
            ;;
        *)
            if [ "${#_expected}" -ne 64 ]; then
                err "checksum for ${_artifact} is not a 64-char SHA-256 — refusing to install (fail closed)"
                return 1
            fi
            ;;
    esac

    _actual="$(compute_sha256 "$_file")"
    # Compare case-insensitively — sha256sum / shasum / openssl can differ in
    # output case across platforms.
    _exp_l="$(lower_hex "$_expected")"
    _act_l="$(lower_hex "$_actual")"
    if [ "$_exp_l" != "$_act_l" ]; then
        err "checksum mismatch for ${_artifact}"
        err "  expected: ${_expected}"
        err "  actual:   ${_actual}"
        err "refusing to install a tampered or corrupt download (fail closed)"
        return 1
    fi
    return 0
}

# ── Install ─────────────────────────────────────────────────────────────────

# Refuse to install into a destination that has been symlink-swapped from under
# us. Checks the dir itself and the final `tether` target: a symlink at either
# means `mv`/`chmod` would write through the link to an attacker-chosen path.
# Also rejects a destination dir that exists but isn't owned by us (a shared /
# world-writable TETHER_INSTALL_DIR is unsafe to install a binary into).
#
# Portable "is $1 owned by the current user?" — POSIX `find -user` (the `[ -O ]`
# test is not in POSIX sh). Returns 0 when the path exists and is owned by us.
owned_by_me() {
    _p="$1"
    [ -e "$_p" ] || return 1
    _me="$(id -un 2>/dev/null || true)"
    [ -n "$_me" ] || return 0 # can't determine the user — don't block on it
    [ -n "$(find "$_p" -maxdepth 0 -user "$_me" 2>/dev/null)" ]
}

assert_safe_install_dir() {
    _dest_dir="$1"
    # A symlinked install dir could redirect the whole install elsewhere.
    if [ -L "$_dest_dir" ]; then
        die "${_dest_dir} is a symlink — refusing to install through it (set TETHER_INSTALL_DIR to a real, user-private dir)"
    fi
    # A symlink at the final binary path would let `mv`/`chmod` write through it.
    if [ -L "$_dest_dir/tether" ]; then
        die "${_dest_dir}/tether is a symlink — refusing to overwrite through it"
    fi
    # A pre-existing dir owned by someone else is not ours to write into.
    if [ -d "$_dest_dir" ] && ! owned_by_me "$_dest_dir"; then
        die "${_dest_dir} is not owned by the current user — refusing to install into it"
    fi
}

# Extract the `tether` binary from $tarball into $dest_dir/tether (mode 755).
# $work is the caller's already-trapped temp workspace (main's $_work) — we
# extract into a subdir of it so the single EXIT trap in main owns ALL cleanup
# and this function never touches the trap (avoids clobbering main's cleanup).
install_binary() {
    _tarball="$1"
    _dest_dir="$2"
    _work="$3"

    # Create the dir with a tight umask so a freshly-made install dir is not
    # group/world-writable. (Restore the umask afterwards.)
    _old_umask="$(umask)"
    umask 077
    mkdir -p "$_dest_dir" || {
        umask "$_old_umask"
        die "cannot create install dir ${_dest_dir}"
    }
    umask "$_old_umask"

    # Re-validate AFTER mkdir, immediately before we write, to close the
    # check-then-write window as far as a POSIX script can.
    assert_safe_install_dir "$_dest_dir"

    _tmp="${_work}/extract"
    mkdir -p "$_tmp" || die "cannot create a temp dir for extraction"

    tar xzf "$_tarball" -C "$_tmp" || die "failed to extract ${_tarball}"
    if [ ! -f "$_tmp/tether" ] || [ -L "$_tmp/tether" ]; then
        die "archive did not contain a regular 'tether' binary at its root"
    fi
    # Final guard right before the write — the binary target must not be a
    # symlink (re-checked here in case it appeared during extraction).
    if [ -L "$_dest_dir/tether" ]; then
        die "${_dest_dir}/tether is a symlink — refusing to overwrite through it"
    fi
    mv "$_tmp/tether" "$_dest_dir/tether" || die "failed to install into ${_dest_dir}"
    chmod 755 "$_dest_dir/tether" || die "failed to chmod the installed binary"
    # No trap to clear — main's EXIT trap removes $_work (and our subdir with it).
}

# Resolve the install dir: TETHER_INSTALL_DIR wins; else ~/.tether/bin (always
# user-writable, no sudo, upgrade-in-place safe). A request for a system dir
# that isn't writable produces a clear error rather than a half-install.
resolve_install_dir() {
    if [ -n "${TETHER_INSTALL_DIR:-}" ]; then
        echo "$TETHER_INSTALL_DIR"
        return 0
    fi
    echo "${HOME}/.tether/bin"
}

# ── PATH management (idempotent, user-scoped) ───────────────────────────────

# The managed sentinel block written into the user's rc. Re-runs detect it and
# skip, so there is never a duplicate entry.
SENTINEL_OPEN="# >>> tether installer (managed) >>>"
SENTINEL_CLOSE="# <<< tether installer (managed) <<<"

# Pure: is $dir already a segment of the PATH value $path_value? (0 = yes.)
path_already_present() {
    _dir="$1"
    _path_value="$2"
    case ":${_path_value}:" in
        *":${_dir}:"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Pure: does $rcfile already contain the managed sentinel? (0 = yes.)
rc_has_sentinel() {
    _rcfile="$1"
    [ -f "$_rcfile" ] && grep -qF "$SENTINEL_OPEN" "$_rcfile"
}

# Pick the rc file to edit from the login shell basename.
rc_file_for_shell() {
    _shell_base="$(basename "${SHELL:-/bin/sh}")"
    case "$_shell_base" in
        zsh) echo "${HOME}/.zshrc" ;;
        bash) echo "${HOME}/.bashrc" ;;
        *) echo "${HOME}/.profile" ;;
    esac
}

# Ensure $dir is on PATH idempotently. If it's already on the live PATH, do
# nothing. Otherwise append a sentinel-guarded export to the rc — but only when
# that block isn't already there, so re-runs never duplicate it.
ensure_on_path() {
    _dir="$1"
    if path_already_present "$_dir" "${PATH:-}"; then
        info "${_dir} is already on PATH"
        return 0
    fi
    _rc="$(rc_file_for_shell)"
    # Refuse to write through a symlinked rc (a planted ~/.zshrc → someone
    # else's file would redirect the managed PATH line, or worse, let an attacker
    # control content the user's next shell sources). It must be a regular file
    # we own, or absent (we then create it).
    if [ -L "$_rc" ]; then
        info "rc file ${_rc} is a symlink — not editing it. Add ${_dir} to PATH yourself."
        return 0
    fi
    if [ -e "$_rc" ] && { [ ! -f "$_rc" ] || ! owned_by_me "$_rc"; }; then
        info "rc file ${_rc} is not a regular file you own — not editing it. Add ${_dir} to PATH yourself."
        return 0
    fi
    if rc_has_sentinel "$_rc"; then
        info "PATH entry already managed in ${_rc} (no change)"
        return 0
    fi
    {
        printf '%s\n' "$SENTINEL_OPEN"
        # The literal $PATH must reach the rc file verbatim — it expands at the
        # user's shell startup, not at install time. SC2016 is the point here.
        # shellcheck disable=SC2016
        printf 'export PATH="%s:$PATH"\n' "$_dir"
        printf '%s\n' "$SENTINEL_CLOSE"
    } >>"$_rc"
    info "added ${_dir} to PATH in ${_rc}"
    info "open a new shell (or run: export PATH=\"${_dir}:\$PATH\") to pick it up now"
}

# ── Usage ───────────────────────────────────────────────────────────────────

usage() {
    cat >&2 <<'EOF'
Usage: install.sh [options]

Options:
  --version X        Install version X instead of the latest release.
  --no-modify-path   Do not edit your shell rc to add the install dir to PATH.
  --no-login         Do not sign in / onboard at the end.
  -h, --help         Show this help.

Environment:
  TETHER_INSTALL_DIR   Install dir (default: ~/.tether/bin).
  TETHER_REPO          GitHub owner/repo slug (default: tetherlab/install).
  TETHER_NO_ONBOARD    Set to skip the post-install sign-in and workspace setup.
EOF
}

# ── main ────────────────────────────────────────────────────────────────────

main() {
    _version=""
    _modify_path=1
    _do_login=1

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version)
                [ "$#" -ge 2 ] || die "--version needs an argument"
                _version="$2"
                shift 2
                ;;
            --version=*)
                _version="${1#--version=}"
                shift
                ;;
            --no-modify-path)
                _modify_path=0
                shift
                ;;
            --no-login)
                _do_login=0
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                err "unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done

    # Shape-validate the repo slug before it reaches any URL (it is overridable
    # via TETHER_REPO, so it's untrusted input on the URL path).
    validate_repo "$TETHER_REPO"

    _os="$(detect_os)"
    _arch="$(detect_arch)"
    info "detected ${_os}/${_arch}"

    if [ -z "$_version" ]; then
        info "resolving the latest release ..."
        _version="$(resolve_latest_version)"
        [ -n "$_version" ] || die "could not resolve the latest version — pass --version <X.Y.Z>"
    fi
    validate_version "$_version"
    info "installing tether v${_version}"

    _artifact="$(artifact_name "$_os" "$_arch" "$_version")"
    _art_url="$(download_url "$_version" "$_artifact")"
    _sums_url="$(checksums_url "$_version")"

    _work="$(mktemp -d "${TMPDIR:-/tmp}/tether-install.XXXXXX")" ||
        die "cannot create a temp working dir"
    # Best-effort cleanup of the download workspace on exit.
    trap 'rm -rf "$_work"' EXIT

    _tarball="${_work}/${_artifact}"
    _sums="${_work}/SHA256SUMS"

    info "downloading ${_artifact} ..."
    fetch_to_file "$_art_url" "$_tarball" ||
        die "download failed: ${_art_url} (is v${_version} published for ${_os}/${_arch}?)"

    info "downloading SHA256SUMS ..."
    # TODO(#634): release.yml does not yet publish SHA256SUMS. Until it does,
    # this download 404s and we fail closed by design. Do not add a
    # --skip-checksum escape hatch.
    fetch_to_file "$_sums_url" "$_sums" ||
        die "checksum file missing: ${_sums_url} — cannot verify the download, refusing to install (fail closed; #634)"

    info "verifying checksum ..."
    verify_checksum "$_tarball" "$_artifact" "$_sums" ||
        die "checksum verification failed — aborting before install"

    _dest_dir="$(resolve_install_dir)"
    # Refuse a symlink-swapped or foreign-owned destination before doing anything
    # else with it (`install_binary` re-checks after mkdir to close the window).
    assert_safe_install_dir "$_dest_dir"
    # Fail clearly when the chosen dir isn't writable, suggesting a fix.
    if [ -d "$_dest_dir" ] && [ ! -w "$_dest_dir" ]; then
        die "no write permission for ${_dest_dir} — set TETHER_INSTALL_DIR to a writable path (e.g. ~/.tether/bin) or re-run with sudo"
    fi
    info "installing to ${_dest_dir}/tether ..."
    install_binary "$_tarball" "$_dest_dir" "$_work"
    info "installed tether v${_version}"

    if [ "$_modify_path" -eq 1 ]; then
        ensure_on_path "$_dest_dir"
    else
        info "skipping PATH edit (--no-modify-path); add ${_dest_dir} to PATH yourself"
    fi

    rm -rf "$_work"
    trap - EXIT

    # Final step: hand off to the binary's onboard chain (sign in → choose/create
    # a workspace → init repo → offer bootstrap), unless suppressed, opted out, or
    # non-interactive. Run the JUST-installed binary by absolute path — PATH may
    # not be live in this shell yet, and let ITS existing auto-onboard chain drive
    # the rest (we never reimplement login/onboard/bootstrap here).
    #
    # TTY: under `curl … | sh` the script's own stdin (fd 0) is the curl pipe, not
    # the terminal, so `[ -t 0 ]` is false even in a fully interactive session and
    # the device-login browser prompt could not read the user's input. /dev/tty is
    # the controlling terminal regardless of how fd 0 was redirected; it exists
    # only when one is attached (absent under most CI / detached runs). We gate on
    # it and reopen it as the child's stdin so onboard can interact even pipe-run.
    if [ "$_do_login" -eq 0 ]; then
        info "skipping sign-in (--no-login). Run \`tether login\` to sign in."
    elif [ -n "${TETHER_NO_ONBOARD:-}" ]; then
        info "TETHER_NO_ONBOARD set — skipping sign-in. Run \`tether login\` to sign in."
    elif [ "${CI:-}" = "true" ] || [ "${CI:-}" = "1" ]; then
        info "CI detected — skipping sign-in. Run \`tether login\` to sign in."
    elif [ -e /dev/tty ]; then
        info "signing you in ..."
        # Reopen /dev/tty as the child's stdin so the device-login browser prompt
        # and the onboard workspace/bootstrap prompts can read user input even when
        # THIS script was pipe-executed (curl … | sh wires fd 0 to the pipe). The
        # binary's onboard flow re-checks the TTY and runs login → workspace →
        # bootstrap itself; we only invoke it.
        "$_dest_dir/tether" onboard </dev/tty ||
            info "onboarding did not complete — run \`tether login\` to retry."
    else
        info "no terminal available — skipping sign-in. Run \`tether login\` to sign in."
    fi

    info "done."
}

# Only auto-run main when executed, not when sourced for tests. The harness
# sets TETHER_INSTALL_SOURCED=1 then `. ./install.sh` to get the functions
# without running the installer.
case "${TETHER_INSTALL_SOURCED:-}" in
    1) : ;;       # sourced by the test harness — define functions only
    *) main "$@" ;;
esac
