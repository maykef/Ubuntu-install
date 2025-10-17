#!/bin/bash

################################################################################
# setup_imaging_pipeline.sh (FIXED)
#
# Lightsheet Microscopy Image Processing Pipeline – Full Installer
# FIXED: Uses PyTorch nightly cu128 (matches llm-inference setup for Blackwell)
#
# Usage: bash setup_imaging_pipeline.sh
################################################################################

set -euo pipefail
IFS=$'\n\t'

# ----------------------------------- Logging -----------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# --------------------------------- Guardrails ----------------------------------
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  log_error "Do not run as root/sudo."
  exit 1
fi

# --------------------------------- Pre-Flight ---------------------------------
log_info "Lightsheet Imaging Pipeline Setup (FIXED - PyTorch nightly cu128)"
echo ""

# Initialize mamba in current shell with faster solver
log_info "Initializing mamba…"
MINIFORGE_HOME="$HOME/miniforge3"
if [ -d "$MINIFORGE_HOME" ]; then
  eval "$("$MINIFORGE_HOME/bin/mamba" shell hook --shell bash)"
  # Use libmamba solver (faster than classic)
  export CONDA_SOLVER=libmamba
else
  log_error "Miniforge not found at $MINIFORGE_HOME. Run setup_llm_core.sh first."
  exit 1
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  log_error "nvidia-smi not found. Install NVIDIA drivers first."
  exit 1
fi

GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 || echo "Unknown GPU")"
GPU_MEMORY="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -1 || echo "N/A")"
log_info "GPU detected: ${GPU_NAME} (${GPU_MEMORY})"

AVAILABLE_SPACE_KB=$(df -k "$HOME" | tail -1 | awk '{print $4}')
REQUIRED_SPACE_KB=$((20 * 1024 * 1024))  # 20GB
if [ "$AVAILABLE_SPACE_KB" -lt "$REQUIRED_SPACE_KB" ]; then
  log_error "Insufficient disk space. Need >= 20 GB free in $HOME."
  exit 1
fi

log_success "Pre-flight checks passed!"
echo ""

read -p "Continue with installation? (y/N): " -n 1 -r; echo
[[ $REPLY =~ ^[Yy]$ ]] || { log_info "Installation cancelled."; exit 0; }

# ------------------------------ PHASE 1: Miniforge -----------------------------
log_info "PHASE 1: Checking for Miniforge…"
MINIFORGE_HOME="$HOME/miniforge3"

if [ -d "$MINIFORGE_HOME" ]; then
  log_success "Miniforge found at $MINIFORGE_HOME"
elif command -v mamba >/dev/null 2>&1; then
  log_success "Mamba available in PATH"
else
  log_warning "Miniforge not found. Installing…"
  INST="/tmp/Miniforge3-Linux-x86_64.sh"
  URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh"
  [ -f "$INST" ] || wget -O "$INST" "$URL" --progress=bar:force 2>&1
  bash "$INST" -b -p "$MINIFORGE_HOME"
  log_success "Miniforge installed."
fi
echo ""

# ------------------------------ PHASE 2: Init mamba ----------------------------
log_info "PHASE 2: Initializing mamba…"
export MAMBA_ROOT_PREFIX="$MINIFORGE_HOME"
eval "$("$MINIFORGE_HOME/bin/mamba" shell hook --shell bash)"

# Persist shell init (work across mamba versions; never fail hard)
set +e
if "$MINIFORGE_HOME/bin/mamba" shell init -h 2>&1 | grep -q -- '--prefix'; then
  "$MINIFORGE_HOME/bin/mamba" shell init -s bash --prefix "$MINIFORGE_HOME" >/dev/null 2>&1 || true
else
  "$MINIFORGE_HOME/bin/mamba" shell init -s bash >/dev/null 2>&1 || true
fi
"$MINIFORGE_HOME/bin/conda" init bash >/dev/null 2>&1 || true
set -e
source ~/.bashrc 2>/dev/null || true

