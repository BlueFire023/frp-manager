#!/usr/bin/env bash
#
# frp-manager.sh – install, update and manage frp (frpc / frps)
# frp: https://github.com/fatedier/frp
#
# Run without arguments for an interactive menu, or see --help for commands.
#
set -euo pipefail

# ------------------------- Settings -------------------------
# Directory containing frpc / frps (configs live in the config/ subdirectory).
# Empty = directory of this script (or /opt/frp if the script lives in a bin dir).
# Can also be set via the FRP_DIR environment variable or --dir.
FRP_DIR="${FRP_DIR:-}"

# Keep the old binary as <name>.bak (required for automatic rollback)
KEEP_BACKUP=true

# Where to fetch the systemd unit files if they are not found locally.
# The script tries <URL>/systemd/<name>.service and <URL>/<name>.service.
SERVICE_SOURCE_URL="https://raw.githubusercontent.com/BlueFire023/frp-manager/main"
# ------------------------------------------------------------

REPO="fatedier/frp"
FORCE=false
ASSUME_YES=false
TARGET_VERSION=""
LATEST=""
NEW_BIN=""

# ---------- Output helpers ----------
if [[ -t 1 ]]; then
    C_B=$'\e[1;34m'; C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_R=$'\e[1;31m'; C_0=$'\e[0m'
else
    C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
log()  { echo "${C_B}[frp]${C_0} $*"; }
ok()   { echo "${C_G}[frp]${C_0} $*"; }
warn() { echo "${C_Y}[frp]${C_0} $*" >&2; }
die()  { echo "${C_R}[frp]${C_0} $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
frp-manager.sh – install, update and manage frp (frpc / frps)

Usage:
  frp-manager.sh                                   Interactive menu
  frp-manager.sh status                            Versions, service state, updates
  frp-manager.sh update         [client|server]    Install or update the binary
  frp-manager.sh install-service client|server     Install and enable the systemd service
  frp-manager.sh remove-service [client|server]    Stop, disable and remove the service

  (client|server can be omitted if only one of them is installed)

Options:
  --version X.Y.Z   Use a specific frp version instead of the latest one
  --force           Reinstall even if the version is already up to date
  --dir PATH        frp directory (default: directory of this script)
  -y, --yes         Answer all questions with yes (non-interactive)
  -h, --help        Show this help

Shortcuts (compatible with frp-update.sh):
  frp-manager.sh client|server       = update client|server
  frp-manager.sh --check             = status
EOF
}

# ---------- Interaction helpers ----------
has_tty() { { : </dev/tty; } 2>/dev/null; }

# ask "Question?" [y|n]  -> returns 0 for yes
ask() {
    local def="${2:-y}" hint ans
    [[ "$ASSUME_YES" == true ]] && return 0
    if ! has_tty; then [[ "$def" == y ]]; return; fi  # no terminal: use the default
    [[ "$def" == y ]] && hint="[Y/n]" || hint="[y/N]"
    read -r -p "$1 $hint " ans </dev/tty || return 1
    [[ "${ans:-$def}" =~ ^[YyJj] ]]
}

prompt() { local ans; read -r -p "$1" ans </dev/tty; echo "$ans"; }

pick_mode() {
    local ans
    while true; do
        ans="$(prompt "Client or server? [c/s] ")"
        case "$ans" in
            c|C|client) echo client; return ;;
            s|S|server) echo server; return ;;
        esac
    done
}

require_root() { [[ $EUID -eq 0 ]] || die "This action needs root. Run it with sudo."; }

bin_of() {
    case "$1" in
        client) echo frpc ;;
        server) echo frps ;;
        *) die "Mode must be 'client' or 'server'." ;;
    esac
}

# ---------- Version helpers ----------
installed_version() {
    local b; b="$FRP_DIR/$(bin_of "$1")"
    if [[ -x "$b" ]]; then
        "$b" -v 2>/dev/null | tr -d 'v[:space:]' || true
    fi
}

# Sets $LATEST (cached). Follows the /releases/latest redirect, which avoids
# the GitHub API rate limit.
fetch_latest() {
    [[ -n "$LATEST" ]] && return 0
    local url
    url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        "https://github.com/$REPO/releases/latest")" || return 1
    LATEST="${url##*/v}"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo amd64 ;;
        aarch64|arm64)  echo arm64 ;;
        armv7*|armv6*)  echo arm ;;
        i386|i686)      echo 386 ;;
        riscv64)        echo riscv64 ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac
}

