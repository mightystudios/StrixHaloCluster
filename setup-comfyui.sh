#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

SERVER_HOST="${SERVER_HOST:-}"
PEER_HOST="${PEER_HOST:-}"
NODE_ROLE="${NODE_ROLE:-auto}"
SERVER_IP="${SERVER_IP:-10.200.0.1}"
PEER_IP="${PEER_IP:-10.200.0.2}"
CLUSTER_IFACE="${CLUSTER_IFACE:-usb4llm0}"

TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || true)}}"
SHARE_GROUP="${SHARE_GROUP:-aimodels}"
SHARE_GID="${SHARE_GID:-971}"

COMFY_ROOT="${COMFY_ROOT:-/srv/comfyui}"
COMFY_LOCAL_CACHE="${COMFY_LOCAL_CACHE:-/var/lib/comfyui-local}"
COMFY_DIR="${COMFY_DIR:-}"
COMFYUI_REPO="${COMFYUI_REPO:-https://github.com/Comfy-Org/ComfyUI.git}"
COMFYUI_COMMIT="${COMFYUI_COMMIT:-b0b743566f65daafc423b4fea8a2fbda94b3384a}"
COMFYUI_PATCH_SOURCE="${COMFYUI_PATCH_SOURCE:-$SCRIPT_DIR/patches/comfyui/comfyui-b0b7435-hunyuan3d-rocm-sdpa.patch}"
COMFYUI_PATCH="/usr/local/share/comfyui/comfyui-b0b7435-hunyuan3d-rocm-sdpa.patch"
HY3D_SDPA_MODE="${HY3D_SDPA_MODE:-auto}"
HY3D_SDPA_PROBE_SOURCE="${HY3D_SDPA_PROBE_SOURCE:-$SCRIPT_DIR/scripts/comfyui-hy3d-sdpa-probe.py}"
HY3D_SDPA_PROBE="/usr/local/libexec/comfyui-hy3d-sdpa-probe.py"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
COMFY_SERVICE_MODE="${COMFY_SERVICE_MODE:-auto}"
LAN_NETS="${LAN_NETS:-10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-1}"
INSTALL_COMFY_SMB="${INSTALL_COMFY_SMB:-1}"
COMFY_SMB_SHARE="${COMFY_SMB_SHARE:-comfyui}"

COMFY_PY="${COMFY_PY:-3.12}"
ROCM_GFX="${ROCM_GFX:-gfx1151}"
ROCM_VERSION="${ROCM_VERSION:-10.0.0}"
TORCH_INDEX="${TORCH_INDEX:-https://stable.repo.amd.com/rocm/whl-next/}"
TORCH_EXPECTED_VERSION="${TORCH_EXPECTED_VERSION:-2.11.0+rocm10.0.0}"
TORCHVISION_EXPECTED_VERSION="${TORCHVISION_EXPECTED_VERSION:-0.26.0+rocm10.0.0}"
TORCHAUDIO_EXPECTED_VERSION="${TORCHAUDIO_EXPECTED_VERSION:-2.11.0+rocm10.0.0}"

COMFY_MANAGER_SECURITY="${COMFY_MANAGER_SECURITY:-weak}"
COMFY_CACHE_MODE="${COMFY_CACHE_MODE:-ram}"
COMFY_CACHE_ACTIVE_GB="${COMFY_CACHE_ACTIVE_GB:-4}"
COMFY_CACHE_INACTIVE_GB="${COMFY_CACHE_INACTIVE_GB:-32}"
COMFY_CACHE_LRU="${COMFY_CACHE_LRU:-8}"
COMFY_RESERVE_VRAM="${COMFY_RESERVE_VRAM:-16}"
COMFY_PREVIEW_METHOD="${COMFY_PREVIEW_METHOD:-auto}"
COMFY_ENABLE_ASSETS="${COMFY_ENABLE_ASSETS:-0}"
COMFY_DISABLE_API_NODES="${COMFY_DISABLE_API_NODES:-0}"

BOLD=$'\e[1m'
RED=$'\e[31m'
GRN=$'\e[32m'
YLW=$'\e[33m'
BLU=$'\e[34m'
RST=$'\e[0m'

log()  { echo "${BLU}${BOLD}==>${RST} ${BOLD}$*${RST}"; }
ok()   { echo "${GRN}  ok:${RST} $*"; }
warn() { echo "${YLW}  warn:${RST} $*"; }
die()  { echo "${RED}${BOLD}ERROR:${RST} $*" >&2; exit 1; }

trap 'die "failed at line $LINENO. See the output above."' ERR

ACTIONS=()
note_action() { ACTIONS+=("$*"); }

ensure_boot_unit() {
  local unit="$1"
  local state

  systemctl enable "$unit" >/dev/null 2>&1 || true
  state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  case "$state" in
    enabled|enabled-runtime|static|indirect|generated|alias)
      ok "$unit is boot-persistent ($state)"
      ;;
    *)
      die "$unit is not boot-persistent (state: ${state:-unknown})"
      ;;
  esac
}

# =============================================================================
# 1. CONFIGURATION AND VALIDATION
# =============================================================================
usage() {
  cat <<USAGE
Usage:
  sudo bash $SCRIPT_NAME --server <hostname> --peer <hostname> [options]

Installs only:
  - One local ComfyUI service (controller active, peer standby by default)
  - One read-write NFS ComfyUI store shared by both nodes
  - One anonymous read-write Windows workspace share at \\\\<server>\\$COMFY_SMB_SHARE
  - LAN access to this node's ComfyUI web service

Required:
  --server <hostname>          Hostname of the node exporting the shared store
  --peer <hostname>            Hostname of the node mounting the shared store

Role and network:
  --role <server|peer|auto>    Node role (default: auto from hostname)
  --server-ip <address>        Private server address (default: $SERVER_IP)
  --peer-ip <address>          Private peer address (default: $PEER_IP)
  --cluster-iface <name>       Private interface used by NFS (default: $CLUSTER_IFACE)

Paths and account:
  --user <name>                Account that runs ComfyUI
  --share-group <name>         Shared NFS group (default: $SHARE_GROUP)
  --share-gid <number>         Numeric group ID on both nodes (default: $SHARE_GID)
  --comfy-root <path>          Shared store (default: $COMFY_ROOT)
  --comfy-dir <path>           Local checkout (default: <user-home>/ComfyUI)
  --local-cache <path>         Local temp/user cache (default: $COMFY_LOCAL_CACHE)
  --smb-share-name <name>      Server-side Windows share (default: $COMFY_SMB_SHARE)

ComfyUI:
  --port <port>                Web service port (default: $COMFYUI_PORT)
  --comfy-cache <mode>         ram, classic, lru, or none
  --reserve-vram <gib>         GPU memory ComfyUI leaves free (default: $COMFY_RESERVE_VRAM)
  --hy3d-sdpa <mode>           auto, default, or math (default: $HY3D_SDPA_MODE)
  --service-mode <mode>        active, standby, or auto; auto starts the
                               server role and leaves the peer in standby
  --preview <mode>             none, auto, latent2rgb, or taesd
  --enable-assets              Enable the shared-store asset scanner
  --disable-api-nodes          Disable frontend API nodes
  --manager-security <level>   Manager security level (default: $COMFY_MANAGER_SECURITY)

Other:
  --lan-nets "<cidrs>"         Space-separated LAN ranges allowed through UFW
  --no-smb-share              Do not configure Windows access to the shared store
  --no-firewall               Do not add UFW rules
  -h, --help                  Show this help

All settings can also be supplied through matching environment variables.
USAGE
}

need_arg() {
  [ -n "${2:-}" ] || die "$1 requires a value"
}