command -v mamba >/dev/null 2>&1 || { log_error "Mamba initialization failed."; exit 1; }
log_success "Mamba: $(mamba --version)"
echo ""

# --------------------------- PHASE 3: Create environment -----------------------
log_info "PHASE 3: Creating imaging_pipeline environment…"

if mamba env list | grep -qE '^\s*imaging_pipeline\s'; then
  log_warning "imaging_pipeline exists. Removing…"
  mamba env remove -n imaging_pipeline -y
fi

if [ -f "environment_imaging.yml" ]; then
  log_info "Creating from environment_imaging.yml…"
  mamba env create -f environment_imaging.yml --yes
else
  log_info "No YAML found. Creating minimal env…"
  mamba create -n imaging_pipeline python=3.11 pip numpy scipy scikit-image scikit-learn pandas matplotlib -y
fi

log_success "Base environment created."
echo ""

# -------- PHASE 4: Install stack (conda-forge) + PyTorch NIGHTLY cu128 --
log_info "PHASE 4: Installing imaging packages…"
eval "$("$MINIFORGE_HOME/bin/mamba" shell hook --shell bash)"
mamba activate imaging_pipeline

# (A) Install in stages to identify what's hanging
log_info "Installing core scientific stack…"
mamba install -y -c conda-forge \
  "numpy>=1.24.0,<2.0.0" \
  "scipy>=1.10.0" \
  "pandas>=2.0.0" \
  "matplotlib>=3.7.0"

log_info "Installing image processing…"
mamba install -y -c conda-forge \
  "scikit-image>=0.22.0" \
  "scikit-learn>=1.3.0" \
  aicspylibczi czifile imagecodecs

log_info "Installing registration & storage…"
mamba install -y -c conda-forge \
  simpleitk \
  "zarr>=2.16.0,<3.0.0" \
  ome-zarr

log_info "Installing parallelization…"
mamba install -y -c conda-forge \
  "dask>=2024.2.0" \
  dask-image

log_info "Installing visualization…"
mamba install -y -c conda-forge \
  napari pyqt

log_info "Installing analysis & utilities…"
mamba install -y -c conda-forge \
  "tifffile>=2021.8.30,<2023.3.15" \
  "xarray>=0.16.1,<2023.02.0" \
  "toolz>=0.11.0" \
  opencv openpyxl seaborn numpy-stl

log_success "Conda packages installed."
echo ""

# (B) PyTorch nightly cu128 (MATCHING llm-inference setup for Blackwell)
log_info "Installing PyTorch 2.10 nightly with CUDA 12.8 (Blackwell support)…"
log_warning "This downloads ~5GB, may take 5-10 minutes…"

# Remove any existing torch trio first (conda or pip)
mamba remove -y pytorch torchvision torchaudio || true
python -m pip uninstall -y torch torchvision torchaudio || true
python -m pip cache purge || true

# Install matching-date nightly cu128 in ONE transaction (critical for alignment)
# Use verbose output to show progress
python -m pip install --upgrade --pre --force-reinstall -v \
  --index-url https://download.pytorch.org/whl/nightly/cu128 \
  torch torchvision torchaudio

log_success "PyTorch nightly cu128 installed (Blackwell support)."
echo ""

# (C) Minimal pip for imaging-specific packages
log_info "Installing cellpose and napari plugins…"
log_warning "Cellpose is ~200MB, napari-aicsimageio is ~20MB…"

python -m pip install --no-build-isolation --no-deps -v \
  "cellpose==3.0.8" \
  "napari-aicsimageio==0.7.2"

log_success "Cellpose and plugins installed."
echo ""

# (D) Cellpose runtime deps (explicit) + dependency fixes
mamba install -y -c conda-forge fastremap numba natsort tqdm roifile

