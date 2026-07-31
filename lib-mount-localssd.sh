#!/usr/bin/env bash
# Mount local SSD của a2-ultragpu-4g thành /mnt/localssd (RAID0 nếu có nhiều đĩa).
# Local SSD là EPHEMERAL: dữ liệu mất sau mỗi lần stop/start VM -> phải mount lại mỗi phiên.
mount_localssd() {
  mountpoint -q /mnt/localssd && return 0

  sudo apt-get install -y -qq mdadm >/dev/null 2>&1 || true
  sudo mkdir -p /mnt/localssd

  local devs ndev
  devs=$(lsblk -dpno NAME,MODEL | grep -i 'nvme_card\|EphemeralDisk' | awk '{print $1}')
  [ -z "$devs" ] && devs=$(ls /dev/nvme0n[0-9]* 2>/dev/null | grep -v 'p[0-9]')
  ndev=$(echo "$devs" | wc -w)

  if [ "$ndev" -eq 0 ]; then
    echo "LỖI: không tìm thấy local SSD" >&2
    return 1
  elif [ "$ndev" -gt 1 ]; then
    sudo mdadm --create /dev/md0 --level=0 --raid-devices="$ndev" $devs --run
    sudo mkfs.ext4 -F /dev/md0
    sudo mount /dev/md0 /mnt/localssd
  else
    sudo mkfs.ext4 -F $devs
    sudo mount $devs /mnt/localssd
  fi

  sudo chmod 777 /mnt/localssd
  echo "==> Local SSD mounted: $(df -h /mnt/localssd | tail -1)"
}