valid_hostname() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --server)
      need_arg "$1" "${2:-}"
      SERVER_HOST="$2"
      shift
      ;;
    --peer)
      need_arg "$1" "${2:-}"
      PEER_HOST="$2"
      shift
      ;;
    --role)
      need_arg "$1" "${2:-}"
      NODE_ROLE="$2"
      shift
      ;;
    --server-ip)
      need_arg "$1" "${2:-}"
      SERVER_IP="$2"
      shift
      ;;
    --peer-ip)
      need_arg "$1" "${2:-}"
      PEER_IP="$2"
      shift
      ;;
    --cluster-iface)
      need_arg "$1" "${2:-}"
      CLUSTER_IFACE="$2"
      shift
      ;;
    --user)
      need_arg "$1" "${2:-}"
      TARGET_USER="$2"
      shift
      ;;
    --share-group)
      need_arg "$1" "${2:-}"
      SHARE_GROUP="$2"
      shift
      ;;
    --share-gid)
      need_arg "$1" "${2:-}"
      SHARE_GID="$2"
      shift
      ;;
    --comfy-root)
      need_arg "$1" "${2:-}"
      COMFY_ROOT="$2"
      shift
      ;;
    --comfy-dir)
      need_arg "$1" "${2:-}"
      COMFY_DIR="$2"
      shift
      ;;
    --local-cache)
      need_arg "$1" "${2:-}"
      COMFY_LOCAL_CACHE="$2"
      shift
      ;;
    --smb-share-name)
      need_arg "$1" "${2:-}"
      COMFY_SMB_SHARE="$2"
      shift
      ;;
    --port)
      need_arg "$1" "${2:-}"
      COMFYUI_PORT="$2"
      shift
      ;;
    --comfy-cache)
      need_arg "$1" "${2:-}"
      COMFY_CACHE_MODE="$2"
      shift
      ;;
    --reserve-vram)
      need_arg "$1" "${2:-}"
      COMFY_RESERVE_VRAM="$2"
      shift
      ;;
    --hy3d-sdpa)
      need_arg "$1" "${2:-}"
      HY3D_SDPA_MODE="$2"
      shift
      ;;
    --service-mode)
      need_arg "$1" "${2:-}"
      COMFY_SERVICE_MODE="$2"
      shift
      ;;
    --preview)
      need_arg "$1" "${2:-}"
      COMFY_PREVIEW_METHOD="$2"
      shift
      ;;
    --enable-assets)
      COMFY_ENABLE_ASSETS=1
      ;;
    --disable-api-nodes)
      COMFY_DISABLE_API_NODES=1
      ;;
    --manager-security)
      need_arg "$1" "${2:-}"
      COMFY_MANAGER_SECURITY="$2"
      shift
      ;;
    --lan-nets)
      need_arg "$1" "${2:-}"
      LAN_NETS="$2"
      shift
      ;;
    --no-smb-share)
      INSTALL_COMFY_SMB=0
      ;;
    --no-firewall)
      CONFIGURE_FIREWALL=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
  shift
done

[ "$EUID" -eq 0 ] || die "run this script as root, for example: sudo bash $SCRIPT_NAME ..."
command -v apt-get >/dev/null 2>&1 || die "this installer requires an apt-based Linux distribution"
command -v systemctl >/dev/null 2>&1 || die "this installer requires systemd"

[ -n "$SERVER_HOST" ] && [ -n "$PEER_HOST" ] || die "--server and --peer are required"
valid_hostname "$SERVER_HOST" || die "invalid server hostname: $SERVER_HOST"
valid_hostname "$PEER_HOST" || die "invalid peer hostname: $PEER_HOST"
[ "$SERVER_HOST" != "$PEER_HOST" ] || die "server and peer hostnames must differ"

[ -n "$TARGET_USER" ] || die "could not determine the ComfyUI user; pass --user <name>"
[ "$TARGET_USER" != "root" ] || die "--user must name an unprivileged account"
id "$TARGET_USER" >/dev/null 2>&1 || die "user '$TARGET_USER' does not exist; run setup-environment.sh first or create the account"

[[ "$SHARE_GID" =~ ^[0-9]+$ ]] || die "share GID must be numeric"
[[ "$COMFYUI_PORT" =~ ^[0-9]+$ ]] || die "ComfyUI port must be numeric"
[ "$COMFYUI_PORT" -ge 1 ] && [ "$COMFYUI_PORT" -le 65535 ] || die "ComfyUI port must be between 1 and 65535"
[[ "$CLUSTER_IFACE" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]] || die "invalid private interface name: $CLUSTER_IFACE"
[[ "$SHARE_GROUP" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "invalid shared group name: $SHARE_GROUP"
[[ "$SERVER_IP" =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] || die "invalid server IPv4 address: $SERVER_IP"
[[ "$PEER_IP" =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] || die "invalid peer IPv4 address: $PEER_IP"
[[ "$COMFY_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid shared-store path: $COMFY_ROOT"
[[ "$COMFY_LOCAL_CACHE" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid local-cache path: $COMFY_LOCAL_CACHE"
[[ "$COMFY_MANAGER_SECURITY" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid Manager security level"
[[ "$COMFY_SMB_SHARE" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "SMB share name may contain only letters, numbers, '.', '_', and '-'"
case "${COMFY_SMB_SHARE,,}" in
  global|homes|printers)
    die "reserved SMB share name: $COMFY_SMB_SHARE"
    ;;
esac
case "$COMFY_ROOT" in
  /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
    die "refusing unsafe shared-store path: $COMFY_ROOT"
    ;;
esac
case "$COMFY_LOCAL_CACHE" in
  /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
    die "refusing unsafe local-cache path: $COMFY_LOCAL_CACHE"
    ;;
esac

case "$COMFY_CACHE_MODE" in
  ram|classic|lru|none) ;;
  *) die "--comfy-cache must be ram, classic, lru, or none" ;;
esac

case "$COMFY_PREVIEW_METHOD" in
  none|auto|latent2rgb|taesd) ;;
  *) die "--preview must be none, auto, latent2rgb, or taesd" ;;
esac
case "$COMFY_SERVICE_MODE" in
  active|standby|auto) ;;
  *) die "--service-mode must be active, standby, or auto" ;;
esac
case "$HY3D_SDPA_MODE" in
  auto|default|math) ;;
  *) die "--hy3d-sdpa must be auto, default, or math" ;;
esac
[[ "$COMFYUI_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
  || die "COMFYUI_COMMIT must be a full lowercase 40-character Git commit"
[ -r "$COMFYUI_PATCH_SOURCE" ] || die "ComfyUI compatibility patch not found: $COMFYUI_PATCH_SOURCE"
[ -r "$HY3D_SDPA_PROBE_SOURCE" ] || die "Hunyuan3D SDPA probe not found: $HY3D_SDPA_PROBE_SOURCE"

for value in "$COMFY_CACHE_ACTIVE_GB" "$COMFY_CACHE_INACTIVE_GB" "$COMFY_RESERVE_VRAM"; do
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "ComfyUI memory values must be numeric GiB values"
done
[[ "$COMFY_CACHE_LRU" =~ ^[0-9]+$ ]] || die "COMFY_CACHE_LRU must be a whole number"
[ "${COMFY_CACHE_ACTIVE_GB%%.*}" -le "${COMFY_CACHE_INACTIVE_GB%%.*}" ] \
  || die "active cache must not exceed inactive cache"
for value in \
    "$COMFY_ENABLE_ASSETS" \
    "$COMFY_DISABLE_API_NODES" \
    "$CONFIGURE_FIREWALL" \
    "$INSTALL_COMFY_SMB"; do
  case "$value" in
    0|1) ;;
    *) die "boolean settings must be 0 or 1" ;;
  esac
done

THIS_HOST="$(hostname -s 2>/dev/null || true)"
[ -n "$THIS_HOST" ] || THIS_HOST="$(head -n1 /etc/hostname 2>/dev/null || true)"

case "$NODE_ROLE" in
  server|peer)
    ;;
  auto)
    if [ "$THIS_HOST" = "$SERVER_HOST" ]; then
      NODE_ROLE=server
    elif [ "$THIS_HOST" = "$PEER_HOST" ]; then
      NODE_ROLE=peer
    else
      die "hostname '$THIS_HOST' matches neither '$SERVER_HOST' nor '$PEER_HOST'; pass --role server or --role peer"
    fi
    ;;
  *)
    die "--role must be server, peer, or auto"
    ;;
esac

if [ "$NODE_ROLE" = "server" ]; then
  IS_SERVER=1
  IS_PEER=0
  MY_HOST="$SERVER_HOST"
  OTHER_HOST="$PEER_HOST"
  OTHER_IP="$PEER_IP"
else
  IS_SERVER=0
  IS_PEER=1
  MY_HOST="$PEER_HOST"
  OTHER_HOST="$SERVER_HOST"
  OTHER_IP="$SERVER_IP"
fi
if [ "$COMFY_SERVICE_MODE" = "auto" ]; then
  if [ "$IS_SERVER" = "1" ]; then
    COMFY_SERVICE_MODE=active
  else
    COMFY_SERVICE_MODE=standby
  fi
