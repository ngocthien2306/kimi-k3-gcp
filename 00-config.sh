#!/usr/bin/env bash
# Cấu hình chung - source file này trước khi chạy các script khác.
# Sửa các giá trị dưới đây cho phù hợp với project của bạn.

export PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
export ZONE="us-central1-a"
export REGION="${ZONE%-*}"

export VM_NAME="kimi-k3-vm"

# a2-highgpu-8g: 8x A100 40GB (320GB VRAM) + 96 vCPU + 680GB RAM = 1,000GB RAM+VRAM.
# Chọn máy này thay vì a2-ultragpu-4g (cùng tổng 1,000GB) vì project đã có sẵn
# quota PREEMPTIBLE_NVIDIA_A100_GPUS=64, trong khi quota A100 80GB = 0.
export MACHINE_TYPE="a2-highgpu-8g"

# A2 Standard KHÔNG kèm local SSD (khác a2-ultragpu) -> phải gắn thủ công.
# a2-highgpu-8g CHỈ chấp nhận đúng 0 hoặc 8 local SSD (không cho số lẻ khác).
# 8 x 375 GiB = 3 TB - dư sức chứa quant 594GB, kể cả Q8 lossless (1.56TB).
export LOCAL_SSD_COUNT=8

# Bucket lưu model (rẻ hơn nhiều so với để trên persistent disk)
export BUCKET="gs://${PROJECT_ID}-kimi-k3-models"

# Quant muốn dùng. LƯU Ý: repo Unsloth đã từng đổi tên thư mục quant
# (UD-IQ1_S <-> UD-IQ1_M <-> UD-IQ2_XXS), nên PHẢI verify tên thật trước khi tải.
# Xem: https://huggingface.co/unsloth/Kimi-K3-GGUF/tree/main
export QUANT="UD-IQ1_S"                    # ~594GB, cần ~610GB RAM+VRAM
export MMPROJ="mmproj-BF16.gguf"           # cần cho vision

# Unsloth Studio tự phát hiện model nằm trong HuggingFace cache.
# Đặt cache lên local SSD (1.5TB, đi kèm sẵn a2-ultragpu-4g) để Studio thấy được.
export HF_HOME="/mnt/localssd/hf"
export STUDIO_PORT="8888"        # port Studio chạy TRÊN VM
export LOCAL_PORT="${LOCAL_PORT:-8888}"  # port trên máy Mac (đổi nếu bị Jupyter chiếm)

# Cách cho người khác truy cập Unsloth Studio:
#   tunnel     - chỉ mình bạn, qua SSH tunnel (an toàn nhất, mặc định)
#   cloudflare - URL HTTPS công khai, ai có link + API key đều vào được
#   lan        - http://<IP-VM>:8888, cần chạy ./06-open-firewall.sh trước
# CẢNH BÁO: Studio cho phép chạy code trên VM. Mở công khai = ai có key
# cũng chạy được code trên máy 8x A100 của bạn. Giữ key cẩn thận.
export EXPOSE="${EXPOSE:-tunnel}"
