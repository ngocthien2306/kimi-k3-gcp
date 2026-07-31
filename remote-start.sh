#!/usr/bin/env bash
# CHẠY TRÊN VM (được 03-start-session.sh copy lên và gọi tự động).
# Restore HF cache từ GCS -> khởi động Unsloth Studio.
set -euo pipefail

BUCKET="${BUCKET:?}"
export HF_HOME="${HF_HOME:-/mnt/localssd/hf}"
STUDIO_PORT="${STUDIO_PORT:-8888}"

# SSH không tương tác KHÔNG nạp ~/.bashrc. Ngoài ra `nohup unsloth` (resolve qua
# PATH, đi qua symlink ~/.local/bin/unsloth) vẫn báo "No such file or directory".
# -> Gọi thẳng binary trong venv bằng ĐƯỜNG DẪN TUYỆT ĐỐI cho chắc.
export PATH="$HOME/.local/bin:$PATH"
UNSLOTH_BIN="$HOME/.unsloth/studio/unsloth_studio/bin/unsloth"
if [ ! -x "$UNSLOTH_BIN" ]; then
  UNSLOTH_BIN=$(command -v unsloth 2>/dev/null || true)
fi
[ -n "$UNSLOTH_BIN" ] || {
  echo "LỖI: không tìm thấy 'unsloth'. Cài lại: curl -fsSL https://unsloth.ai/install.sh | sh" >&2
  exit 1
}

source "$(dirname "$0")/lib-mount-localssd.sh"
mount_localssd
mkdir -p "$HF_HOME/hub"

# Restore model từ GCS (in-region: nhanh + không mất phí egress)
# "WARNING: Skipping symlink ..." là BÌNH THƯỜNG - rsync không xử lý symlink,
# phần đó được khôi phục bằng tarball ở bước dưới. Lọc bớt cho đỡ rối.
echo "==> Restore blobs từ GCS (~600GB)"
gcloud storage rsync -r "$BUCKET/hf-hub" "$HF_HOME/hub" 2>&1 \
  | grep -v 'Skipping symlink' || true

# rsync bỏ qua symlink -> phải bung lại snapshots/ từ tarball, nếu không
# Studio sẽ không thấy model dù blobs đã có đủ.
echo "==> Khôi phục cấu trúc symlink"
if gcloud storage cp "$BUCKET/hf-meta.tar.gz" /tmp/hf-meta.tar.gz 2>/dev/null; then
  tar xzf /tmp/hf-meta.tar.gz -C "$HF_HOME/hub"
  rm -f /tmp/hf-meta.tar.gz
else
  echo "CẢNH BÁO: không có $BUCKET/hf-meta.tar.gz" >&2
  echo "          Studio có thể không thấy model. Tạo lại bằng (trên VM):" >&2
  echo "          tar czf /tmp/hf-meta.tar.gz -C $HF_HOME/hub --exclude=blobs . && \\" >&2
  echo "          gcloud storage cp /tmp/hf-meta.tar.gz $BUCKET/hf-meta.tar.gz" >&2
fi

# Kiểm tra symlink có trỏ đúng không (broken symlink = restore hỏng)
BROKEN=$(find "$HF_HOME/hub" -xtype l 2>/dev/null | wc -l)
if [ "$BROKEN" -gt 0 ]; then
  echo "CẢNH BÁO: có $BROKEN symlink hỏng trong HF cache" >&2
  find "$HF_HOME/hub" -xtype l 2>/dev/null | head -3 >&2
fi

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
# Pattern 'unsloth[ ]studio' để pkill KHÔNG tự khớp command line của chính nó
pkill -f 'unsloth[ ]studio' 2>/dev/null || true
sleep 3
nohup "$UNSLOTH_BIN" studio "${STUDIO_ARGS[@]}" > ~/unsloth-studio.log 2>&1 < /dev/null &

# Đợi đến khi port THỰC SỰ listen. Grep log không đủ: log in ra trước khi
# server bind xong -> tunnel mở sớm và báo "connect failed: Connection refused".
echo "==> Chờ Studio bind port $STUDIO_PORT..."
READY=0
for _ in $(seq 60); do
  if ss -tln 2>/dev/null | grep -q ":$STUDIO_PORT "; then READY=1; break; fi
  sleep 2
done

if [ "$READY" -eq 0 ]; then
  echo "LỖI: Studio không bind được port $STUDIO_PORT sau 120s" >&2
  tail -20 ~/unsloth-studio.log >&2
  exit 1
fi
echo "==> Studio đã sẵn sàng trên port $STUDIO_PORT"

if [ "$EXPOSE" = "cloudflare" ]; then
  echo
  echo "===================== URL CÔNG KHAI + API KEY ====================="
  grep -iE 'trycloudflare\.com|https://|api[ -]?key' ~/unsloth-studio.log | tail -10 || \
    echo "Chưa thấy URL. Xem thêm: tail -f ~/unsloth-studio.log"
  echo "=================================================================="
fi

echo "==> Studio đang chạy. Log: tail -f ~/unsloth-studio.log"