fi

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$USER_HOME" ] && [ -d "$USER_HOME" ] || die "home directory for '$TARGET_USER' was not found"
[ -n "$COMFY_DIR" ] || COMFY_DIR="$USER_HOME/ComfyUI"
[[ "$COMFY_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid ComfyUI checkout path: $COMFY_DIR"
case "$COMFY_DIR" in
  /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
    die "refusing unsafe ComfyUI checkout path: $COMFY_DIR"
    ;;
esac
[ "$COMFY_DIR" != "$COMFY_ROOT" ] || die "the local checkout and shared store must be different paths"
[ "$COMFY_LOCAL_CACHE" != "$COMFY_ROOT" ] || die "the local cache and shared store must be different paths"
TARGET_PRIMARY_GROUP="$(id -gn "$TARGET_USER")"

as_user() {
  sudo -u "$TARGET_USER" -H bash -lc "$1"
}

comfy_git() {
  sudo -u "$TARGET_USER" -H git -C "$COMFY_DIR" "$@"
}

MANAGED_CHECKOUT_LINKS=()

restore_managed_checkout_links() {
  local expected_target
  local managed_path
  local relative_path

  MANAGED_CHECKOUT_LINKS=()
  for relative_path in models custom_nodes input output; do
    managed_path="$COMFY_DIR/$relative_path"
    expected_target="$COMFY_ROOT/$relative_path"
    [ -L "$managed_path" ] || continue
    [ "$(readlink "$managed_path")" = "$expected_target" ] \
      || die "refusing to replace unmanaged symlink: $managed_path"

    MANAGED_CHECKOUT_LINKS+=("$relative_path")
  done

  if [ "${#MANAGED_CHECKOUT_LINKS[@]}" -gt 0 ]; then
    for relative_path in "${MANAGED_CHECKOUT_LINKS[@]}"; do
      sudo -u "$TARGET_USER" -H unlink -- "$COMFY_DIR/$relative_path"
    done
    if ! comfy_git restore --source=HEAD --staged --worktree -- "${MANAGED_CHECKOUT_LINKS[@]}"; then
      for relative_path in "${MANAGED_CHECKOUT_LINKS[@]}"; do
        sudo -u "$TARGET_USER" -H rm -rf -- "$COMFY_DIR/$relative_path" || true
        sudo -u "$TARGET_USER" -H ln -s \
          "$COMFY_ROOT/$relative_path" "$COMFY_DIR/$relative_path" || true
      done
      die "could not restore tracked files while preparing the pinned ComfyUI checkout"
    fi
    ok "temporarily restored tracked ComfyUI files for the pinned checkout"
  fi
}

reinstate_managed_checkout_links() {
  local expected_target
  local managed_path
  local path_status
  local relative_path

  for relative_path in "${MANAGED_CHECKOUT_LINKS[@]}"; do
    managed_path="$COMFY_DIR/$relative_path"
    expected_target="$COMFY_ROOT/$relative_path"

    if [ -L "$managed_path" ]; then
      [ "$(readlink "$managed_path")" = "$expected_target" ] \
        || die "refusing to replace unmanaged symlink: $managed_path"
      continue
    fi

    if [ -e "$managed_path" ]; then
      path_status="$(comfy_git status --porcelain --untracked-files=all -- "$relative_path")"
      [ -z "$path_status" ] \
        || die "refusing to discard unexpected files restored below $managed_path"
      sudo -u "$TARGET_USER" -H rm -rf -- "$managed_path"
    fi
    sudo -u "$TARGET_USER" -H ln -s "$expected_target" "$managed_path"
  done

  if [ "${#MANAGED_CHECKOUT_LINKS[@]}" -gt 0 ]; then
    ok "restored managed shared-workspace links without copying checkout files"
  fi
  MANAGED_CHECKOUT_LINKS=()
}

verify_comfyui_checkout_changes() {
  local actual_commit="$1"
  local changed_path
  local expected_target
  local managed_root

  while IFS= read -r changed_path; do
    case "$changed_path" in
      comfy/ldm/hunyuan3d/vae.py)
        [ "$actual_commit" = "$COMFYUI_COMMIT" ] \
          || die "refusing to overwrite a modified $changed_path at an unmanaged revision"
        comfy_git apply --reverse --check "$COMFYUI_PATCH" \
          || die "refusing to overwrite non-managed edits in $changed_path"
        ;;
      models/*|custom_nodes/*|input/*|output/*)
        managed_root="${changed_path%%/*}"
        expected_target="$COMFY_ROOT/$managed_root"
        [ -L "$COMFY_DIR/$managed_root" ] \
          && [ "$(readlink "$COMFY_DIR/$managed_root")" = "$expected_target" ] \
          || die "refusing to overwrite non-managed changes below $managed_root"
        ;;
      *)
        die "refusing to overwrite tracked change in $COMFY_DIR: $changed_path"
        ;;
    esac
  done < <(comfy_git diff --name-only HEAD)
}

first_unmanaged_checkout_change() {
  local changed_path

  while IFS= read -r changed_path; do
    case "$changed_path" in
      models/*|custom_nodes/*|input/*|output/*)
        ;;
      *)
        printf '%s\n' "$changed_path"
        return 0
        ;;
    esac
  done < <(comfy_git diff --name-only HEAD)
}

prepare_comfyui_checkout() {
  local actual_commit
  local existing_checkout=0
  local managed_patch_removed=0
  local remaining_change
  local tracked_changes

  if [ -e "$COMFY_DIR" ] && [ ! -d "$COMFY_DIR/.git" ]; then
    die "$COMFY_DIR exists but is not a Git checkout"
  fi

  if [ ! -d "$COMFY_DIR/.git" ]; then
    sudo -u "$TARGET_USER" -H git clone --no-checkout "$COMFYUI_REPO" "$COMFY_DIR"
  else
    existing_checkout=1
    actual_commit="$(comfy_git rev-parse HEAD)"
    verify_comfyui_checkout_changes "$actual_commit"
  fi

  log "Pinning ComfyUI at $COMFYUI_COMMIT"
  if ! comfy_git fetch --tags --prune origin; then
    if comfy_git cat-file -e "$COMFYUI_COMMIT^{commit}"; then
      warn "could not refresh ComfyUI from origin; using the locally cached pinned commit"
    else
      die "could not fetch pinned ComfyUI commit $COMFYUI_COMMIT"
    fi
  fi
  if ! comfy_git cat-file -e "$COMFYUI_COMMIT^{commit}"; then
    comfy_git fetch --depth 1 origin "$COMFYUI_COMMIT" \
      || die "could not fetch pinned ComfyUI commit $COMFYUI_COMMIT"
  fi

  if [ "$existing_checkout" = "1" ]; then
    if [ "$actual_commit" = "$COMFYUI_COMMIT" ] \
        && comfy_git apply --reverse --check "$COMFYUI_PATCH"; then
      comfy_git apply --reverse "$COMFYUI_PATCH"
      managed_patch_removed=1
      ok "removed the previously managed ComfyUI patch"
    fi

    remaining_change="$(first_unmanaged_checkout_change)"
    if [ -n "$remaining_change" ]; then
      if [ "$managed_patch_removed" = "1" ]; then
        comfy_git apply "$COMFYUI_PATCH" \
          || warn "could not restore the managed Hunyuan3D patch after detecting other edits"
      fi
      die "refusing to overwrite tracked change in $COMFY_DIR: $remaining_change"
    fi

    restore_managed_checkout_links
    tracked_changes="$(comfy_git status --porcelain --untracked-files=no)"
    if [ -n "$tracked_changes" ]; then
      reinstate_managed_checkout_links
      if [ "$managed_patch_removed" = "1" ]; then
        comfy_git apply "$COMFYUI_PATCH" \
          || warn "could not restore the managed Hunyuan3D patch after checkout validation failed"
      fi
      die "refusing to overwrite tracked changes in $COMFY_DIR; preserve or revert them, then rerun"
    fi
  fi

  if ! comfy_git checkout --detach "$COMFYUI_COMMIT"; then
    reinstate_managed_checkout_links
    if [ "$managed_patch_removed" = "1" ]; then
      comfy_git apply "$COMFYUI_PATCH" \
        || warn "could not restore the managed Hunyuan3D patch after checkout failed"
    fi
    die "could not check out pinned ComfyUI revision $COMFYUI_COMMIT"
  fi

  actual_commit="$(comfy_git rev-parse HEAD)"
  if [ "$actual_commit" != "$COMFYUI_COMMIT" ]; then
    reinstate_managed_checkout_links
    die "ComfyUI checkout resolved to $actual_commit instead of $COMFYUI_COMMIT"
  fi

  if ! comfy_git apply --check "$COMFYUI_PATCH"; then
    reinstate_managed_checkout_links
    die "the managed Hunyuan3D patch does not apply to ComfyUI $COMFYUI_COMMIT"
  fi
  if ! comfy_git apply "$COMFYUI_PATCH"; then
    reinstate_managed_checkout_links
    die "could not apply the managed Hunyuan3D patch"
  fi
  if ! comfy_git diff --check; then
    comfy_git apply --reverse "$COMFYUI_PATCH" || true
    reinstate_managed_checkout_links
    die "the managed Hunyuan3D patch introduced a whitespace error"
  fi
  reinstate_managed_checkout_links
  ok "pinned and patched ComfyUI $COMFYUI_COMMIT"
}

if [ "$IS_SERVER" = "1" ]; then
  QWEN_SERVICE_UNIT="qwen3d8-server.service"
else
  QWEN_SERVICE_UNIT="qwen3d8-rpc.service"
fi
QWEN_WAS_ACTIVE=0
QWEN_MAIN_PID_BEFORE=""

capture_qwen_service_state() {
  if systemctl is-active --quiet "$QWEN_SERVICE_UNIT"; then
    QWEN_WAS_ACTIVE=1
    QWEN_MAIN_PID_BEFORE="$(systemctl show "$QWEN_SERVICE_UNIT" --property MainPID --value)"
    [[ "$QWEN_MAIN_PID_BEFORE" =~ ^[1-9][0-9]*$ ]] \
      || die "$QWEN_SERVICE_UNIT is active but has no valid main PID"
    ok "will preserve active $QWEN_SERVICE_UNIT process $QWEN_MAIN_PID_BEFORE"
  else
    ok "$QWEN_SERVICE_UNIT is inactive and will be left unchanged"
  fi
}

verify_qwen_service_unchanged() {
  local current_pid

  [ "$QWEN_WAS_ACTIVE" = "1" ] || return 0
  systemctl is-active --quiet "$QWEN_SERVICE_UNIT" \
    || die "$QWEN_SERVICE_UNIT was active before setup but is no longer active"

  current_pid="$(systemctl show "$QWEN_SERVICE_UNIT" --property MainPID --value)"
  [ "$current_pid" = "$QWEN_MAIN_PID_BEFORE" ] \
    || die "$QWEN_SERVICE_UNIT main PID changed from $QWEN_MAIN_PID_BEFORE to $current_pid"
  ok "$QWEN_SERVICE_UNIT remained active with PID $current_pid"
}

ensure_share_group() {
  local current_gid
  local gid_owner

  if getent group "$SHARE_GROUP" >/dev/null 2>&1; then
    current_gid="$(getent group "$SHARE_GROUP" | cut -d: -f3)"
    [ "$current_gid" = "$SHARE_GID" ] \
      || die "group '$SHARE_GROUP' is GID $current_gid here but must be $SHARE_GID on both nodes"
  else
    gid_owner="$(getent group "$SHARE_GID" | cut -d: -f1 || true)"
    [ -z "$gid_owner" ] || die "GID $SHARE_GID is already used by group '$gid_owner'"
    groupadd -g "$SHARE_GID" "$SHARE_GROUP"
    ok "created group '$SHARE_GROUP' with GID $SHARE_GID"
  fi

  usermod -aG "$SHARE_GROUP",render,video "$TARGET_USER"
  ok "$TARGET_USER added to $SHARE_GROUP, render, and video"
}

normalize_shared_workspace_permissions() {
  local directory
  local workspace_path
  local invalid_path

  [ "$IS_SERVER" = "1" ] || return 0

  log "Normalizing shared ComfyUI workspace permissions"
  for directory in models custom_nodes input output workflows; do
    workspace_path="$COMFY_ROOT/$directory"
    [ -d "$workspace_path" ] || continue

    chgrp -hR "$SHARE_GROUP" "$workspace_path"
    chmod -R g+rwX "$workspace_path"
    find "$workspace_path" -xdev -type d -exec chmod g+s {} +
    find "$workspace_path" -xdev -type d \
      -exec setfacl -m "d:g:$SHARE_GROUP:rwx,d:m::rwx" {} +

    invalid_path="$(
      find "$workspace_path" -xdev \
        \( \( -type d ! -perm -2070 \) -o \( -type f ! -perm -0060 \) \) \
        -print -quit
    )"
    [ -z "$invalid_path" ] \
      || die "shared asset path is not group-writable after repair: $invalid_path"
  done
  ok "shared workspace folders inherit read-write access for group '$SHARE_GROUP'"
}

# =============================================================================
# 2. SHARED NFS STORE
# =============================================================================
capture_qwen_service_state

export DEBIAN_FRONTEND=noninteractive
log "Installing ComfyUI and shared-store prerequisites"
apt-get update -y
BASE_PACKAGES=(acl ca-certificates curl git sudo findutils coreutils util-linux iputils-ping)
[ "$CONFIGURE_FIREWALL" = "1" ] && BASE_PACKAGES+=(ufw)
apt-get install -y "${BASE_PACKAGES[@]}"
ensure_share_group

configure_shared_store_server() {
  log "Exporting the shared ComfyUI store to $PEER_IP"

  apt-get install -y nfs-kernel-server

  install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" "$COMFY_ROOT"
  for directory in models custom_nodes input output workflows hf; do
    install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" "$COMFY_ROOT/$directory"
  done
  normalize_shared_workspace_permissions

  install -d -m 0755 /etc/nfs.conf.d
  cat > /etc/nfs.conf.d/10-comfyui-cluster.conf <<NFSCONF
# Managed by $SCRIPT_NAME
[nfsd]
vers2 = n
vers3 = n
udp = n
tcp = y
NFSCONF

  install -d -m 0755 /etc/exports.d
  cat > /etc/exports.d/comfyui-cluster.exports <<EXPORTS
# Managed by $SCRIPT_NAME
# Read-write export restricted to the private peer address.
$COMFY_ROOT	$PEER_IP/32(rw,sync,no_subtree_check,root_squash)
EXPORTS
  chmod 0644 /etc/exports.d/comfyui-cluster.exports

  cat > "$COMFY_ROOT/.cluster-ids" <<IDS
# Managed by $SCRIPT_NAME on $SERVER_HOST
SERVER_HOST=$SERVER_HOST
TARGET_USER=$TARGET_USER
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_GID=$(id -g "$TARGET_USER")
SHARE_GROUP=$SHARE_GROUP
SHARE_GID=$SHARE_GID
IDS
  chown "$TARGET_USER:$SHARE_GROUP" "$COMFY_ROOT/.cluster-ids"
  chmod 0664 "$COMFY_ROOT/.cluster-ids"

  ensure_boot_unit nfs-server
  systemctl restart nfs-server >/dev/null 2>&1 \
    || systemctl start nfs-server >/dev/null 2>&1
  exportfs -rav
  systemctl is-active --quiet nfs-server || die "nfs-server is not active"
  ok "$COMFY_ROOT exported read-write to $PEER_IP"
}

configure_shared_store_peer() {
  log "Mounting the shared ComfyUI store from $SERVER_IP"

  apt-get install -y nfs-common
  mountpoint -q "$COMFY_ROOT" 2>/dev/null || install -d -m 0755 "$COMFY_ROOT"

  sed -i '\%^# >>> qwen3d8 ComfyUI shared store%,\%^# <<< qwen3d8 ComfyUI shared store%d' /etc/fstab
  sed -i "\#[[:space:]]${COMFY_ROOT}[[:space:]]#d" /etc/fstab
  cat >> /etc/fstab <<FSTAB
# >>> qwen3d8 ComfyUI shared store (managed by $SCRIPT_NAME) >>>
$SERVER_IP:$COMFY_ROOT	$COMFY_ROOT	nfs4	rw,_netdev,noatime,nofail,nconnect=4,x-systemd.automount,x-systemd.mount-timeout=30	0	0
# <<< qwen3d8 ComfyUI shared store <<<
FSTAB
  systemctl daemon-reload >/dev/null 2>&1 || true

  if ping -c1 -W2 -n "$SERVER_IP" >/dev/null 2>&1; then
    if mountpoint -q "$COMFY_ROOT"; then
      ok "$COMFY_ROOT already mounted"
    elif timeout 45 mount "$COMFY_ROOT" >/dev/null 2>&1; then
      ok "$COMFY_ROOT mounted from $SERVER_IP"
    else
      warn "$COMFY_ROOT did not mount immediately; systemd will automount it when the server is available"
    fi
  else
    warn "$SERVER_IP is not reachable yet; the shared store will automount later"
  fi

  if [ -r "$COMFY_ROOT/.cluster-ids" ]; then
    local server_uid
    local server_gid
    local local_uid
    local local_gid

    server_uid="$(awk -F= '$1=="TARGET_UID"{print $2}' "$COMFY_ROOT/.cluster-ids")"
    server_gid="$(awk -F= '$1=="SHARE_GID"{print $2}' "$COMFY_ROOT/.cluster-ids")"
    local_uid="$(id -u "$TARGET_USER")"
    local_gid="$(getent group "$SHARE_GROUP" | cut -d: -f3)"

    if [ -n "$server_uid" ] && [ "$server_uid" != "$local_uid" ]; then
      warn "UID mismatch: $TARGET_USER is $local_uid here and $server_uid on $SERVER_HOST"
      note_action "Make '$TARGET_USER' use UID $server_uid on both nodes before writing to $COMFY_ROOT"
    else
      ok "$TARGET_USER has the same UID on both nodes"
    fi

    if [ -n "$server_gid" ] && [ "$server_gid" != "$local_gid" ]; then
      warn "GID mismatch: $SHARE_GROUP is $local_gid here and $server_gid on $SERVER_HOST"
      note_action "Make '$SHARE_GROUP' use GID $server_gid on both nodes"
    else
      ok "$SHARE_GROUP has the same GID on both nodes"
    fi
  fi
}

if [ "$IS_SERVER" = "1" ]; then
  configure_shared_store_server
else
  configure_shared_store_peer
fi
echo

# =============================================================================
# 3. WINDOWS ACCESS TO THE SHARED ASSET STORE
# =============================================================================
configure_comfy_smb_share() {
  local smb_conf=/etc/samba/smb.conf
  local smb_tmp
  local probe_file
  local probe_readback
  local probe_dir
  local probe_name
  local probe_target
  local smb_probe
  local directory
  local probe_failed=0
  local -a probe_targets

  log "Sharing $COMFY_ROOT with Windows as '$COMFY_SMB_SHARE'"

  apt-get install -y samba samba-common-bin smbclient \
    || die "failed to install Samba; use --no-smb-share to leave the share out"
  ok "Samba $(dpkg-query -W -f='${Version}' samba 2>/dev/null) installed"

  install -d -m 0755 "$(dirname "$smb_conf")"
  [ -f "$smb_conf" ] || printf '[global]\n' > "$smb_conf"
  [ -f "${smb_conf}.qwen3d8-cluster-orig" ] \
    || cp -a "$smb_conf" "${smb_conf}.qwen3d8-cluster-orig"

  smb_tmp="$(mktemp)"
  sed '/qwen3d8-comfyui-smb BEGIN/,/qwen3d8-comfyui-smb END/d' \
    "$smb_conf" > "$smb_tmp"

  if awk -v expected="$COMFY_SMB_SHARE" '
      /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
        section = $0
        sub(/^[[:space:]]*\[/, "", section)
        sub(/\][[:space:]]*$/, "", section)
        if (tolower(section) == tolower(expected)) {
          found = 1
        }
      }
      END { exit found ? 0 : 1 }
    ' "$smb_tmp"; then
    rm -f "$smb_tmp"
    die "SMB share '$COMFY_SMB_SHARE' already exists outside the managed ComfyUI block"
  fi

  {
    echo
    echo "# ==== qwen3d8-comfyui-smb BEGIN - managed by $SCRIPT_NAME, edits here are lost ===="
    cat <<SMBCONF
[global]
   server min protocol = SMB2
   client min protocol = SMB2
   map to guest = Bad User
   guest account = $TARGET_USER

[$COMFY_SMB_SHARE]
   comment = Shared ComfyUI workspace on $MY_HOST
   path = $COMFY_ROOT
   browseable = yes
   read only = no
   guest ok = yes
   guest only = yes
   force user = $TARGET_USER
   force group = $SHARE_GROUP
   create mask = 0664
   force create mode = 0664
   directory mask = 2775
   force directory mode = 2775
   veto files = /.cluster-ids/hf/
   delete veto files = no
SMBCONF
    echo "# ==== qwen3d8-comfyui-smb END ===="
  } >> "$smb_tmp"

  if testparm -s "$smb_tmp" >/dev/null 2>&1; then
    install -m 0644 "$smb_tmp" "$smb_conf"
    ok "validated [$COMFY_SMB_SHARE] -> $COMFY_ROOT in $smb_conf"
  else
    warn "generated Samba configuration failed validation; $smb_conf was not changed"
    { testparm -s "$smb_tmp" 2>&1 || true; } | sed 's/^/       /' | head -20 || true
    rm -f "$smb_tmp"
    return 1
  fi
  rm -f "$smb_tmp"

  ensure_boot_unit smbd.service
  if systemctl restart smbd.service >/dev/null 2>&1; then
    ok "smbd running"
  else
    { systemctl status smbd.service --no-pager -n 8 2>&1 || true; } \
      | sed 's/^/       /' | head -12 || true
    die "smbd did not start; inspect: systemctl status smbd"
  fi

  probe_file="$(mktemp)"
  probe_dir=".comfyui-smb-write-test-$$"
  probe_name="probe.txt"
  probe_targets=(models custom_nodes workflows input output)
  for directory in models/background_removal models/checkpoints; do
    if [ -d "$COMFY_ROOT/$directory" ]; then
      probe_targets+=("$directory")
      break
    fi
  done
  printf 'ComfyUI SMB write test\n' > "$probe_file"
  probe_readback="${probe_file}.readback"
  for probe_target in "${probe_targets[@]}"; do
    rm -f "$probe_readback"
    if smb_probe="$(
        smbclient "//127.0.0.1/$COMFY_SMB_SHARE" -N \
          -c "cd \"$probe_target\"; mkdir \"$probe_dir\"; cd \"$probe_dir\"; put \"$probe_file\" \"$probe_name\"; get \"$probe_name\" \"$probe_readback\"; del \"$probe_name\"; cd ..; rmdir \"$probe_dir\"" 2>&1
      )" && cmp -s "$probe_file" "$probe_readback"; then
      ok "local anonymous SMB nested write test passed in $probe_target"
    else
      probe_failed=1
      warn "the ComfyUI share failed its nested write test in $probe_target:"
      printf '%s\n' "$smb_probe" | sed 's/^/       /' | head -8 || true
    fi
    rm -f "$COMFY_ROOT/$probe_target/$probe_dir/$probe_name"
    rmdir "$COMFY_ROOT/$probe_target/$probe_dir" 2>/dev/null || true
  done
  rm -f "$probe_file" "$probe_readback"
  warn "SMB clients can modify executable custom-node code; expose this share only to trusted LAN clients"
  if [ "$probe_failed" = "1" ]; then
    die "the SMB share is not read-write in every mapped folder; inspect with: smbclient //127.0.0.1/$COMFY_SMB_SHARE -N"
  fi
}

if [ "$IS_SERVER" = "1" ] && [ "$INSTALL_COMFY_SMB" = "1" ]; then
  configure_comfy_smb_share
  echo
fi

# =============================================================================
# 4. COMFYUI CHECKOUT, PYTHON ENVIRONMENT, AND SHARED LINKS
# =============================================================================
install_uv() {
  if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
    ok "uv already installed at $UV_BIN"
    return
  fi

  log "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh
  UV_BIN=/usr/local/bin/uv
  [ -x "$UV_BIN" ] || die "uv installation did not create $UV_BIN"
  ok "uv installed at $UV_BIN"
}

install_uv

log "Installing the local ComfyUI checkout"
install -D -m 0644 -o root -g root "$COMFYUI_PATCH_SOURCE" "$COMFYUI_PATCH"
install -D -m 0755 -o root -g root "$HY3D_SDPA_PROBE_SOURCE" "$HY3D_SDPA_PROBE"
prepare_comfyui_checkout

install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" \
  "$COMFY_LOCAL_CACHE" "$COMFY_LOCAL_CACHE/temp"
install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_PRIMARY_GROUP" \
  "$COMFY_LOCAL_CACHE/user"

shared_store_ready=0
if [ "$IS_SERVER" = "1" ] || findmnt -T "$COMFY_ROOT" -n -o FSTYPE 2>/dev/null | grep nfs >/dev/null; then
  shared_store_ready=1
else
  warn "$COMFY_ROOT is not mounted yet; links will target the future automount"
fi

link_shared() {
  local relative_path="$1"
  local target="$2"
  local source="$COMFY_DIR/$relative_path"
  local copy_error=""
  local copy_ok=0

  install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" "$target" 2>/dev/null || true

  if [ -L "$source" ]; then
    if [ "$(readlink -f "$source")" = "$(readlink -f "$target")" ]; then
      return 0
    fi
    rm -f "$source"
  elif [ -d "$source" ]; then
    if [ -n "$(ls -A "$source" 2>/dev/null)" ]; then
      log "  migrating existing $relative_path into the shared store"
      if copy_error="$(cp -a "$source/." "$target/" 2>&1)"; then
        copy_ok=1
      elif copy_error="$(as_user "cp -a '$source/.' '$target/'" 2>&1)"; then
        copy_ok=1
      fi

      if [ "$copy_ok" = "0" ]; then
        if [ -n "$(find "$source" -type f ! -name '.gitkeep' ! -name 'put_*' -print -quit 2>/dev/null)" ]; then
          warn "could not migrate $source into $target; leaving it local"
          [ -n "$copy_error" ] && warn "  ${copy_error%%$'\n'*}"
          return 1
        fi
      fi
    fi
    rm -rf "$source"
  fi

  ln -sfn "$target" "$source"
  chown -h "$TARGET_USER:$TARGET_PRIMARY_GROUP" "$source" 2>/dev/null || true
}

link_shared_pending_mount() {
  local relative_path="$1"
  local target="$2"
  local source="$COMFY_DIR/$relative_path"

  if [ -L "$source" ]; then
    if [ "$(readlink "$source" 2>/dev/null || true)" = "$target" ]; then
      return 0
    fi
    rm -f "$source"
  elif [ -d "$source" ]; then
    if [ -n "$(find "$source" -type f ! -name '.gitkeep' ! -name 'put_*' -print -quit 2>/dev/null)" ]; then
      die "$source contains real files but the shared store is unavailable; mount $COMFY_ROOT before rerunning"
    fi
    rm -rf "$source"
  fi

  ln -sfn "$target" "$source"
  chown -h "$TARGET_USER:$TARGET_PRIMARY_GROUP" "$source" 2>/dev/null || true
}

normalize_shared_entry_as_user() {
  local path="$1"

  if [ -L "$path" ]; then
    sudo -u "$TARGET_USER" -H chgrp -h "$SHARE_GROUP" "$path"
    return
  fi

  sudo -u "$TARGET_USER" -H chgrp -hR "$SHARE_GROUP" "$path"
  sudo -u "$TARGET_USER" -H chmod -R g+rwX "$path"
  sudo -u "$TARGET_USER" -H find "$path" -xdev -type d -exec chmod g+s {} +
  sudo -u "$TARGET_USER" -H find "$path" -xdev -type d \
    -exec setfacl -m "d:g:$SHARE_GROUP:rwx,d:m::rwx" {} +
}

link_shared_custom_nodes() {
  local source="$COMFY_DIR/custom_nodes"
  local target="$COMFY_ROOT/custom_nodes"
  local backup
  local entry
  local entry_name
  local copy_error
  local copy_failures=0
  local duplicate_count=0
  local migrated_count=0

  install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" "$target" 2>/dev/null || true

  if [ -L "$source" ]; then
    if [ "$(readlink -f "$source")" = "$(readlink -f "$target")" ]; then
      return 0
    fi
    rm -f "$source"
  elif [ -d "$source" ]; then
    if [ -z "$(ls -A "$source" 2>/dev/null)" ]; then
      rmdir "$source"
    elif [ -z "$(ls -A "$target" 2>/dev/null)" ]; then
      log "  migrating existing custom_nodes into the empty shared store"
      if copy_error="$(
          sudo -u "$TARGET_USER" -H cp -a -- "$source/." "$target/" 2>&1
        )"; then
        normalize_shared_entry_as_user "$target"
        rm -rf "$source"
      else
        warn "could not migrate $source into $target; leaving it local"
        [ -n "$copy_error" ] && warn "  ${copy_error%%$'\n'*}"
        return 1
      fi
    else
      backup="$COMFY_DIR/custom_nodes.local-before-sharing-$(date -u +%Y%m%dT%H%M%SZ)"
      while [ -e "$backup" ]; do
        backup="${backup}-${RANDOM}"
      done

      mv -- "$source" "$backup"
      log "  merging peer-only custom nodes into the controller's shared store"
      while IFS= read -r -d '' entry; do
        entry_name="${entry##*/}"
        if [ -e "$target/$entry_name" ] || [ -L "$target/$entry_name" ]; then
          duplicate_count=$((duplicate_count + 1))
          continue
        fi

        if copy_error="$(
            sudo -u "$TARGET_USER" -H cp -a -- "$entry" "$target/" 2>&1
          )"; then
          normalize_shared_entry_as_user "$target/$entry_name"
          migrated_count=$((migrated_count + 1))
          ok "migrated peer-only custom node: $entry_name"
        else
          copy_failures=$((copy_failures + 1))
          warn "could not migrate peer-only custom node '$entry_name'"
          [ -n "$copy_error" ] && warn "  ${copy_error%%$'\n'*}"
        fi
      done < <(find "$backup" -mindepth 1 -maxdepth 1 -print0)

      if [ "$duplicate_count" -gt 0 ]; then
        warn "kept $duplicate_count controller copies instead of overwriting them from the peer"
      fi
      if [ "$migrated_count" -gt 0 ]; then
        note_action "Install or repair dependencies for the $migrated_count peer-only custom nodes on $SERVER_HOST"
      fi
      note_action "Review and remove the preserved peer custom-node backup when no longer needed: $backup"
      if [ "$copy_failures" -gt 0 ]; then
        note_action "Manually reconcile $copy_failures custom-node entries that remain only in $backup"
      fi
    fi
  elif [ -e "$source" ]; then
    die "$source exists but is not a directory or symbolic link"
  fi

  ln -sfn "$target" "$source"
  chown -h "$TARGET_USER:$TARGET_PRIMARY_GROUP" "$source" 2>/dev/null || true
}

