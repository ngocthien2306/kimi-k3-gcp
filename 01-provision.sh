#!/usr/bin/env bash
# Tạo hạ tầng: bucket lưu model + Spot VM.
# Chạy 1 lần. Các phiên sau chỉ cần 03-start-session.sh.
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "==> Project: $PROJECT_ID | Zone: $ZONE | Machine: $MACHINE_TYPE"

# --- 0. Preflight: check quota trước khi tạo, fail sớm với thông báo rõ ràng
echo "==> Kiểm tra quota"
QJSON=$(gcloud compute regions describe "$REGION" --format=json)
check_quota() {
  local metric="$1" need="$2"
  local limit
  limit=$(echo "$QJSON" | python3 -c "
import json,sys
qs=json.load(sys.stdin)['quotas']
print(next((q['limit'] for q in qs if q['metric']=='$metric'), 0))
")
  if (( $(echo "$limit < $need" | bc -l) )); then
    echo "  ✗ $metric = $limit (cần >= $need)" >&2
    return 1
  fi
  echo "  ✓ $metric = $limit"
}

MISSING=0
check_quota PREEMPTIBLE_NVIDIA_A100_GPUS 16   || MISSING=1
check_quota PREEMPTIBLE_CPUS 96               || MISSING=1

# KHÔNG check PREEMPTIBLE_LOCAL_SSD_GB ở đây: metric regional trong
# `gcloud compute regions describe` là API legacy và báo 0 sai lệch.
# Quota thật là ZONAL (PREEMPTIBLE-LOCAL-SSD-GB-per-project-zone), mặc định
# unlimited (-1, isFixed). Kiểm tra nếu cần:
#   gcloud beta quotas info describe PREEMPTIBLE-LOCAL-SSD-GB-per-project-zone \
#     --service=compute.googleapis.com --project=$PROJECT_ID

if [ "$MISSING" -eq 1 ]; then
  cat >&2 <<EOF

Thiếu quota. Xin tại: https://console.cloud.google.com/iam-admin/quotas?project=$PROJECT_ID
Lọc theo region "$REGION" và tìm đúng metric bị thiếu ở trên.
EOF
  exit 1
fi

# --- 1. Bucket lưu model (regional, cùng region với VM để transfer nhanh & free egress)
if ! gcloud storage buckets describe "$BUCKET" >/dev/null 2>&1; then
  echo "==> Tạo bucket $BUCKET"
  gcloud storage buckets create "$BUCKET" --location="$REGION" --uniform-bucket-level-access
else
  echo "==> Bucket $BUCKET đã tồn tại, bỏ qua"
fi

# --- 2. Spot VM
# --instance-termination-action=STOP : khi bị preempt thì STOP (không xoá VM),
#   giữ lại boot disk + config để start lại nhanh.
# --max-run-duration : chốt trần thời gian chạy, tránh quên tắt máy đốt tiền.
# --local-ssd x N : A2 Standard không kèm local SSD sẵn, phải gắn thủ công (375GiB/cái).
LOCAL_SSD_FLAGS=()
for _ in $(seq "$LOCAL_SSD_COUNT"); do
  LOCAL_SSD_FLAGS+=(--local-ssd=interface=NVME)
done

echo "==> Tạo Spot VM $VM_NAME ($MACHINE_TYPE + ${LOCAL_SSD_COUNT}x375GB local SSD)"
gcloud compute instances create "$VM_NAME" \
  --zone="$ZONE" \
  --machine-type="$MACHINE_TYPE" \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --discard-local-ssds-at-termination-timestamp=true \
  --max-run-duration=8h \
  --maintenance-policy=TERMINATE \
  --image-family=common-cu129-ubuntu-2204-nvidia-580 \
  --image-project=deeplearning-platform-release \
  --boot-disk-size=200GB \
  --boot-disk-type=pd-balanced \
  "${LOCAL_SSD_FLAGS[@]}" \
  --scopes=https://www.googleapis.com/auth/cloud-platform \
  --metadata="install-nvidia-driver=True"

echo
echo "==> Xong. Bước tiếp theo (setup một lần):"
echo "    gcloud compute scp 02-setup-vm.sh lib-mount-localssd.sh $VM_NAME:~/ --zone=$ZONE"
echo "    gcloud compute ssh $VM_NAME --zone=$ZONE"
echo "    # trên VM (nên chạy trong tmux):"
echo "    export BUCKET=$BUCKET QUANT=$QUANT"
echo "    bash ~/02-setup-vm.sh"
