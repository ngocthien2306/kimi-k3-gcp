#!/usr/bin/env bash
# Kết thúc phiên - QUAN TRỌNG: luôn chạy khi dùng xong để không bị tính tiền GPU.
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "==> Stop VM $VM_NAME (ngừng tính phí GPU/vCPU/RAM)"
# --discard-local-ssd=true BẮT BUỘC khi VM có local SSD (gcloud không cho mặc định).
#   true  = xoá dữ liệu local SSD -> phiên sau kéo lại model từ GCS (~10-20 phút)
#   false = giữ lại, nhưng VẪN TÍNH TIỀN 3TB local SSD (~$240/tháng) lúc VM tắt
#           -> đắt hơn nhiều so với để model trên GCS (~$12/tháng)
gcloud compute instances stop "$VM_NAME" --zone="$ZONE" --discard-local-ssd=true

echo
echo "Chi phí còn lại khi VM đã stop:"
echo "  - Boot disk 200GB pd-balanced : ~\$20/tháng"
echo "  - Model trên GCS (~600GB)     : ~\$12/tháng"
echo "  - Local SSD 3TB               : \$0 (đã discard)"
echo "  - GPU/vCPU/RAM                : \$0 (đã stop)"