verify_shared_workspace_access() {
  local directory
  local test_dir
  local test_file
  local expected
  local actual

  log "Verifying shared ComfyUI workspace read-write access"
  expected="ComfyUI shared write test from $MY_HOST"

  for directory in models custom_nodes input output workflows; do
    [ -d "$COMFY_ROOT/$directory" ] \
      || die "required shared folder is missing: $COMFY_ROOT/$directory"

    test_dir="$COMFY_ROOT/$directory/.comfyui-rw-test-$MY_HOST-$$"
    test_file="$test_dir/probe.txt"

    if ! sudo -u "$TARGET_USER" -H mkdir -- "$test_dir"; then
      die "$TARGET_USER cannot create directories in $COMFY_ROOT/$directory"
    fi
    if ! printf '%s\n' "$expected" \
        | sudo -u "$TARGET_USER" -H tee "$test_file" >/dev/null; then
      rmdir "$test_dir" 2>/dev/null || true
      die "$TARGET_USER cannot write files in $COMFY_ROOT/$directory"
    fi

    actual="$(sudo -u "$TARGET_USER" -H cat "$test_file" 2>/dev/null || true)"
    if [ "$actual" != "$expected" ]; then
      rm -f "$test_file"
      rmdir "$test_dir" 2>/dev/null || true
      die "$TARGET_USER cannot read files in $COMFY_ROOT/$directory"
    fi

    sudo -u "$TARGET_USER" -H rm -- "$test_file" \
      || die "$TARGET_USER cannot delete files in $COMFY_ROOT/$directory"
    sudo -u "$TARGET_USER" -H rmdir -- "$test_dir" \
      || die "$TARGET_USER cannot delete directories in $COMFY_ROOT/$directory"
    ok "read-write access verified: $COMFY_ROOT/$directory"
  done
}

