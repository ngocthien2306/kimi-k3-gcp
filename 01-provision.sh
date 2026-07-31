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

# Quota GPU tuỳ machine type: ultragpu dùng A100 80GB, highgpu/megagpu dùng A100 40GB
case "$MACHINE_TYPE" in
  *ultragpu*) GPU_QUOTA="PREEMPTIBLE_NVIDIA_A100_80GB_GPUS" ;;
  *)          GPU_QUOTA="PREEMPTIBLE_NVIDIA_A100_GPUS" ;;
esac
GPU_NEED="${MACHINE_TYPE##*-}"; GPU_NEED="${GPU_NEED%g}"   # a2-ultragpu-8g -> 8

MISSING=0
check_quota "$GPU_QUOTA" "$GPU_NEED"          || MISSING=1
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
#   a2-ultragpu ĐÃ có sẵn -> LOCAL_SSD_COUNT=0, mảng rỗng.
LOCAL_SSD_FLAGS=()
if [ "${LOCAL_SSD_COUNT:-0}" -gt 0 ]; then
  for _ in $(seq "$LOCAL_SSD_COUNT"); do
    LOCAL_SSD_FLAGS+=(--local-ssd=interface=NVME)
  done
  SSD_NOTE="+ ${LOCAL_SSD_COUNT}x375GB local SSD"
else
  SSD_NOTE="(local SSD kèm sẵn theo machine type)"
fi

# GPU Spot hay dính ZONE_RESOURCE_POOL_EXHAUSTED -> thử lần lượt nhiều zone.
# Nhưng KHÔNG phải zone nào cũng có machine type (vd a2-ultragpu-8g chỉ có ở
# us-central1-a và -c) -> hỏi GCP xem zone nào thực sự hỗ trợ, thay vì đoán.
echo "==> Tìm zone hỗ trợ $MACHINE_TYPE trong $REGION"
SUPPORTED=$(gcloud compute machine-types list \
  --filter="name=$MACHINE_TYPE AND zone~^$REGION" \
  --format="value(zone)" 2>/dev/null | tr '\n' ' ')

if [ -z "$SUPPORTED" ]; then
  echo "LỖI: $MACHINE_TYPE không có ở region $REGION." >&2
  echo "     Các zone có machine type này:" >&2
  gcloud compute machine-types list --filter="name=$MACHINE_TYPE" \
    --format="value(zone)" 2>/dev/null | sed 's/^/       /' >&2
  exit 1
fi
echo "    zone hỗ trợ: $SUPPORTED"

# Ưu tiên $ZONE trước, rồi tới thứ tự trong ZONE_CANDIDATES, cuối cùng là phần còn lại
TRY_ZONES=""
for z in $ZONE $ZONE_CANDIDATES $SUPPORTED; do
  case " $SUPPORTED " in *" $z "*) ;; *) continue ;; esac   # bỏ zone không hỗ trợ
  case " $TRY_ZONES " in *" $z "*) continue ;; esac         # bỏ trùng
  TRY_ZONES="$TRY_ZONES $z"
done

CREATED_ZONE=""
for z in $TRY_ZONES; do

  echo "==> Thử tạo Spot VM $VM_NAME ($MACHINE_TYPE $SSD_NOTE) tại $z"
  if gcloud compute instances create "$VM_NAME" \
      --zone="$z" \
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
      ${LOCAL_SSD_FLAGS[@]+"${LOCAL_SSD_FLAGS[@]}"} \
      --scopes=https://www.googleapis.com/auth/cloud-platform \
      --metadata="install-nvidia-driver=True" 2>&1 | tee /tmp/kimi-create.log; then
    CREATED_ZONE="$z"
    break
  fi

  if grep -qE 'ZONE_RESOURCE_POOL_EXHAUSTED|does not exist in zone' /tmp/kimi-create.log; then
    echo "    -> $z không dùng được lúc này, thử zone tiếp theo"
    continue
  fi
  echo "LỖI không phải do hết chỗ, dừng lại." >&2
  exit 1
done

if [ -z "$CREATED_ZONE" ]; then
  cat >&2 <<EOF

LỖI: không zone nào trong '$TRY_ZONES' còn chỗ cho $MACHINE_TYPE.

Lựa chọn:
  1. Đợi rồi thử lại (capacity Spot thay đổi liên tục)
  2. Đổi sang machine type ít khan hiếm hơn trong 00-config.sh:
       export MACHINE_TYPE="a2-highgpu-8g"   # 8x A100 40GB, đã chạy ổn định
  3. Dùng on-demand thay vì Spot (quota on-demand A100-80GB đã có = 8):
       sửa --provisioning-model=SPOT thành STANDARD trong file này,
       và bỏ --instance-termination-action / --discard-local-ssds-at-...
       LƯU Ý: on-demand ~\$29-59/giờ, KHÔNG tự tắt khi hết --max-run-duration.
EOF
  exit 1
fi

# Ghi zone thành công để 03/04/05/06 dùng đúng zone
echo "$CREATED_ZONE" > "$(dirname "$0")/.zone"

echo
echo "==> Xong. VM đang chạy tại zone: $CREATED_ZONE"
[ "$CREATED_ZONE" = "$ZONE" ] || echo "    (đã ghi vào .zone, các script khác tự dùng zone này)"
echo
echo "==> Bước tiếp theo:"
echo "    ./03-start-session.sh      # tự cài Studio + restore model từ GCS"
echo "    ./05-update-ssh.sh         # cập nhật IP cho SSH/VS Code"
