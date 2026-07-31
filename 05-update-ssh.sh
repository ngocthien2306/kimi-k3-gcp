#!/usr/bin/env bash
# Cập nhật HostName của entry "kimi-k3" trong ~/.ssh/config theo IP hiện tại của VM.
# Chạy sau mỗi lần start VM (IP ngoài đổi mỗi lần stop/start).
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

IP=$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)

if [ -z "$IP" ]; then
  echo "LỖI: VM '$VM_NAME' chưa chạy hoặc không có IP ngoài." >&2
  echo "      Start trước: gcloud compute instances start $VM_NAME --zone=$ZONE" >&2
  exit 1
fi

CONFIG="$HOME/.ssh/config"
if ! grep -q '^Host kimi-k3$' "$CONFIG"; then
  echo "LỖI: không tìm thấy 'Host kimi-k3' trong $CONFIG" >&2
  exit 1
fi

cp "$CONFIG" "$CONFIG.bak"

# Chỉ thay dòng HostName NGAY SAU "Host kimi-k3", không đụng entry khác
python3 - "$CONFIG" "$IP" <<'PY'
import re, sys
path, ip = sys.argv[1], sys.argv[2]
lines = open(path).read().split('\n')
out, in_block = [], False
for ln in lines:
    if re.match(r'^Host\s', ln):
        in_block = ln.strip() == 'Host kimi-k3'
    elif in_block and re.match(r'^\s*HostName\s', ln):
        ln = re.sub(r'(^\s*HostName\s+).*', r'\g<1>' + ip, ln)
        in_block = False
    out.append(ln)
open(path, 'w').write('\n'.join(out))
PY

echo "==> Đã cập nhật: kimi-k3 -> $IP"
echo "==> Kiểm tra: ssh kimi-k3 hostname"