if [ "$shared_store_ready" = "1" ]; then
  for pair in \
      "models:$COMFY_ROOT/models" \
      "input:$COMFY_ROOT/input" \
      "output:$COMFY_ROOT/output"; do
    link_shared "${pair%%:*}" "${pair#*:}"
    ok "ComfyUI/${pair%%:*} -> ${pair#*:}"
  done
  link_shared_custom_nodes
  ok "ComfyUI/custom_nodes -> $COMFY_ROOT/custom_nodes"

  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_PRIMARY_GROUP" \
    "$COMFY_DIR/user" "$COMFY_DIR/user/default"
  link_shared user/default/workflows "$COMFY_ROOT/workflows"
  ok "ComfyUI/user/default/workflows -> $COMFY_ROOT/workflows"
else
  for pair in \
      "models:$COMFY_ROOT/models" \
      "custom_nodes:$COMFY_ROOT/custom_nodes" \
      "input:$COMFY_ROOT/input" \
      "output:$COMFY_ROOT/output"; do
    link_shared_pending_mount "${pair%%:*}" "${pair#*:}"
    ok "ComfyUI/${pair%%:*} -> ${pair#*:} (pending NFS mount)"
  done

  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_PRIMARY_GROUP" \
    "$COMFY_DIR/user" "$COMFY_DIR/user/default"
  link_shared_pending_mount user/default/workflows "$COMFY_ROOT/workflows"
  ok "ComfyUI/user/default/workflows -> $COMFY_ROOT/workflows (pending NFS mount)"
