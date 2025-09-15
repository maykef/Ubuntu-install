#!/usr/bin/env bash

# Ubuntu targeted installer for:
# - system update/upgrade
# - zfsutils-linux + import pool 'tank'
# - curl
# - git
# - Ollama (official installer)
# - Pull Ollama model: qwen2.5:32b-instruct
# - Docker Engine + CLI + Compose plugin
# - Deploy Open WebUI (Docker)
# - Install GUI apps via snap

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

wait_for_ollama() {
  echo "==> Waiting for Ollama API to be ready on http://localhost:11434 …"
  for i in {1..30}; do
    if curl -fsS http://localhost:11434/api/tags >/dev/null 2>&1; then
      echo "✓ Ollama is ready"
      return 0
    fi
    sleep 1
  done
  echo "⚠ Ollama API did not respond in time; continuing anyway."
  return 1
}

ollama_model_present() {
  local model="$1"
  ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$model"
}

# ---------- FIX #1: robust ZFS import ----------
import_zfs_tank() {
  echo "==> Importing ZFS pool 'tank' (if present)…"
  if command -v zpool >/dev/null 2>&1; then
    $SUDO modprobe zfs || true

    if zpool list -H -o name 2>/dev/null | grep -qx "tank"; then
      echo "✓ 'tank' already imported"
      return
    fi

    if zpool import 2>/dev/null | awk '/^[[:space:]]*pool:[[:space:]]+/{print $2}' | grep -qx "tank"; then
      if $SUDO zpool import tank 2>/dev/null || $SUDO zpool import -f tank 2>/dev/null; then
        echo "✓ Imported pool 'tank'"
      else
        echo "⚠ Could not import 'tank' automatically."
        echo "   Try manually with: sudo zpool import -f tank"
      fi
    else
      echo "ℹ No exportable pool named 'tank' detected. Skipping."
    fi
  else
    echo "⚠ zpool command not found even after installing zfsutils-linux."
  fi
}

# ---------- FIX #2: Docker DNS fallback ----------
ensure_docker_dns() {
  echo "==> Checking DNS resolution for ghcr.io…"
  if getent ahosts ghcr.io >/dev/null 2>&1; then
    echo "✓ DNS resolution for ghcr.io is OK"
    return 0
  fi

  echo "⚠ DNS lookup for ghcr.io failed via systemd-resolved (127.0.0.53)."
  echo "   Applying Docker-specific DNS fallback…"

  $SUDO install -d -m 0755 /etc/docker
  if [[ -f /etc/docker/daemon.json ]]; then
    if grep -q '"dns"' /etc/docker/daemon.json; then
      $SUDO sed -i 's/"dns"[[:space:]]*:[[:space:]]*\[[^]]*\]/"dns": ["1.1.1.1","1.0.0.1","8.8.8.8","8.8.4.4"]/' /etc/docker/daemon.json
    else
      $SUDO sed -i 's/}[[:space:]]*$/,\n  "dns": ["1.1.1.1","1.0.0.1","8.8.8.8","8.8.4.4"]\n}/' /etc/docker/daemon.json
    fi
  else
    cat <<'JSON' | $SUDO tee /etc/docker/daemon.json >/dev/null
{
  "dns": ["1.1.1.1","1.0.0.1","8.8.8.8","8.8.4.4"]
}
JSON
  fi

  $SUDO systemctl restart docker
  sleep 1

  if getent ahosts ghcr.io >/dev/null 2>&1; then
    echo "✓ DNS resolution for ghcr.io is OK after fallback"
    return 0
  else
    echo "⚠ DNS still failing. Check your network or set global DNS in /etc/systemd/resolved.conf."
    return 1
  fi
}

prepull_openwebui_image() {
  local image="ghcr.io/open-webui/open-webui:main"
  echo "==> Pre-pulling image ${image} …"
  if $SUDO docker pull "$image"; then
    echo "✓ Pulled ${image}"
    return 0
  fi
  echo "⚠ First pull failed; retrying after DNS fix…"
  ensure_docker_dns || true
  $SUDO docker pull "$image" || return 1
}

main() {
  require_sudo
  have_internet || { echo "No internet connectivity detected. Aborting." >&2; exit 1; }

  echo "==> Updating system…"
  $SUDO apt-get update -y
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get upgrade -y

  echo "==> Installing base packages…"
  apt_install ca-certificates gnupg curl zfsutils-linux git

  import_zfs_tank

  echo "==> Installing Ollama…"
  curl -fsSL https://ollama.com/install.sh | $SUDO sh
  if systemctl list-unit-files | grep -q '^ollama.service'; then
    $SUDO systemctl enable --now ollama || true
  fi
  wait_for_ollama || true

  echo "==> Downloading Ollama model: qwen2.5:32b-instruct …"
  if ollama_model_present "qwen2.5:32b-instruct"; then
    echo "✓ Model already present"
  else
    if ! ollama pull qwen2.5:32b-instruct; then
      echo "⚠ Failed to pull 'qwen2.5:32b-instruct'. Retry later with:"
      echo "   ollama pull qwen2.5:32b-instruct"
    fi
  fi

  echo "==> Installing Docker Engine + CLI + Compose plugin…"
  if docker_installed; then
    echo "✓ docker already installed ($(docker --version || true))"
  else
    $SUDO apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc || true
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
    $SUDO systemctl enable --now docker
  fi

  if docker_service_active; then
    echo "✓ docker service running"
  else
    echo "⚠ docker service is not active; attempting to start…"
    $SUDO systemctl start docker || true
  fi

  echo "==> Deploying Open WebUI (Docker)…"
  ensure_docker_dns || true
  prepull_openwebui_image || true

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

  echo "==> Installing GUI apps via snap…"
  ensure_snapd
  snap_install_if_missing "pycharm-community" --classic
  snap_install_if_missing "chromium"
  snap_install_if_missing "mission-center"
  snap_install_if_missing "onlyoffice-desktopeditors"

  echo "==> All done."
  echo "• Open WebUI: http://localhost:3000"
  echo "• Pulled model: qwen2.5:32b-instruct"
  echo "• If you were added to new groups (e.g., docker), log out/in."
}

main "$@"
