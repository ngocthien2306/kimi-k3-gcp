#!/usr/bin/env bash
# Mount local SSD thành RAID0 tại /mnt/localssd.
# Local SSD là EPHEMERAL: mất dữ liệu sau mỗi lần stop/start -> phải mount lại mỗi phiên.
#
# AN TOÀN: hàm này chạy mkfs, nên TUYỆT ĐỐI không được chạm vào boot disk.
# Trên GCP, boot disk báo model "nvme_card-pd" còn local SSD là "nvme_card<N>"
# -> chỉ grep "nvme_card" là DÍNH CẢ BOOT DISK. Phải lọc kỹ.

_localssd_devices() {
  # Thiết bị chứa root filesystem - không bao giờ đụng vào
  local root_src root_dev
  root_src=$(findmnt -no SOURCE / 2>/dev/null)
  root_dev=$(lsblk -pno PKNAME "$root_src" 2>/dev/null | head -1)

  local name model
  while read -r name model; do
    [ -n "$name" ] || continue

    # Lớp 1: chỉ nhận local SSD, loại persistent disk (-pd) và thiết bị không model
    case "$model" in
      nvme_card-pd*|"")            continue ;;
      nvme_card*|*EphemeralDisk*)  ;;
      *)                           continue ;;
    esac

    # Lớp 2: không phải đĩa chứa root
    [ -n "$root_dev" ] && [ "$name" = "$root_dev" ] && continue

    # Lớp 3: không có partition nào đang được mount
    if lsblk -no MOUNTPOINT "$name" 2>/dev/null | grep -q '[^[:space:]]'; then
      continue
    fi

    echo "$name"
  done < <(lsblk -dpno NAME,MODEL)
}

mount_localssd() {
  mountpoint -q /mnt/localssd && { echo "==> /mnt/localssd đã mount sẵn"; return 0; }

  command -v mdadm >/dev/null 2>&1 || sudo apt-get install -y -qq mdadm >/dev/null 2>&1 || true
  sudo mkdir -p /mnt/localssd

  local devs ndev
  devs=$(_localssd_devices | tr '\n' ' ')
  ndev=$(echo $devs | wc -w)

  if [ "$ndev" -eq 0 ]; then
    echo "LỖI: không tìm thấy local SSD nào." >&2
    echo "     Kiểm tra bằng: lsblk -dpno NAME,MODEL" >&2
    return 1
  fi

  echo "==> Tìm thấy $ndev local SSD: $devs"

  if [ "$ndev" -gt 1 ]; then
    # Dọn RAID cũ nếu còn sót từ lần boot trước
    sudo mdadm --stop /dev/md0 2>/dev/null || true
    sudo mdadm --create /dev/md0 --level=0 --raid-devices="$ndev" $devs --run
    sudo mkfs.ext4 -F -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard /dev/md0
    sudo mount -o discard,defaults,nobarrier /dev/md0 /mnt/localssd
  else
    sudo mkfs.ext4 -F -m 0 -E lazy_itable_init=0,discard $devs
    sudo mount -o discard,defaults,nobarrier $devs /mnt/localssd
  fi

  sudo chmod 777 /mnt/localssd
  echo "==> Local SSD mounted: $(df -h /mnt/localssd | tail -1)"
}