service_state() {
    local svc; svc="$(bin_of "$1")"
    if ! command -v systemctl >/dev/null; then echo "no systemd"; return; fi
    if ! systemctl cat "$svc" >/dev/null 2>&1; then echo "not installed"; return; fi
    echo "$(systemctl is-active "$svc" 2>/dev/null || true), $(systemctl is-enabled "$svc" 2>/dev/null || true)"
}

# ---------- Download ----------
# download_release <version> <binary>  -> sets $NEW_BIN
download_release() {
    local ver="$1" bin="$2" arch pkg base dir v
    arch="$(detect_arch)"
    pkg="frp_${ver}_linux_${arch}"
    base="https://github.com/$REPO/releases/download/v${ver}"
    dir="$(mktemp -d -p "$TMP_ROOT")"

    log "Downloading $pkg.tar.gz"
    curl -fL --progress-bar -o "$dir/$pkg.tar.gz" "$base/$pkg.tar.gz" \
        || die "Download failed. Does version $ver exist?"

    if command -v sha256sum >/dev/null \
        && curl -fsSL -o "$dir/sums.txt" "$base/frp_sha256_checksums.txt"; then
        (cd "$dir" && grep " $pkg.tar.gz\$" sums.txt | sha256sum -c --quiet -) \
            || die "Checksum verification failed!"
        log "Checksum OK"
    else
        warn "Checksum could not be verified (sha256sum or checksum file missing)."
    fi

    tar -xzf "$dir/$pkg.tar.gz" -C "$dir" || die "Extraction failed."
    NEW_BIN="$dir/$pkg/$bin"
    [[ -f "$NEW_BIN" ]] || die "$bin not found in the archive."
    chmod +x "$NEW_BIN"

    v="$("$NEW_BIN" -v | tr -d 'v[:space:]')"
    [[ "$v" == "$ver" ]] || die "Downloaded binary reports version '$v' instead of '$ver'."
}

