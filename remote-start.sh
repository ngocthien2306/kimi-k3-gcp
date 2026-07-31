#!/usr/bin/env bash
# CHẠY TRÊN VM (được 03-start-session.sh copy lên và gọi tự động).
# Restore HF cache từ GCS -> khởi động Unsloth Studio.
set -euo pipefail

BUCKET="${BUCKET:?}"
export HF_HOME="${HF_HOME:-/mnt/localssd/hf}"
STUDIO_PORT="${STUDIO_PORT:-8888}"

source "$(dirname "$0")/lib-mount-localssd.sh"
mount_localssd
mkdir -p "$HF_HOME/hub"

# Restore model từ GCS (in-region: nhanh + không mất phí egress)
echo "==> Restore model từ GCS (~600GB)"
gcloud storage rsync -r "$BUCKET/hf-hub" "$HF_HOME/hub"

# Khởi động Unsloth Studio.
#   EXPOSE=tunnel     (mặc định) bind localhost, chỉ vào được qua SSH tunnel - an toàn nhất
#   EXPOSE=lan        bind 0.0.0.0, vào qua http://<IP-VM>:8888 - CẦN mở firewall GCP
#   EXPOSE=cloudflare bind 0.0.0.0 + Cloudflare tunnel, sinh URL HTTPS công khai
EXPOSE="${EXPOSE:-tunnel}"

case "$EXPOSE" in
  tunnel)     STUDIO_ARGS=(-p "$STUDIO_PORT") ;;
  lan)        STUDIO_ARGS=(-H 0.0.0.0 -p "$STUDIO_PORT") ;;
  cloudflare) STUDIO_ARGS=(-H 0.0.0.0 -p "$STUDIO_PORT" --cloudflare) ;;
  *) echo "LỖI: EXPOSE phải là tunnel|lan|cloudflare (nhận: $EXPOSE)" >&2; exit 1 ;;
esac

echo "==> Khởi động Unsloth Studio (EXPOSE=$EXPOSE, port $STUDIO_PORT)"
pkill -f 'unsloth studio' 2>/dev/null || true
sleep 2
nohup unsloth studio "${STUDIO_ARGS[@]}" > ~/unsloth-studio.log 2>&1 &

echo "==> Chờ Studio khởi động..."
for _ in $(seq 30); do
  grep -qiE 'https?://|api key|listening' ~/unsloth-studio.log 2>/dev/null && break
  sleep 2
done

if [ "$EXPOSE" = "cloudflare" ]; then
  echo
  echo "===================== URL CÔNG KHAI + API KEY ====================="
  grep -iE 'trycloudflare\.com|https://|api[ -]?key' ~/unsloth-studio.log | tail -10 || \
    echo "Chưa thấy URL. Xem thêm: tail -f ~/unsloth-studio.log"
  echo "=================================================================="
fi

echo "==> Studio đang chạy. Log: tail -f ~/unsloth-studio.log"
