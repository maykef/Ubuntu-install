#!/usr/bin/env bash
# Ubuntu installer with forced ZFS import for pool 'tank'
# - update/upgrade
# - zfsutils-linux + ALWAYS import 'tank' with -f (if not already imported)
# - curl
# - Ollama (official installer)
# - PyCharm Community, Chromium, Mission Center, ONLYOFFICE via snap

set -euo pipefail

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
require_sudo() { if [[ $EUID -ne 0 ]]; then need_cmd sudo; SUDO="sudo"; else SUDO=""; fi; }
have_internet() { ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; }
apt_installed() { dpkg -s "$1" >/dev/null 2>&1; }
apt_install() {
  local need=()
  for p in "$@"; do apt_installed "$p" && echo "✓ $p already installed" || need+=("$p"); done
  ((${#need[@]})) && $SUDO apt-get install -y "${need[@]}"
}
ensure_snapd() {
  if ! command -v snap >/dev/null 2>&1; then
    echo "snap not found; installing snapd…"
    apt_install snapd
    sleep 2
  fi
}
snap_installed() { snap list | awk '{print $1}' | grep -qx "$1"; }
snap_install_if_missing() {
  local name="$1"; shift || true
  if snap_installed "$name"; then
    echo "✓ snap '$name' already installed"
  else
    $SUDO snap install "$name" "$@"
  fi
}

force_import_tank() {
  # Import only if not already imported; use -f as requested
  if zpool list -H -o name 2>/dev/null | grep -qx "tank"; then
    echo "✓ 'tank' already imported"
    return 0
  fi
  echo "==> Force-importing ZFS pool 'tank'…"
  if $SUDO zpool import -f tank; then
    echo "✓ Forced import of 'tank' complete"
  else
    echo "⚠ Failed to force-import 'tank'. You can try: sudo zpool import -f tank" >&2
  fi
}

main() {
  require_sudo
  need_cmd curl
  have_internet || { echo "No internet connectivity detected. Aborting." >&2; exit 1; }

  echo "==> Updating system…"
  $SUDO apt-get update -y
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get upgrade -y

  echo "==> Installing base packages…"
  apt_install ca-certificates gnupg curl zfsutils-linux

  echo "==> Importing ZFS pool 'tank' (forced if needed)…"
  if command -v zpool >/dev/null 2>&1; then
    force_import_tank
  else
    echo "⚠ zpool command not found even after installing zfsutils-linux."
  fi

  echo "==> Installing Ollama…"
  curl -fsSL https://ollama.com/install.sh | $SUDO sh
  if systemctl list-unit-files | grep -q '^ollama.service'; then
    $SUDO systemctl enable --now ollama || true
  fi

  echo "==> Installing GUI apps via snap…"
  ensure_snapd
  snap_install_if_missing "pycharm-community" --classic
  snap_install_if_missing "chromium"
  snap_install_if_missing "mission-center"
  snap_install_if_missing "onlyoffice-desktopeditors"

  # Ensure ONLYOFFICE shows in app grid (some desktops miss the snap .desktop)
  echo "==> Ensuring ONLYOFFICE desktop entry is visible…"
  DESK_SRC="/var/lib/snapd/desktop/applications/onlyoffice-desktopeditors_onlyoffice-desktopeditors.desktop"
  DESK_DST="$HOME/.local/share/applications/onlyoffice-desktopeditors_onlyoffice-desktopeditors.desktop"
  if [[ -f "$DESK_SRC" ]]; then
    mkdir -p "$HOME/.local/share/applications"
    cp -f "$DESK_SRC" "$DESK_DST"
    update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
  fi

  echo "==> All done."
}

main "$@"