# ---------- Actions ----------
do_update() {
    local mode="$1" bin path cur target was_active=false
    bin="$(bin_of "$mode")"
    path="$FRP_DIR/$bin"
    require_root

    cur="$(installed_version "$mode")"
    if [[ -n "$TARGET_VERSION" ]]; then
        target="$TARGET_VERSION"
    else
        fetch_latest || die "Could not fetch the latest version from GitHub."
        target="$LATEST"
    fi
    [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid version: '$target'"

    log "$bin: ${cur:-not installed} -> $target"
    if [[ "$cur" == "$target" && "$FORCE" == false ]]; then
        ok "$bin is already up to date. (Use --force to reinstall.)"
        return 0
    fi

    download_release "$target" "$bin"
    mkdir -p "$FRP_DIR"

    if command -v systemctl >/dev/null && systemctl is-active --quiet "$bin" 2>/dev/null; then
        was_active=true
        log "Stopping service $bin"
        systemctl stop "$bin"
    fi

    if [[ -f "$path" && "$KEEP_BACKUP" == true ]]; then
        cp -p "$path" "$path.bak"
        log "Backup: $path.bak"
    fi

    # Replace atomically: copy next to the target first, then rename
    install -m 0755 -o root -g root "$NEW_BIN" "$path.new"
    mv -f "$path.new" "$path"
    ok "$bin installed: ${cur:-none} -> $target"

    if [[ "$was_active" == true ]]; then
        log "Starting service $bin"
        systemctl start "$bin"
        sleep 3
        if ! systemctl is-active --quiet "$bin"; then
            warn "Service fails to start with the new version!"
            if [[ -f "$path.bak" ]]; then
                warn "Rolling back to the previous version …"
                mv -f "$path.bak" "$path"
                systemctl start "$bin" || true
            fi
            die "Update failed. Logs: journalctl -u $bin -n 50"
        fi
        ok "Service $bin is running."
    elif [[ "$(service_state "$mode")" == "not installed" ]] && [[ "$ASSUME_YES" == false ]] && has_tty; then
        if ask "No systemd service for $bin yet. Install it now?" n; then
            do_install_service "$mode"
        fi
    fi
}

# find_service_file <binary>  -> prints the path of a unit file
find_service_file() {
    local bin="$1" f url
    for f in "$SELF_DIR/systemd/$bin.service" \
             "$SELF_DIR/$bin.service" \
             "/usr/share/frp-manager/systemd/$bin.service"; do
        if [[ -f "$f" ]]; then echo "$f"; return 0; fi
    done
    f="$(mktemp -p "$TMP_ROOT")"
    for url in "$SERVICE_SOURCE_URL/systemd/$bin.service" "$SERVICE_SOURCE_URL/$bin.service"; do
        if curl -fsSL -o "$f" "$url" 2>/dev/null; then echo "$f"; return 0; fi
    done
    return 1
}

# ---------- Config helpers ----------
# Prints the store path from a frp TOML config (store.path = … or [store] path = …)
get_store_path() {
    awk '
        /^[ \t]*\[/ { s = $0; gsub(/[][ \t]/, "", s); next }
        (s == "" && /^[ \t]*store\.path[ \t]*=/) || (s == "store" && /^[ \t]*path[ \t]*=/) {
            v = $0; sub(/^[^=]*=[ \t]*/, "", v); print v; exit
        }
    ' "$1" | sed -e 's/[ \t]*#.*$//' -e "s/^[\"']//" -e "s/[\"'][ \t]*\$//"
}

# set_store_path <config> <new path>  – rewrites the store path in place
set_store_path() {
    local tmp; tmp="$(mktemp -p "$TMP_ROOT")"
    awk -v new="$2" '
        /^[ \t]*\[/ { s = $0; gsub(/[][ \t]/, "", s) }
        (s == "" && /^[ \t]*store\.path[ \t]*=/) || (s == "store" && /^[ \t]*path[ \t]*=/) {
            match($0, /^[ \t]*[^ \t=]+/); print substr($0, 1, RLENGTH) " = \"" new "\""; next
        }
        { print }
    ' "$1" > "$tmp"
    cat "$tmp" > "$1"   # keeps owner and permissions of the original file
}

# Moves an old config (and its store file) from $FRP_DIR into the config
# directory and makes the store path absolute.
migrate_config() {
    local bin="$1" cfg="$2" cfg_dir old store resolved target
    cfg_dir="$(dirname "$cfg")"
    old="$FRP_DIR/$bin.toml"

    if [[ ! -f "$cfg" && -f "$old" && "$old" != "$cfg" ]]; then
        log "Found old config $old"
        if ask "Move it to $cfg?" y; then
            mv "$old" "$cfg"
            ok "Moved config to $cfg"
        fi
    fi
    [[ -f "$cfg" ]] || return 0

    store="$(get_store_path "$cfg")"
    [[ -n "$store" ]] || return 0

    # Resolve relative paths the way the old setup most likely used them
    case "$store" in
        /*) resolved="$store" ;;
        *)  resolved="$FRP_DIR/${store#./}" ;;
    esac
    target="$cfg_dir/$(basename "$store")"
    [[ "$resolved" == "$target" && "$store" == "$target" ]] && return 0

    log "Store path in $cfg: $store"
    ask "Move the store to $target and update the config?" y || return 0
    if [[ -f "$resolved" && "$resolved" != "$target" ]]; then
        mv "$resolved" "$target"
        ok "Moved store file to $target"
    fi
    set_store_path "$cfg" "$target"
    ok "store.path set to $target"
}

# Directory layout and permissions:
#   $FRP_DIR          root:root 755   binaries, backups, this script
#   $FRP_DIR/config   frp:frp   700   config + store (writable by the service)
fix_permissions() {
    local cfg_dir="$1" user="$2" group="$3"
    chown root:root "$FRP_DIR"
    chmod 755 "$FRP_DIR"
    mkdir -p "$cfg_dir"
    chown -R "$user:$group" "$cfg_dir"
    chmod 700 "$cfg_dir"
    find "$cfg_dir" -type f -exec chmod 600 {} +
    log "Permissions set: $FRP_DIR (root, 755), $cfg_dir ($user, 700)"
}

do_install_service() {
    local mode="$1" bin src unit new_unit user group cfg saved_yes was_active=false
    bin="$(bin_of "$mode")"
    unit="/etc/systemd/system/$bin.service"
    require_root
    command -v systemctl >/dev/null || die "systemd not found on this system."

    if [[ ! -x "$FRP_DIR/$bin" ]]; then
        warn "$bin is not installed in $FRP_DIR."
        ask "Download and install $bin now?" y || die "Aborted."
        saved_yes="$ASSUME_YES"; ASSUME_YES=true   # don't ask about the service again
        do_update "$mode"
        ASSUME_YES="$saved_yes"
    fi

    src="$(find_service_file "$bin")" \
        || die "No $bin.service found locally or at $SERVICE_SOURCE_URL."

    # Adapt paths if frp lives somewhere other than /opt/frp
    new_unit="$(mktemp -p "$TMP_ROOT")"
    sed "s#/opt/frp#$FRP_DIR#g" "$src" > "$new_unit"

    if [[ -f "$unit" ]] && ! cmp -s "$new_unit" "$unit"; then
        warn "$unit already exists and differs:"
        diff -u "$unit" "$new_unit" || true
        ask "Overwrite it?" n || { log "Keeping the existing unit."; cp "$unit" "$new_unit"; }
    fi

    # Service user (see the directory layout above)
    user="$(sed -n 's/^User=//p' "$new_unit" | head -n1)"
    group="$(sed -n 's/^Group=//p' "$new_unit" | head -n1)"
    user="${user:-root}"
    group="${group:-$user}"
    if [[ "$user" != root ]] && ! id -u "$user" >/dev/null 2>&1; then
        log "Creating system user '$user'"
        useradd --system --no-create-home --shell /usr/sbin/nologin "$user"
    fi
    getent group "$group" >/dev/null || groupadd --system "$group"

    cfg="$(sed -n 's/^ExecStart=.* -c \([^ ]*\).*/\1/p' "$new_unit" | head -n1)"
    cfg="${cfg:-$FRP_DIR/config/$bin.toml}"

    # Stop the running service before moving files around
    if systemctl is-active --quiet "$bin" 2>/dev/null; then
        was_active=true
        log "Stopping service $bin"
        systemctl stop "$bin"
    fi

    mkdir -p "$(dirname "$cfg")"
    migrate_config "$bin" "$cfg"
    fix_permissions "$(dirname "$cfg")" "$user" "$group"

    install -m 0644 "$new_unit" "$unit"
    systemctl daemon-reload
    ok "Installed $unit"

    if [[ ! -f "$cfg" ]]; then
        warn "Config $cfg not found – create it, then run: systemctl enable --now $bin"
        return 0
    fi

    if "$FRP_DIR/$bin" verify -c "$cfg" >/dev/null 2>&1; then
        log "Config syntax OK"
    else
        warn "'$bin verify' reports a problem with $cfg:"
        "$FRP_DIR/$bin" verify -c "$cfg" || true
    fi

    if ask "Enable and (re)start $bin now?" y; then
        systemctl enable "$bin" >/dev/null 2>&1
        systemctl restart "$bin"
        sleep 2
        if systemctl is-active --quiet "$bin"; then
            ok "Service $bin is enabled and running."
        else
            die "Service $bin failed to start. Logs: journalctl -u $bin -n 50"
        fi
    elif [[ "$was_active" == true ]]; then
        warn "$bin was running before and is now stopped. Start it with: systemctl start $bin"
    fi
}

do_remove_service() {
    local mode="$1" bin unit
    bin="$(bin_of "$mode")"
    unit="/etc/systemd/system/$bin.service"
    require_root
    [[ -f "$unit" ]] || die "$unit does not exist."

    ask "Stop, disable and remove the $bin service? (binary and config are kept)" n \
        || { log "Aborted."; return 0; }
    systemctl disable --now "$bin" >/dev/null 2>&1 || true
    rm -f "$unit"
    systemctl daemon-reload
    ok "Service $bin removed."
}

# is_installed <mode>  -> binary present or a systemd unit exists
is_installed() {
    local state
    [[ -x "$FRP_DIR/$(bin_of "$1")" ]] && return 0
    state="$(service_state "$1")"
    [[ "$state" != "not installed" && "$state" != "no systemd" ]]
}

installed_modes() {
    local m
    for m in client server; do
        if is_installed "$m"; then echo "$m"; fi
    done
}

show_status() {
    local mode bin ver state upd found=false
    fetch_latest || warn "Could not reach GitHub."
    echo "  frp directory:  $FRP_DIR"
    echo "  config dir:     $FRP_DIR/config"
    echo "  latest release: ${LATEST:-unknown}"
    echo
    for mode in $(installed_modes); do
        found=true
        bin="$(bin_of "$mode")"
        ver="$(installed_version "$mode")"
        state="$(service_state "$mode")"
        upd=""
        if [[ -n "$ver" && -n "$LATEST" && "$ver" != "$LATEST" ]]; then
            upd="${C_Y}update available${C_0}"
        fi
        printf "  %-5s  %-14s  service: %-22s %s\n" "$bin" "${ver:-binary missing}" "$state" "$upd"
    done
    [[ "$found" == true ]] || echo "  No frp installation found in $FRP_DIR."
}

# update_to_version <mode> [version]  (asks for the version if none is given)
update_to_version() {
    local ver="${2:-}"
    [[ -n "$ver" ]] || ver="$(prompt "Version (e.g. 0.61.0): ")"
    TARGET_VERSION="${ver#v}"; FORCE=true
    do_update "$1"
}

# Runs an action in a subshell so a failure doesn't end the menu
run_action() {
    ( "$@" ) || warn "Action failed."
    read -r -p "Press Enter to continue … " _ </dev/tty || true
}

# Menu entries: label, function, mode
MENU_LABEL=(); MENU_FN=(); MENU_MODE=()
add_entry() { MENU_LABEL+=("$1"); MENU_FN+=("$2"); MENU_MODE+=("$3"); }

build_menu() {
    local mode bin modes
    MENU_LABEL=(); MENU_FN=(); MENU_MODE=()
    modes="$(installed_modes)"

    if [[ -z "$modes" ]]; then
        add_entry "Install frpc (client)" do_install_service client
        add_entry "Install frps (server)" do_install_service server
        return
    fi

    for mode in $modes; do
        bin="$(bin_of "$mode")"
        add_entry "Update $bin"                   do_update         "$mode"
        add_entry "Install specific $bin version" update_to_version "$mode"
        if [[ "$(service_state "$mode")" == "not installed" ]]; then
            add_entry "Install $bin service"      do_install_service "$mode"
        else
            add_entry "Repair $bin service"       do_install_service "$mode"
            add_entry "Remove $bin service"       do_remove_service  "$mode"
        fi
    done
}

menu() {
    local choice i
    has_tty || die "No terminal available for the interactive menu. See --help."
    [[ $EUID -eq 0 ]] || warn "Not running as root – only the status is available. Restart with sudo."

    while true; do
        echo
        echo "${C_B}===== frp manager =====${C_0}"
        show_status
        build_menu
        echo
        for i in "${!MENU_LABEL[@]}"; do
            printf "  %d) %s\n" "$((i + 1))" "${MENU_LABEL[$i]}"
        done
        echo "  q) Quit"
        echo
        choice="$(prompt "Select: ")"
        if [[ "$choice" =~ ^[qQ]$ ]]; then
            exit 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#MENU_LABEL[@]} )); then
            i=$((choice - 1))
            run_action "${MENU_FN[$i]}" "${MENU_MODE[$i]}"
        else
            warn "Invalid choice."
        fi
    done
}

# ---------- Main ----------
CMD=""
MODE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        status|update|install-service|remove-service) CMD="$1" ;;
        client|server) MODE="$1" ;;
        --check)       CMD="status" ;;
        --version)     shift; TARGET_VERSION="${1:-}"; TARGET_VERSION="${TARGET_VERSION#v}" ;;
        --force)       FORCE=true ;;
        --dir)         shift; FRP_DIR="${1:-}" ;;
        -y|--yes)      ASSUME_YES=true ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "Unknown argument: $1 (see --help)" ;;
    esac
    shift
