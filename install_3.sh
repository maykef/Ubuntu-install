#!/usr/bin/env bash
# Ubuntu targeted installer for:
# - system update/upgrade
# - zfsutils-linux + import pool 'tank'
# - curl
# - git
# - Ollama (official installer)
# - Pull Ollama model: qwen2.5:32b-instruct
# - Docker Engine + Compose plugin (no Docker Desktop)
# - Open WebUI (Docker container, host networking)
# - PyCharm Community, Chromium, Mission Center, ONLYOFFICE via snap

set -euo pipefail
trap 'echo "❌ Error on line $LINENO running: $BASH_COMMAND" >&2' ERR

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

wait_for_ollama() {
  echo "==> Waiting for Ollama API to be ready on http://127.0.0.1:11434 …"
  for _ in {1..30}; do
    if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
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

# ----------------------- steps -----------------------
main() {
  require_sudo
  have_internet || { echo "No internet connectivity detected. Aborting." >&2; exit 1; }

  echo "==> Updating system…"
  $SUDO apt-get update -y
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get upgrade -y

  echo "==> Installing base packages…"
  apt_install ca-certificates gnupg curl zfsutils-linux git

  echo "==> Importing ZFS pool 'tank' (if present)…"
  if command -v zpool >/dev/null 2>&1; then
    if zpool list -H -o name 2>/dev/null | grep -qx "tank"; then
      echo "✓ 'tank' already imported"
    else
      if zpool import 2>/dev/null | awk '/^  pool: /{print $2}' | grep -qx "tank"; then
        echo "ℹ Pool 'tank' is importable; attempting import…"
        if $SUDO zpool import tank 2>/dev/null; then
          echo "✓ Imported pool 'tank'"
        else
          echo "⚠ Standard import failed; trying forced import…"
          if $SUDO zpool import -f tank 2>/dev/null; then
            echo "✓ Imported pool 'tank' with -f"
          else
            echo "❗ Could not import 'tank'. Try manually: sudo zpool import -f tank"
          fi
        fi
      else
        echo "ℹ No exportable pool named 'tank' detected. Skipping."
      fi
    fi
  else
    echo "⚠ zpool command not found even after installing zfsutils-linux."
  fi

  echo "==> Installing Ollama…"
  curl -fsSL https://ollama.com/install.sh | $SUDO sh
  if systemctl list-unit-files | grep -q '^ollama.service'; then
    $SUDO systemctl enable --now ollama || echo "⚠ Could not enable/start ollama service (continuing)…"
  fi

  wait_for_ollama || true

  echo "==> Downloading Ollama model: qwen2.5:32b-instruct …"
  if ollama_model_present "qwen2.5:32b-instruct"; then
    echo "✓ Model already present"
  else
    if ! ollama pull qwen2.5:32b-instruct; then
      echo "⚠ Failed to pull 'qwen2.5:32b-instruct'. Try manually later with: ollama pull qwen2.5:32b-instruct"
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

    $SUDO systemctl enable --now docker || echo "⚠ Could not enable/start docker (continuing)…"
  fi

  if docker_service_active; then
    echo "✓ docker service running"
  else
    echo "⚠ docker service is not active; attempting to start…"
    $SUDO systemctl start docker || echo "❗ docker service did not start; check journalctl -u docker"
  fi

  echo "==> Deploying Open WebUI (Docker with host networking)…"
  if docker_container_exists "open-webui"; then
    if docker_container_running "open-webui"; then
      echo "✓ open-webui container already running"
    else
      echo "ℹ Starting existing open-webui container…"
      $SUDO docker start open-webui || echo "❗ Failed to start existing open-webui container"
    fi
  else
    $SUDO docker run -d \
      --name open-webui \
      --network=host \
      -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \
      -v open-webui:/app/backend/data \
      --restart=always \
      ghcr.io/open-webui/open-webui:main || echo "❗ Failed to run open-webui container"
    echo "✓ Open WebUI deployed at http://localhost:8080"
  fi

  echo "==> Installing GUI apps via snap (same as App Center)…"
  ensure_snapd
  snap_install_if_missing "pycharm-community" --classic
  snap_install_if_missing "chromium"
  snap_install_if_missing "mission-center"
  snap_install_if_missing "onlyoffice-desktopeditors"

  echo "==> All done."
  echo "• Open WebUI: http://localhost:8080"
  echo "• Pulled model: qwen2.5:32b-instruct (use from Open WebUI or 'ollama run qwen2.5:32b-instruct')"
  echo "• If you were added to any new system groups (e.g., docker), you may need to log out/in."
}

main "$@"
