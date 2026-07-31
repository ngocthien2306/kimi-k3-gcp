#!/usr/bin/env bash
# Cấu hình chung - source file này trước khi chạy các script khác.
# Sửa các giá trị dưới đây cho phù hợp với project của bạn.

export PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"

# Zone. 01-provision.sh tự thử lần lượt ZONE_CANDIDATES khi gặp
# ZONE_RESOURCE_POOL_EXHAUSTED (hay gặp với 16 GPU), rồi ghi zone thành công vào
# file .zone để các script khác dùng đúng zone đó.
# Mọi zone phải cùng REGION với bucket GCS thì transfer mới nhanh + free egress.
export ZONE_CANDIDATES="${ZONE_CANDIDATES:-us-central1-c us-central1-f us-central1-a us-central1-b}"

_ZONE_FILE="$(dirname "${BASH_SOURCE[0]}")/.zone"
if [ -f "$_ZONE_FILE" ]; then
  export ZONE="$(cat "$_ZONE_FILE")"
else
  export ZONE="${ZONE:-us-central1-c}"
fi
export REGION="${ZONE%-*}"

export VM_NAME="kimi-k3-vm"

# a2-megagpu-16g: 16x A100 40GB (640GB VRAM) + 96 vCPU + 1360GB RAM.
# 640GB VRAM > model 553GB -> TOÀN BỘ model nằm trong VRAM, bỏ được CPU offload
# (nút thắt lớn nhất: mỗi token phải kéo expert weights qua PCIe từ RAM).
# Quota PREEMPTIBLE_NVIDIA_A100_GPUS=64 đủ cho 16 GPU, không cần xin thêm.
#
# Máy cũ: a2-highgpu-8g (8x A100 40GB = 320GB VRAM) -> 233GB model phải ở CPU RAM.
# a2-ultragpu-8g / a3-highgpu-8g cũng đủ VRAM nhưng quota A100-80GB và H100 = 0.
export MACHINE_TYPE="a2-megagpu-16g"

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
