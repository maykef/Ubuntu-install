#!/usr/bin/env bash
# Ubuntu targeted installer for:
# - system update/upgrade
# - install openssh-server + nvtop
# - install GUI apps via snap:
#   pycharm-community, chromium, mission-center, onlyoffice-desktopeditors

set -euo pipefail

require_sudo() {
  if [[ $EUID -ne 0 ]]; then
    SUDO="sudo"
  else
    SUDO=""
  fi
}

have_internet() {
  ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1
}

apt_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

apt_install() {
  local pkgs=("$@")
  local need=()
  for p in "${pkgs[@]}"; do
    if apt_installed "$p"; then
      echo "✓ $p already installed"
    else
      need+=("$p")
    fi
  done
  if ((${#need[@]})); then
    $SUDO apt-get install -y "${need[@]}"
  fi
}

ensure_snapd() {
  if ! command -v snap >/dev/null 2>&1; then
    echo "snap not found; installing snapd…"
    apt_install snapd
    sleep 2
  fi
}

snap_installed() {
  snap list | awk '{print $1}' | grep -qx "$1"
}

snap_install_if_missing() {
  local name="$1"
  shift || true
  local extra=("$@")
  if snap_installed "$name"; then
    echo "✓ snap '$name' already installed"
  else
    $SUDO snap install "$name" "${extra[@]}"
  fi
}

main() {
  require_sudo
  have_internet || { echo "No internet connectivity detected. Aborting." >&2; exit 1; }

  echo "==> Updating system…"
  $SUDO apt-get update -y
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get upgrade -y

  echo "==> Installing essential packages (openssh-server, nvtop)…"
  apt_install openssh-server nvtop

  echo "==> Enabling and starting SSH service…"
  $SUDO systemctl enable ssh
  $SUDO systemctl start ssh
  systemctl is-active --quiet ssh && echo "✓ SSH service is active" || echo "⚠ SSH service failed to start"

  echo "==> Installing GUI apps via snap…"
  ensure_snapd
  snap_install_if_missing "pycharm-community" --classic
  snap_install_if_missing "chromium"
  snap_install_if_missing "mission-center"
  snap_install_if_missing "onlyoffice-desktopeditors"

  echo "==> All done."
  echo "• SSH service is running (port 22)"
  echo "• Installed: openssh-server, nvtop"
  echo "• Installed snaps: pycharm-community, chromium, mission-center, onlyoffice-desktopeditors"
  echo "• If you were added to new groups, log out/in."
}

main "$@"