fi

if [ "$IS_SERVER" = "1" ]; then
  normalize_shared_workspace_permissions
fi
verify_shared_workspace_access

cat > "$USER_HOME/.comfyui_provision.sh" <<'PROVISION'
#!/usr/bin/env bash
set -Eeuo pipefail

exec </dev/null
export GIT_TERMINAL_PROMPT=0

cd "$COMFY_DIR"

if [ -x .venv/bin/python ]; then
  existing_py="$(.venv/bin/python -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
  if [ "$existing_py" != "$COMFY_PY" ]; then
    echo "Rebuilding .venv because Python $existing_py does not match $COMFY_PY"
    rm -rf .venv
  fi
fi

if [ ! -x .venv/bin/python ] || ! .venv/bin/python -c '' >/dev/null 2>&1; then
  rm -rf .venv
  "$UV_BIN" venv --python "$COMFY_PY" .venv
fi

"$UV_BIN" pip install --python .venv/bin/python \
  --index-url "$TORCH_INDEX" \
  --extra-index-url https://pypi.org/simple \
  --index-strategy unsafe-best-match \
  "torch==${TORCH_EXPECTED_VERSION}" \
  "amd-torch-device-gfx1151==${TORCH_EXPECTED_VERSION}" \
  "rocm-sdk-devel==${ROCM_VERSION}" \
  "rocm-sdk-device-gfx1151==${ROCM_VERSION}" \
  "torchvision==${TORCHVISION_EXPECTED_VERSION}" \
  "amd-torchvision-device-gfx1151==${TORCHVISION_EXPECTED_VERSION}" \
  "torchaudio==${TORCHAUDIO_EXPECTED_VERSION}"

