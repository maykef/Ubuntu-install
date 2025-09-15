# Ollama + Open WebUI Installer for Ubuntu

This repository provides a one-shot installer script for setting up a complete **local AI environment** on Ubuntu, including:

- System update & upgrade  
- ZFS utilities (optional, imports pool `tank` if present)  
- Ollama (server + models)  
- Docker Engine, CLI, and Compose plugin  
- Open WebUI (running in Docker, bound to host networking)  
- GUI apps via Snap (PyCharm CE, Chromium, Mission Center, OnlyOffice)  

Open WebUI connects to your local Ollama server, giving you a browser-based interface to interact with large language models.  

---

## Requirements

- Ubuntu (20.04 or newer recommended)  
- Sudo privileges  
- Internet access  

---

## Installation

Clone this repo and run the installer:

```bash
git clone https://github.com/maykef/ollama-openwebui-setup.git
cd ollama-openwebui-setup
chmod +x install.sh
./install.sh
```

The script will:  
- Update your system  
- Install Ollama  
- Download the **Qwen2.5-32B Instruct** model  
- Install Docker  
- Deploy **Open WebUI** on port `8080`  

---

## Usage

### Start Ollama

```bash
sudo systemctl start ollama
```

Enable auto-start on boot:

```bash
sudo systemctl enable ollama
```

### Auto-loading a Model

By default, Ollama only starts the server. To automatically load your preferred model (e.g. `qwen2.5:32b-instruct`), create a **systemd service override**:

```bash
sudo systemctl edit ollama
```

Add the following under `[Service]`:

```ini
ExecStartPost=/usr/bin/ollama run qwen2.5:32b-instruct
```

Save, then reload systemd and restart Ollama:

```bash
sudo systemctl daemon-reexec
sudo systemctl restart ollama
```

Now, Ollama will auto-load the model whenever the service starts.

---

### Start Open WebUI

```bash
sudo docker start open-webui
```

Open your browser at:  
👉 http://localhost:8080

---

### Stop Open WebUI

```bash
sudo docker stop open-webui
```

### Stop Ollama

```bash
sudo systemctl stop ollama
```

---

## Managing Data

Open WebUI stores data in a Docker volume named `open-webui`.

- List volumes:

```bash
sudo docker volume ls
```

- Remove Open WebUI data (**irreversible**):

```bash
sudo docker volume rm open-webui
```

---

## Logs & Debugging

- **Ollama logs**:

```bash
journalctl -u ollama -f
```

- **Open WebUI logs**:

```bash
sudo docker logs -f open-webui
```

- **Check port usage**:

```bash
sudo ss -lntp | grep :8080
```

---

## Uninstall

To remove Open WebUI and Ollama:

```bash
# Stop and remove Open WebUI container
sudo docker rm -f open-webui

# Remove its volume (data)
sudo docker volume rm open-webui

# Remove the image
sudo docker rmi ghcr.io/open-webui/open-webui:main

# Stop and disable Ollama
sudo systemctl stop ollama
sudo systemctl disable ollama

# Optionally uninstall packages
sudo apt-get remove --purge -y docker-ce docker-ce-cli containerd.io ollama zfsutils-linux
```

---

## License

MIT License – do what you want, but no guarantees.