done

for cmd in curl tar uname; do
    command -v "$cmd" >/dev/null || die "'$cmd' is required but not installed."
done

# Directory of this script (symlinks resolved). When piped into bash, use $PWD.
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
else
    SELF_DIR="$PWD"
fi

if [[ -z "$FRP_DIR" ]]; then
    case "$SELF_DIR" in
        */bin|*/sbin) FRP_DIR="/opt/frp" ;;
        *)            FRP_DIR="$SELF_DIR" ;;
    esac
fi
FRP_DIR="${FRP_DIR%/}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# A mode without a command keeps the old frp-update.sh behaviour
[[ -z "$CMD" && -n "$MODE" ]] && CMD="update"

# No mode given: use the installed one if it's unambiguous, otherwise ask
if [[ "$CMD" =~ ^(update|remove-service)$ && -z "$MODE" ]]; then
    mapfile -t _modes < <(installed_modes)
    if [[ ${#_modes[@]} -eq 1 ]]; then
        MODE="${_modes[0]}"
    elif [[ ${#_modes[@]} -eq 0 && "$CMD" == remove-service ]]; then
        die "No frp installation found in $FRP_DIR."
    fi
fi
if [[ "$CMD" =~ ^(update|install-service|remove-service)$ && -z "$MODE" ]]; then
    has_tty && [[ "$ASSUME_YES" == false ]] || die "Please specify 'client' or 'server'."
    MODE="$(pick_mode)"
fi

case "$CMD" in
    "")              menu ;;
    status)          show_status ;;
    update)          do_update "$MODE" ;;
    install-service) do_install_service "$MODE" ;;
    remove-service)  do_remove_service "$MODE" ;;
esac