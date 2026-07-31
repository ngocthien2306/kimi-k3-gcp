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

# a2-ultragpu-8g: 8x A100 80GB (640GB VRAM) + 96 vCPU + 1360GB RAM.
# 640GB VRAM > model 553GB -> TOÀN BỘ model trong VRAM, bỏ được CPU offload.
# Chỉ 8 GPU nên ít khan hiếm hơn 16x A100 40GB -> rủi ro preempt thấp hơn.
# (Quota A100-80GB đã xin và được duyệt = 8, ngày 2026-07-31.)
#
# LỊCH SỬ ĐÃ THỬ:
#  - a2-highgpu-8g  (8x A100 40GB = 320GB VRAM): chạy ỔN ĐỊNH > 1 tiếng, nhưng
#    ~233GB expert weights phải ở CPU RAM -> mỗi token kéo qua PCIe, CHẬM.
#  - a2-megagpu-16g (16x A100 40GB = 640GB VRAM): đủ VRAM nhưng Spot bị preempt
#    sau ~18 PHÚT, không kịp restore (~10 phút) + load model. Quá khan hiếm.
#
# Nếu a2-ultragpu-8g cũng hay bị preempt -> quay lại a2-highgpu-8g (chậm mà chắc),
# hoặc dùng on-demand (quota on-demand A100-80GB cũng đã có = 8).
export MACHINE_TYPE="a2-ultragpu-8g"

# a2-ultragpu ĐÃ KÈM SẴN local SSD -> đặt 0, KHÔNG gắn thủ công.
# (Chỉ A2 Standard như a2-highgpu-8g mới cần gắn tay, và chỉ nhận đúng 0 hoặc 8.)
export LOCAL_SSD_COUNT=0

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