grep -viE '^(torch|torchvision|torchaudio)([[:space:]<>=!~;]|$)' requirements.txt \
  > .reqs-notorch.txt || cp requirements.txt .reqs-notorch.txt
"$UV_BIN" pip install --python .venv/bin/python -r .reqs-notorch.txt

manager_ok=0
if [ -f manager_requirements.txt ]; then
  grep -viE '^(torch|torchvision|torchaudio)([[:space:]<>=!~;]|$)' manager_requirements.txt \
    > .mgr-reqs.txt || cp manager_requirements.txt .mgr-reqs.txt
  if "$UV_BIN" pip install --python .venv/bin/python -r .mgr-reqs.txt; then
    manager_ok=1
  fi
fi

if [ "$manager_ok" != "1" ] || ! .venv/bin/python -c 'import comfyui_manager' 2>/dev/null; then
  mkdir -p custom_nodes
  if [ -d custom_nodes/comfyui-manager/.git ]; then
    git -C custom_nodes/comfyui-manager pull --ff-only || true
  else
    git clone https://github.com/Comfy-Org/ComfyUI-Manager custom_nodes/comfyui-manager || true
  fi

  if [ -f custom_nodes/comfyui-manager/requirements.txt ]; then
    grep -viE '^(torch|torchvision|torchaudio)([[:space:]<>=!~;]|$)' \
      custom_nodes/comfyui-manager/requirements.txt \
      > .mgr-cn-reqs.txt || cp custom_nodes/comfyui-manager/requirements.txt .mgr-cn-reqs.txt
    "$UV_BIN" pip install --python .venv/bin/python -r .mgr-cn-reqs.txt || true
  fi
fi

"$UV_BIN" pip install --python .venv/bin/python --no-deps \
  --index-url "$TORCH_INDEX" \
  --extra-index-url https://pypi.org/simple \
  --index-strategy unsafe-best-match \
  "torch==${TORCH_EXPECTED_VERSION}" \
  "amd-torch-device-gfx1151==${TORCH_EXPECTED_VERSION}" \
  "rocm-sdk-devel==${ROCM_VERSION}" \
  "rocm-sdk-device-gfx1151==${ROCM_VERSION}" \
  "torchvision==${TORCHVISION_EXPECTED_VERSION}" \
  "amd-torchvision-device-gfx1151==${TORCHVISION_EXPECTED_VERSION}" \
  "torchaudio==${TORCHAUDIO_EXPECTED_VERSION}"

echo "Validating torchvision deform_conv2d on the ROCm GPU"
.venv/bin/python - <<'PY'
import torch
from torchvision.ops import deform_conv2d

if not torch.cuda.is_available():
    raise RuntimeError("ROCm GPU is not available to PyTorch")

device = torch.device("cuda")
input_tensor = torch.zeros((1, 1, 5, 5), device=device)
offset = torch.zeros((1, 18, 3, 3), device=device)
weight = torch.ones((1, 1, 3, 3), device=device)
output = deform_conv2d(input_tensor, offset, weight)
torch.cuda.synchronize()

if output.shape != (1, 1, 3, 3):
    raise RuntimeError(f"unexpected deform_conv2d output shape: {output.shape}")

print(
    "torchvision deform_conv2d GPU smoke test passed on "
    f"{torch.cuda.get_device_name(device)}"
)
PY

mkdir -p custom_nodes
if [ -d custom_nodes/comfyui-url-downloader/.git ]; then
  git -C custom_nodes/comfyui-url-downloader pull --ff-only || true
else
  git clone https://github.com/mighty-bean/comfyui-url-downloader custom_nodes/comfyui-url-downloader || true
fi
PROVISION
chown "$TARGET_USER:$TARGET_PRIMARY_GROUP" "$USER_HOME/.comfyui_provision.sh"
chmod 0755 "$USER_HOME/.comfyui_provision.sh"

if as_user "COMFY_DIR='$COMFY_DIR' UV_BIN='$UV_BIN' COMFY_PY='$COMFY_PY' TORCH_INDEX='$TORCH_INDEX' TORCH_EXPECTED_VERSION='$TORCH_EXPECTED_VERSION' TORCHVISION_EXPECTED_VERSION='$TORCHVISION_EXPECTED_VERSION' TORCHAUDIO_EXPECTED_VERSION='$TORCHAUDIO_EXPECTED_VERSION' ROCM_VERSION='$ROCM_VERSION' bash '$USER_HOME/.comfyui_provision.sh'"; then
  ok "ComfyUI Python environment ready"
else
  die "ComfyUI Python provisioning failed; rerun: sudo -u $TARGET_USER bash $USER_HOME/.comfyui_provision.sh"
fi

COMFY_ROCM_PATH="$COMFY_DIR/.venv/lib/python$COMFY_PY/site-packages/_rocm_sdk_core"
HY3D_SDPA_STATE_FILE="$COMFY_LOCAL_CACHE/hy3d-sdpa-mode"

log "Selecting a Hunyuan3D SDPA backend with isolated GPU probes"
if as_user "ROCM_PATH='$COMFY_ROCM_PATH' HIP_PATH='$COMFY_ROCM_PATH' PYTORCH_ROCM_ARCH='$ROCM_GFX' '$COMFY_DIR/.venv/bin/python' '$HY3D_SDPA_PROBE' --requested-mode '$HY3D_SDPA_MODE' --state-file '$HY3D_SDPA_STATE_FILE'"; then
  ok "Hunyuan3D SDPA compatibility probe completed"
else
  die "Hunyuan3D SDPA compatibility probe failed; no safe backend policy was selected"
fi

HY3D_SDPA_SELECTED="$(tr -d '[:space:]' < "$HY3D_SDPA_STATE_FILE")"
case "$HY3D_SDPA_SELECTED" in
  default)
    HY3D_FORCE_MATH_SDPA=0
    ;;
  math)
    HY3D_FORCE_MATH_SDPA=1
    ;;
  *)
    die "invalid Hunyuan3D SDPA probe state: $HY3D_SDPA_SELECTED"
    ;;
esac
ok "Hunyuan3D SDPA policy selected: $HY3D_SDPA_SELECTED"

comfy_has_flag() {
  as_user "grep -q -- '$1' '$COMFY_DIR/comfy/cli_args.py'"
}

COMFY_TUNE_FLAGS=""
comfy_add_flag() {
  COMFY_TUNE_FLAGS="${COMFY_TUNE_FLAGS:+$COMFY_TUNE_FLAGS }$*"
}

COMFY_MANAGER_FLAG=""
if comfy_has_flag --enable-manager 2>/dev/null; then
  COMFY_MANAGER_FLAG=--enable-manager
fi

COMFY_TEMP_FLAG=""
if comfy_has_flag --temp-directory 2>/dev/null; then
  COMFY_TEMP_FLAG="--temp-directory $COMFY_LOCAL_CACHE/temp"
fi

case "$COMFY_CACHE_MODE" in
  ram)
    if comfy_has_flag --cache-ram 2>/dev/null; then
      comfy_add_flag "--cache-ram $COMFY_CACHE_ACTIVE_GB $COMFY_CACHE_INACTIVE_GB"
    fi
    ;;
  classic)
    comfy_has_flag --cache-classic 2>/dev/null && comfy_add_flag --cache-classic
    ;;
  lru)
    comfy_has_flag --cache-lru 2>/dev/null && comfy_add_flag "--cache-lru $COMFY_CACHE_LRU"
    ;;
  none)
    comfy_has_flag --cache-none 2>/dev/null && comfy_add_flag --cache-none
    ;;
esac

if [ "${COMFY_RESERVE_VRAM%%.*}" != "0" ] && comfy_has_flag --reserve-vram 2>/dev/null; then
  comfy_add_flag "--reserve-vram $COMFY_RESERVE_VRAM"
fi

if [ "$COMFY_PREVIEW_METHOD" != "none" ] && comfy_has_flag --preview-method 2>/dev/null; then
  comfy_add_flag "--preview-method $COMFY_PREVIEW_METHOD"
fi

if [ "$COMFY_ENABLE_ASSETS" = "1" ] && comfy_has_flag --enable-assets 2>/dev/null; then
  comfy_add_flag --enable-assets
fi

if [ "$COMFY_DISABLE_API_NODES" = "1" ] && comfy_has_flag --disable-api-nodes 2>/dev/null; then
  comfy_add_flag --disable-api-nodes
fi

