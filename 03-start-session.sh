#!/usr/bin/env bash
# Chạy TỪ MÁY LOCAL. Start VM -> restore model -> chạy Unsloth Studio -> mở SSH tunnel.
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> Start VM $VM_NAME"
gcloud compute instances start "$VM_NAME" --zone="$ZONE"

echo "==> Chờ SSH sẵn sàng..."
until gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="true" >/dev/null 2>&1; do
  sleep 10
done

echo "==> Copy script lên VM"
gcloud compute scp "$HERE/remote-start.sh" "$HERE/lib-mount-localssd.sh" \
  "$VM_NAME":~/ --zone="$ZONE"

echo "==> Restore model + khởi động Unsloth Studio (EXPOSE=$EXPOSE)"
gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="\
  BUCKET='$BUCKET' HF_HOME='$HF_HOME' STUDIO_PORT='$STUDIO_PORT' EXPOSE='$EXPOSE' \
  bash ~/remote-start.sh"

echo
echo "======================================================================"
case "$EXPOSE" in
  cloudflare)
    echo "  URL công khai HTTPS: xem output ở trên (link *.trycloudflare.com)"
    echo "  Chia sẻ URL + API key cho người cần dùng."
    ;;
  lan)
    IP=$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" \
      --format="value(networkInterfaces[0].accessConfigs[0].natIP)")
    echo "  Truy cập:  http://$IP:$STUDIO_PORT"
    echo "  (cần đã chạy ./06-open-firewall.sh; IP đổi mỗi lần start VM)"
    ;;
  *)
    echo "  Unsloth Studio UI:  http://localhost:$STUDIO_PORT"
    ;;
esac
echo "======================================================================"
echo "  Trong UI, chọn model Kimi-K3-GGUF ($QUANT) rồi mở phần"
echo "  'GGUF hardware controls' để chỉnh MoE expert offload / multi-GPU."
echo

if [ "$EXPOSE" = "tunnel" ]; then
  echo "  Ctrl-C để đóng tunnel (VM VẪN CHẠY - nhớ chạy ./04-stop-session.sh)"
  echo "======================================================================"
  gcloud compute ssh "$VM_NAME" --zone="$ZONE" -- -N -L "$STUDIO_PORT:localhost:$STUDIO_PORT"
else
  echo "  VM VẪN CHẠY - nhớ chạy ./04-stop-session.sh khi xong"
  echo "======================================================================"
fi