# (E) FIX dependency conflicts after pip installations
log_info "Fixing dependency conflicts…"
# Reinstall pandas/numpy with proper constraints
pip install --force-reinstall --no-deps pandas>=2.0.0
pip install --force-reinstall --no-deps 'numpy>=1.24.0,<2.0.0'
pip install --force-reinstall --no-deps 'toolz>=0.11.0'

log_success "All imaging packages installed & dependencies fixed."
echo ""

# -------------------------------- PHASE 5: Verify ------------------------------
log_info "PHASE 5: Verifying installation…"
eval "$("$MINIFORGE_HOME/bin/mamba" shell hook --shell bash)"
mamba activate imaging_pipeline

python << 'EOF'
import sys, importlib, warnings
warnings.filterwarnings("ignore", category=UserWarning, module="torch.cuda")

checks = {
    'aicspylibczi': 'CZI I/O',
    'SimpleITK':    'Registration',
    'zarr':         'Storage',
    'cellpose':     'Segmentation',
    'napari':       'Visualization',
    'torch':        'Deep Learning',
    'pandas':       'Analysis',
    'fastremap':    'Cellpose dep',
}
failed=[]
for lib, desc in checks.items():
    try:
        importlib.import_module(lib)
        print(f"✓ {lib:20} ({desc})")
    except Exception as e:
        print(f"✗ {lib:20} ({desc}) - {e}")
        failed.append(lib)