install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_PRIMARY_GROUP" \
  "$COMFY_DIR/user" \
  "$COMFY_DIR/user/__manager" \
  "$COMFY_DIR/user/default" \
  "$COMFY_DIR/user/default/ComfyUI-Manager"

for manager_dir in \
    "$COMFY_DIR/user/__manager" \
    "$COMFY_DIR/user/default/ComfyUI-Manager"; do
  if [ ! -f "$manager_dir/config.ini" ]; then
    printf '[default]\nsecurity_level = %s\nnetwork_mode = public\n' \
      "$COMFY_MANAGER_SECURITY" > "$manager_dir/config.ini"
  fi
done
chown -R -h "$TARGET_USER:$TARGET_PRIMARY_GROUP" "$COMFY_DIR/user"

if [ "$IS_PEER" = "1" ]; then
  automount_unit="$(systemd-escape -p --suffix=automount "$COMFY_ROOT" 2>/dev/null || true)"
  [ -n "$automount_unit" ] || automount_unit=remote-fs.target

  cat > /usr/local/bin/comfy-store-wait <<WAIT
#!/usr/bin/env bash
set -u

for _ in \$(seq 1 40); do
  ls "$COMFY_ROOT/" >/dev/null 2>&1 || true
  if findmnt -T "$COMFY_ROOT" -n -o FSTYPE 2>/dev/null | grep nfs >/dev/null; then
    if [ -r "$COMFY_ROOT/.cluster-ids" ]; then
      server_uid="\$(awk -F= '\$1==\"TARGET_UID\"{print \$2}' "$COMFY_ROOT/.cluster-ids")"
      server_gid="\$(awk -F= '\$1==\"SHARE_GID\"{print \$2}' "$COMFY_ROOT/.cluster-ids")"
      if [ -n "\$server_uid" ] && [ "\$server_uid" != "$(id -u "$TARGET_USER")" ]; then
        echo "comfy-store-wait: UID mismatch for $TARGET_USER (local $(id -u "$TARGET_USER"), server \$server_uid)" >&2
        exit 1
      fi
      if [ -n "\$server_gid" ] && [ "\$server_gid" != "$SHARE_GID" ]; then
        echo "comfy-store-wait: GID mismatch for $SHARE_GROUP (local $SHARE_GID, server \$server_gid)" >&2
        exit 1
      fi
    fi
    exit 0
  fi
  sleep 3
done

echo "comfy-store-wait: $COMFY_ROOT is not mounted from $SERVER_HOST" >&2
exit 1
WAIT
  chmod 0755 /usr/local/bin/comfy-store-wait

  SERVICE_MOUNT_DEPENDENCY="After=$automount_unit
Wants=$automount_unit"
  SERVICE_MOUNT_GATE="ExecStartPre=/usr/local/bin/comfy-store-wait"
else
  SERVICE_MOUNT_DEPENDENCY=""
  SERVICE_MOUNT_GATE=""
fi

# =============================================================================
# 5. COMFYUI SERVICE
# =============================================================================
COMFY_ROCM_PATH="$COMFY_DIR/.venv/lib/python$COMFY_PY/site-packages/_rocm_sdk_core"
cat > /etc/systemd/system/comfyui.service <<UNIT
[Unit]
Description=ComfyUI on $MY_HOST
After=network-online.target
Wants=network-online.target
$SERVICE_MOUNT_DEPENDENCY

[Service]
Type=simple
User=$TARGET_USER
Group=$TARGET_PRIMARY_GROUP
SupplementaryGroups=render video $SHARE_GROUP
UMask=0002
Environment=HOME=$USER_HOME
Environment=HF_HOME=$COMFY_ROOT/hf
Environment=HF_HUB_CACHE=$COMFY_ROOT/hf/hub
Environment=ROCM_PATH=$COMFY_ROCM_PATH
Environment=HIP_PATH=$COMFY_ROCM_PATH
Environment=PYTORCH_ROCM_ARCH=$ROCM_GFX
Environment=COMFY_HY3D_FORCE_MATH_SDPA=$HY3D_FORCE_MATH_SDPA
WorkingDirectory=$COMFY_DIR
$SERVICE_MOUNT_GATE
ExecStart=$COMFY_DIR/.venv/bin/python $COMFY_DIR/main.py --listen $BIND_ADDR --port $COMFYUI_PORT $COMFY_MANAGER_FLAG $COMFY_TEMP_FLAG $COMFY_TUNE_FLAGS
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
if [ "$COMFY_SERVICE_MODE" = "standby" ]; then
  systemctl disable --now comfyui.service >/dev/null 2>&1 \
    || die "could not place comfyui.service in standby"
  ok "comfyui.service installed in standby and disabled at boot"
else
  ensure_boot_unit comfyui.service
  if [ "$IS_PEER" = "1" ] && ! findmnt -T "$COMFY_ROOT" -n -o FSTYPE 2>/dev/null | grep nfs >/dev/null; then
    systemctl start --no-block comfyui.service >/dev/null 2>&1 || true
    warn "comfyui.service is enabled and waiting for the shared NFS store"
  elif systemctl restart comfyui.service >/dev/null 2>&1; then
    ok "comfyui.service running on $BIND_ADDR:$COMFYUI_PORT"
  else
    warn "comfyui.service did not start immediately"
    note_action "Inspect it with: systemctl status comfyui.service --no-pager"
  fi
fi

# =============================================================================
# 6. FIREWALL AND SUMMARY
# =============================================================================
configure_firewall() {
  [ "$CONFIGURE_FIREWALL" = "1" ] || return 0

  log "Adding ComfyUI and shared-store firewall rules"
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true

  local net
  for net in $LAN_NETS; do
    ufw allow from "$net" to any port "$COMFYUI_PORT" proto tcp >/dev/null
    if [ "$IS_SERVER" = "1" ] && [ "$INSTALL_COMFY_SMB" = "1" ]; then
      ufw allow from "$net" to any port 445 proto tcp >/dev/null
    fi
  done

  if [ "$IS_SERVER" = "1" ]; then
    ufw allow in on "$CLUSTER_IFACE" from "$PEER_IP" to any port 2049 proto tcp >/dev/null
  fi

  yes | ufw enable >/dev/null 2>&1 || true
  systemctl enable ufw.service >/dev/null 2>&1 || true
  if ufw status 2>/dev/null | grep '^Status: active' >/dev/null; then
    if [ "$IS_SERVER" = "1" ] && [ "$INSTALL_COMFY_SMB" = "1" ]; then
      ok "UFW active; ComfyUI and SMB are LAN-only and NFS is private-link-only"
    else
      ok "UFW active; ComfyUI is LAN-only and NFS is private-link-only"
    fi
    if grep -E '^ENABLED=yes' /etc/ufw/ufw.conf >/dev/null 2>&1; then
      ok "UFW is configured to restore its rules at boot"
    else
      warn "UFW is active now but is not marked enabled for boot"
      note_action "Persist UFW at boot with: sudo ufw enable"
    fi
  else
    warn "UFW is not active"
    note_action "Enable it with: sudo ufw default deny incoming && sudo ufw enable"
  fi
}

configure_firewall
verify_qwen_service_unchanged

LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
[ -n "$LAN_IP" ] || LAN_IP="$MY_HOST"

echo
echo "${GRN}${BOLD}ComfyUI setup complete on $MY_HOST${RST}"
echo "  Role:          $NODE_ROLE"
echo "  Service mode:  $COMFY_SERVICE_MODE"
echo "  Revision:      ${COMFYUI_COMMIT:0:12}"
echo "  HY3D SDPA:     $HY3D_SDPA_SELECTED (requested: $HY3D_SDPA_MODE)"
if [ "$COMFY_SERVICE_MODE" = "active" ]; then
  echo "  Web service:   http://$LAN_IP:$COMFYUI_PORT"
else
  echo "  Web service:   standby; start manually with: sudo systemctl start comfyui.service"
fi
echo "  Shared store:  $COMFY_ROOT"
if [ "$IS_SERVER" = "1" ]; then
  echo "  NFS export:    $COMFY_ROOT -> $PEER_IP"
  if [ "$INSTALL_COMFY_SMB" = "1" ]; then
    echo "  Windows share: \\\\$LAN_IP\\$COMFY_SMB_SHARE -> $COMFY_ROOT"
  fi
else
  echo "  NFS source:    $SERVER_IP:$COMFY_ROOT"
fi
echo "  Shared code:   $COMFY_DIR/custom_nodes -> $COMFY_ROOT/custom_nodes"
echo "  Local state:   $COMFY_DIR/.venv, $COMFY_DIR/user, $COMFY_LOCAL_CACHE"

if [ "${#ACTIONS[@]}" -gt 0 ]; then
  echo
  echo "${YLW}${BOLD}Action required${RST}"
  for action in "${ACTIONS[@]}"; do
    echo "${YLW}  *${RST} $action"
  done
fi
