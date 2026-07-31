#!/usr/bin/env bash
# Mở firewall GCP cho port Studio (chỉ cần khi EXPOSE=lan).
# Không cần nếu dùng EXPOSE=cloudflare hoặc EXPOSE=tunnel.
#
# Dùng:
#   ./06-open-firewall.sh                 # mở cho TẤT CẢ (0.0.0.0/0)
#   ./06-open-firewall.sh 1.2.3.4/32      # chỉ mở cho IP/dải chỉ định (AN TOÀN HƠN)
#   ./06-open-firewall.sh --delete        # gỡ rule
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

RULE="allow-unsloth-studio"
TAG="unsloth-studio"

if [ "${1:-}" = "--delete" ]; then
  gcloud compute firewall-rules delete "$RULE" --quiet
  gcloud compute instances remove-tags "$VM_NAME" --zone="$ZONE" --tags="$TAG"
  echo "==> Đã gỡ rule + tag"
  exit 0
fi

SRC="${1:-0.0.0.0/0}"

if [ "$SRC" = "0.0.0.0/0" ]; then
  cat <<EOF

  ⚠️  Sắp mở port $STUDIO_PORT cho TOÀN BỘ INTERNET (0.0.0.0/0), không có TLS.
      Unsloth Studio cho phép chạy code trên VM này (8x A100).

      An toàn hơn: giới hạn theo IP, ví dụ
        ./06-open-firewall.sh \$(curl -s ifconfig.me)/32
      Hoặc dùng EXPOSE=cloudflare để có HTTPS thay vì HTTP trần.

EOF
  read -r -p "  Vẫn tiếp tục? [y/N] " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "Đã huỷ."; exit 1; }
fi

if gcloud compute firewall-rules describe "$RULE" >/dev/null 2>&1; then
  echo "==> Cập nhật rule $RULE (source: $SRC)"
  gcloud compute firewall-rules update "$RULE" --source-ranges="$SRC"
else
  echo "==> Tạo rule $RULE (source: $SRC)"
  gcloud compute firewall-rules create "$RULE" \
    --allow="tcp:$STUDIO_PORT" \
    --source-ranges="$SRC" \
    --target-tags="$TAG" \
    --description="Unsloth Studio UI"
fi

gcloud compute instances add-tags "$VM_NAME" --zone="$ZONE" --tags="$TAG"

IP=$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || echo "<VM chưa chạy>")

echo
echo "==> Xong. Truy cập: http://$IP:$STUDIO_PORT"
echo "==> Nhớ chạy Studio với EXPOSE=lan:"
echo "      EXPOSE=lan ./03-start-session.sh"
