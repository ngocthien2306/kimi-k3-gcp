#!/usr/bin/env bash
# CHẠY TRÊN VM, một lần duy nhất.
# Cài Unsloth Studio + tải model vào HF cache -> backup lên GCS.
#
# Unsloth Studio đã bundle sẵn llama.cpp fork hỗ trợ Kimi K3,
# nên KHÔNG cần build llama.cpp từ source.
set -euo pipefail

BUCKET="${BUCKET:?export BUCKET=gs://... trước khi chạy}"
QUANT="${QUANT:-UD-IQ1_S}"
MMPROJ="${MMPROJ:-mmproj-BF16.gguf}"
export HF_HOME="${HF_HOME:-/mnt/localssd/hf}"

sudo apt-get update -qq
source "$(dirname "$0")/lib-mount-localssd.sh"
mount_localssd
mkdir -p "$HF_HOME"

# --- 1. Cài Unsloth Studio
echo "==> Cài Unsloth Studio"
curl -fsSL https://unsloth.ai/install.sh | sh

# Thêm HF_HOME vào bashrc để Studio luôn thấy đúng cache
grep -q 'HF_HOME' ~/.bashrc || echo "export HF_HOME=$HF_HOME" >> ~/.bashrc

# --- 2. Đảm bảo có HuggingFace CLI (`hf`)
# Image DLVM không phải lúc nào cũng có `pip` trên PATH -> dò lần lượt.
export PATH="$HOME/.local/bin:$PATH"

if ! command -v hf >/dev/null 2>&1; then
  echo "==> Cài huggingface_hub CLI"
  PIP=""
  for c in pip3 pip; do
    command -v "$c" >/dev/null 2>&1 && PIP="$c" && break
  done
  if [ -z "$PIP" ] && python3 -m pip --version >/dev/null 2>&1; then
    PIP="python3 -m pip"
  fi
  if [ -z "$PIP" ]; then
    sudo apt-get install -y -qq python3-pip
    PIP="python3 -m pip"
  fi
  $PIP install -q -U "huggingface_hub[cli]"
fi

command -v hf >/dev/null 2>&1 || { echo "LỖI: không tìm thấy lệnh 'hf'" >&2; exit 1; }
grep -q '.local/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

# --- 3. Tải model vào HF cache (KHÔNG dùng --local-dir, để Studio auto-detect)
echo "==> Tải quant $QUANT (~600GB, sẽ mất khá lâu)"
hf download unsloth/Kimi-K3-GGUF \
  --include "*${QUANT}*" --include "*${MMPROJ}*" \
  --max-workers 16

# --- 4. Backup HF cache lên GCS để các phiên sau khỏi tải lại từ HuggingFace
echo "==> Backup lên GCS: $BUCKET"
gcloud storage rsync -r "$HF_HOME/hub" "$BUCKET/hf-hub"

echo
echo "==> Setup xong. Thoát SSH và chạy 03-start-session.sh từ máy local."