print("\n" + "="*60)
print("GPU Status (Blackwell):")
print("="*60)
try:
    import torch
    print(f"  PyTorch version: {torch.__version__}")
    print(f"  CUDA available: {torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"  GPU: {torch.cuda.get_device_name(0)}")
        props = torch.cuda.get_device_properties(0)
        print(f"  VRAM: {props.total_memory/1e9:.1f} GB")
        try:
            cap = torch.cuda.get_device_capability(0)
            print(f"  Compute capability: sm_{cap[0]}{cap[1]}")
            if cap[0] >= 12:
                print(f"  ✓ Blackwell GPU support confirmed!")
        except Exception:
            pass
        # Test CUDA matmul
        print(f"  Testing CUDA kernels…")
        a = torch.randn(512,512, device="cuda"); b = torch.randn(512,512, device="cuda")
        c = a @ b
        print(f"  ✓ CUDA matmul OK (shape={tuple(c.shape)}, device=cuda)")
    else:
        print("  ✗ CUDA NOT AVAILABLE - GPU support FAILED!")
        failed.append("CUDA")
except Exception as e:
    print(f"  ✗ PyTorch check failed: {e}")
    failed.append("PyTorch")

print()
if failed:
    print(f"⚠ {len(failed)} check(s) failed: {', '.join(failed)}")
    sys.exit(1)
else:
    print("✅ All packages verified! GPU support active.")
EOF
echo ""

# ------------------------------- PHASE 6: Workspace ----------------------------
log_info "PHASE 6: Setting up workspace…"
mkdir -p "$HOME/imaging-workspace"/{configs,scripts,notebooks,example_data,logs}
sudo mkdir -p /scratch/imaging/{raw,stitched,deconvolved,segmented,analysis,cache} 2>/dev/null || true
sudo chown -R "$USER":"$USER" /scratch/imaging 2>/dev/null || true

cat > "$HOME/imaging-workspace/configs/pipeline_config.yaml" << 'CONFIG'
# Lightsheet Imaging Pipeline Configuration
imaging:
  input_dir: /tmp/dataset1
  output_base: /scratch/imaging
  czi:
    z_step_microns: 0.5
    tile_overlap_percent: 15
    background_subtraction: true

registration:
  method: "cross_correlation"
  max_iterations: 100

deconvolution:
  enabled: true
  iterations: 20

segmentation:
  cellpose_model: "nuclei"
  cellpose_diameter: 30
  gpu_enabled: true
  batch_size: 4

hardware:
  n_workers: 16
  max_memory_gb: 60
CONFIG

log_success "Workspace created at ~/imaging-workspace"
echo ""

# ----------------------------- PHASE 7: Helper scripts -------------------------
log_info "PHASE 7: Creating helper scripts…"

cat > "$HOME/start-imaging-pipeline.sh" << 'HELPER'
#!/bin/bash
echo "🔬 Lightsheet Imaging Pipeline"
eval "$("$HOME/miniforge3/bin/mamba" shell hook --shell bash)"
mamba activate imaging_pipeline
echo "✓ Environment: imaging_pipeline"
echo "✓ Workspace: ~/imaging-workspace"
echo "✓ Data: /scratch/imaging"
python - << 'PY'
import warnings, torch
warnings.filterwarnings("ignore", category=UserWarning, module="torch.cuda")
print(f"✓ PyTorch: {torch.__version__} | CUDA: {torch.cuda.is_available()}")
if torch.cuda.is_available():
    print(f"✓ GPU: {torch.cuda.get_device_name(0)} | Capability: {torch.cuda.get_device_capability(0)}")
PY
bash
HELPER
chmod +x "$HOME/start-imaging-pipeline.sh"

cat > "$HOME/switch-to-imaging.sh" << 'SWITCH'
#!/bin/bash
eval "$("$HOME/miniforge3/bin/mamba" shell hook --shell bash)"
mamba activate imaging_pipeline
bash
SWITCH
chmod +x "$HOME/switch-to-imaging.sh"

log_success "Helper scripts created"
echo ""

# ------------------------------ PHASE 8: Final checks --------------------------
log_info "PHASE 8: Final verification…"
log_success "Available environments:"
mamba env list | grep -E "^(base|imaging_pipeline|llm-inference)" || true

python - << 'EOF'
try:
    from aicspylibczi import CziFile
    print('✓ CZI I/O (aicspylibczi import ok)')
except Exception as e:
    print(f'⚠ aicspylibczi quick check failed: {e}')
try:
    from cellpose.core import use_gpu
    gpu_ok = use_gpu()
    print(f'✓ Cellpose GPU support: {gpu_ok}')
except Exception as e:
    print(f'⚠ Cellpose quick check failed: {e}')
EOF

echo ""
log_success "=========================================="
log_success "  IMAGING PIPELINE READY!"
log_success "=========================================="
echo ""

log_info "Installation Summary:"
echo "  ✓ imaging_pipeline environment created (Python 3.11)"
echo "  ✓ Imaging libs installed via conda-forge"
echo "  ✓ PyTorch 2.10 NIGHTLY cu128 (Blackwell GPU support)"
echo "  ✓ Cellpose 3.0.8 (pinned for stability)"
echo "  ✓ Workspace at ~/imaging-workspace"
echo "  ✓ GPU CUDA kernels verified with matmul test"
echo "  ✓ Separate from llm-inference (no conflicts)"
echo ""

cat > "$HOME/imaging-pipeline-install.log" << LOG
Imaging Pipeline Installation Log (FIXED)
Date: $(date)
User: $USER
Environment: imaging_pipeline
GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
PyTorch: $(python -c 'import torch; print(torch.__version__)' 2>/dev/null)
CUDA: $(python -c 'import torch; print(torch.version.cuda)' 2>/dev/null)
Compute Capability: $(python -c 'import torch; cap = torch.cuda.get_device_capability(0); print(f"sm_{cap[0]}{cap[1]}")' 2>/dev/null)
Blackwell Support: ENABLED
LOG

log_success "Installation log: ~/imaging-pipeline-install.log"
log_info "Next steps:"
echo "  1. Activate: mamba activate imaging_pipeline"
echo "  2. Or use:   ~/start-imaging-pipeline.sh"
echo "  3. Download test data from Dryad (optional)"
echo "  4. Create MVP stitcher script"
echo ""
log_success "READY FOR LIGHTSHEET IMAGE PROCESSING! 🚀"
