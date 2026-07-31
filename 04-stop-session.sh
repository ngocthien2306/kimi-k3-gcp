#!/usr/bin/env bash
# Kết thúc phiên - QUAN TRỌNG: luôn chạy khi dùng xong để không bị tính tiền GPU.
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "==> Stop VM $VM_NAME (ngừng tính phí GPU/vCPU/RAM)"
gcloud compute instances stop "$VM_NAME" --zone="$ZONE"

echo
echo "Chi phí còn lại khi VM đã stop:"
echo "  - Boot disk 200GB pd-balanced : ~\$20/tháng"
echo "  - Model trên GCS (~600GB)     : ~\$12/tháng"
echo "  - GPU/vCPU/RAM                : \$0 (đã stop)"
