#!/usr/bin/env bash
# Ubuntu targeted installer for:
# - system update/upgrade
# - zfsutils-linux + import pool 'tank'
# - curl
# - git
# - Ollama (official installer)
# - Docker Engine + Compose plugin (no Docker Desktop)
# - Open WebUI (Docker container)
# - PyCharm Community, Chromium, Mission Center, ONLYOFFICE via snap

set -euo pipefail

# ----------------------- helpers -----------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command '$1' not found." >&2
    exit 1
  }
}

require_sudo() {
  if [[ $EUID -ne 0 ]]; then
    need_cmd sudo
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

docker_installed() {
  command -v docker >/dev/null 2>&1
}

docker_service_active() {
  systemctl is-active --quiet docker
}

docker_container_exists() {
  local name="$1"
  $SUDO docker ps -a --format '{{.Names}}' | grep -qx "$name"
}

docker_container_running() {
  local name="$1"
  $SUDO docker ps --format '{{.Names}}' | grep -qx "$name"
}

# ----------------------- steps -----------------------
main() {
  require_sudo
  have_internet || { echo "No internet connectivity detected. Aborting." >&2; exit 1; }

  echo "==> Updating system…"
  $SUDO apt-get update -y
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get upgrade -y

  echo "==> Installing base packages…"
  # Added 'git' here
  apt_install ca-certificates gnupg curl zfsutils-linux git

  echo "==> Importing ZFS pool 'tank' (if present)…"
  if command -v zpool >/dev/null 2>&1; then
    if zpool list -H -o name 2>/dev/null | grep -qx "tank"; then
      echo "✓ 'tank' already imported"
    else
      if zpool import 2>/dev/null | grep -q "^   tank\b"; then
        if $SUDO zpool import tank; then
          echo "✓ Imported pool 'tank'"
        else
          echo "⚠ Could not import 'tank' automatically. If this pool was used on another system recently, you may need:"
          echo "   sudo zpool import -f tank"
        fi
      else
        echo "ℹ No exportable pool named 'tank' detected. Skipping."
      fi
    fi
  else
    echo "⚠ zpool command not found even after installing zfsutils-linux."
  fi

  echo "==> Installing Ollama…"
  # Official installer (creates/updates systemd service)
  # shellcheck disable=SC2312
  curl -fsSL https://ollama.com/install.sh | $SUDO sh
  if systemctl list-unit-files | grep -q '^ollama.service'; then
    $SUDO systemctl enable --now ollama || true
  fi

  echo "==> Installing Docker Engine + CLI + Compose plugin…"
  if docker_installed; then
    echo "✓ docker already installed ($(docker --version || true))"
  else
    # Remove conflicting packages if present (safe to run)
    $SUDO apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc || true

    # Add Docker's official APT repo
    $SUDO install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    source /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
      | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

    $SUDO apt-get update -y
    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Enable/start docker service
    $SUDO systemctl enable --now docker
  fi

  if docker_service_active; then
    echo "✓ docker service running"
  else
    echo "⚠ docker service is not active; attempting to start…"
    $SUDO systemctl start docker || true
  fi

  echo "==> Deploying Open WebUI (Docker)…"
  # Run Open WebUI on localhost:3000. Persist data to named volume 'open-webui'.
  # We explicitly set OLLAMA_BASE_URL and add the host.docker.internal alias for Linux.
  if docker_container_exists "open-webui"; then
    if docker_container_running "open-webui"; then
      echo "✓ open-webui container already running"
    else
      echo "ℹ Starting existing open-webui container…"
      $SUDO docker start open-webui
    fi
  else
    $SUDO docker run -d \
      -p 3000:8080 \
      --add-host=host.docker.internal:host-gateway \
      -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
      -v open-webui:/app/backend/data \
      --name open-webui \
      --restart=always \
      ghcr.io/open-webui/open-webui:main
    echo "✓ Open WebUI deployed at http://localhost:3000"
  fi

  echo "==> Installing GUI apps via snap (same as App Center)…"
  ensure_snapd
  snap_install_if_missing "pycharm-community" --classic
  snap_install_if_missing "chromium"
  snap_install_if_missing "mission-center"
  snap_install_if_missing "onlyoffice-desktopeditors"

  echo "==> All done."
  echo "• Open WebUI: http://localhost:3000"
  echo "• If you prefer not to use 'sudo docker', consider adding your user to the 'docker' group and re-login:"
  echo "    sudo usermod -aG docker \$USER"
}

main "$@"
