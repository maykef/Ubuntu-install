#!/usr/bin/env bash

# Ubuntu targeted installer for:
# - system update/upgrade
# - zfsutils-linux + import pool 'tank'
# - curl
# - git
# - Ollama (official installer)
# - Pull Ollama model: qwen2.5:32b-instruct
# - Docker Engine + CLI + Compose plugin
# - Deploy Open WebUI (Docker, host networking to reach local Ollama)
# - Install GUI apps via snap
#
# DNS note:
# Docker daemon uses the host's /etc/resolv.conf (at daemon start) to resolve registries.
# This script ensures host-level DNS is sane so pulls from ghcr.io succeed, *then*
# optionally sets container-level DNS in /etc/docker/daemon.json for consistency.

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
  echo "==> Waiting for Ollama API to be ready on http://127.0.0.1:11434 …"
  for i in {1..60}; do
    if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
      echo "✓ Ollama is ready"
      return 0
    fi
    sleep 1
  done
  echo "⚠ Ollama API did not respond in time; continuing anyway."
  return 1
}

wait_for_webui() {
  # With host networking, Open WebUI listens on 8080 by default.
  local url="http://127.0.0.1:8080"
  echo "==> Waiting for Open WebUI to be reachable at ${url} …"
  for i in {1..60}; do
    if curl -fsS "${url}/" >/dev/null 2>&1; then
      echo "✓ Open WebUI is reachable"
      return 0
    fi
    sleep 1
  done
  echo "⚠ Open WebUI did not become reachable in time; continuing."
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

# ---------- FIX #2: DNS for Docker pulls (host-level + container-level) ----------
resolved_is_active() {
  systemctl is-active --quiet systemd-resolved
}

ensure_host_dns_upstreams() {
  if command -v resolvectl >/dev/null 2>&1 || systemctl list-unit-files | grep -q '^systemd-resolved.service'; then
    $SUDO install -m 0644 -D /dev/null /etc/systemd/resolved.conf || true
    if ! grep -q '^\[Resolve\]' /etc/systemd/resolved.conf 2>/dev/null; then
      echo '[Resolve]' | $SUDO tee /etc/systemd/resolved.conf >/dev/null
    fi
    if grep -q '^DNS=' /etc/systemd/resolved.conf; then
      $SUDO sed -i 's/^DNS=.*/DNS=1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4/' /etc/systemd/resolved.conf
    else
      echo 'DNS=1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4' | $SUDO tee -a /etc/systemd/resolved.conf >/dev/null
    fi
    if grep -q '^FallbackDNS=' /etc/systemd/resolved.conf; then
      $SUDO sed -i 's/^FallbackDNS=.*/FallbackDNS=9.9.9.9 149.112.112.112/' /etc/systemd/resolved.conf
    else
      echo 'FallbackDNS=9.9.9.9 149.112.112.112' | $SUDO tee -a /etc/systemd/resolved.conf >/dev/null
    fi
    if grep -q '^DNSStubListener=' /etc/systemd/resolved.conf; then
      $SUDO sed -i 's/^DNSStubListener=.*/DNSStubListener=yes/' /etc/systemd/resolved.conf
    else
      echo 'DNSStubListener=yes' | $SUDO tee -a /etc/systemd/resolved.conf >/dev/null
    fi

    $SUDO systemctl enable --now systemd-resolved || true

    if [ -L /etc/resolv.conf ]; then
      target="$(readlink -f /etc/resolv.conf || true)"
      if [ "$target" != "/run/systemd/resolve/resolv.conf" ]; then
        $SUDO ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
      fi
    else
      $SUDO mv -f /etc/resolv.conf /etc/resolv.conf.backup.$(date +%s) 2>/dev/null || true
      $SUDO ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi

    $SUDO systemctl restart systemd-resolved
    sleep 1
  else
    if ! grep -Eq 'nameserver (1\.1\.1\.1|8\.8\.8\.8)' /etc/resolv.conf 2>/dev/null; then
      echo "nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:2 rotate" | $SUDO tee /etc/resolv.conf >/dev/null
    fi
  fi
}

test_host_dns() {
  getent ahosts "$1" >/dev/null 2>&1
}

ensure_docker_dns() {
  local test_host="ghcr.io"
  echo "==> Checking host DNS resolution for ${test_host} …"
  if test_host_dns "$test_host"; then
    echo "✓ Host DNS can resolve ${test_host}"
  else
    echo "⚠ Host DNS cannot resolve ${test_host}; fixing host DNS…"
    ensure_host_dns_upstreams
    if ! test_host_dns "$test_host"; then
      echo "⚠ DNS still failing at host level. Check your uplink/DHCP or firewall."
    else
      echo "✓ Host DNS fixed"
    fi
  fi

  $SUDO systemctl restart docker || true
  sleep 1

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

  $SUDO systemctl restart docker || true
  sleep 1

  if command -v curl >/dev/null 2>&1; then
    curl -fsSI https://ghcr.io/ >/dev/null 2>&1 && echo "✓ Reached ghcr.io over HTTPS" || echo "⚠ HTTPS reachability test failed (but DNS may now be OK)"
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

deploy_openwebui_hostnet() {
  # Use host networking so the container can reach the local Ollama at 127.0.0.1:11434
  local name="open-webui"
  local image="ghcr.io/open-webui/open-webui:main"
  local url="http://127.0.0.1:8080"

  echo "==> Ensuring no conflicting '${name}' container is running…"
  $SUDO docker rm -f "${name}" >/dev/null 2>&1 || true

  echo "==> Starting ${name} with host networking…"
  $SUDO docker run -d \
    --name "${name}" \
    --network=host \
    -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \
    -v open-webui:/app/backend/data \
    --restart=always \
    "${image}"

  wait_for_webui || true

  echo "✓ Open WebUI deployed at ${url}"
  echo "   (Host networking: UI on :8080; connects to Ollama on 127.0.0.1:11434)"
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
  # Make sure Ollama is up before we launch the UI (prevents "no models" confusion)
  wait_for_ollama || true
  deploy_openwebui_hostnet

  echo "==> Installing GUI apps via snap…"
  ensure_snapd
  snap_install_if_missing "pycharm-community" --classic
  snap_install_if_missing "chromium"
  snap_install_if_missing "mission-center"
  snap_install_if_missing "onlyoffice-desktopeditors"

  echo "==> All done."
  echo "• Open WebUI: http://localhost:8080"
  echo "• Ollama API:  http://127.0.0.1:11434"
  echo "• Pulled model: qwen2.5:32b-instruct"
  echo "• If you were added to new groups (e.g., docker), log out/in."
}

main "$@"
