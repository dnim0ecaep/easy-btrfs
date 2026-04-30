#!/bin/bash
# Debian 13 Btrfs-Timeshift Automation Script

# 1. Identify the largest internal drive by size
TARGET_DRIVE=$(lsblk -dnbo NAME,SIZE | sort -rnk2 | head -n1 | awk '{print "/dev/"$1}')
echo "Targeting largest drive: $TARGET_DRIVE"

# 2. Partition the drive (GPT, 512M EFI, Rest Btrfs)
# Uses parted --script for automation
sudo parted --script "$TARGET_DRIVE" \
    mklabel gpt \
    mkpart "EFI" fat32 1MiB 513MiB \
    set 1 esp on \
    mkpart "ROOT" btrfs 513MiB 100%

# 3. Format the partitions
EFI_PART="${TARGET_DRIVE}1"
ROOT_PART="${TARGET_DRIVE}2"

# Handle NVMe naming conventions (e.g., nvme0n1p1)
if]; then
    EFI_PART="${TARGET_DRIVE}p1"
    ROOT_PART="${TARGET_DRIVE}p2"
fi

sudo mkfs.vfat -F 32 "$EFI_PART"
sudo mkfs.btrfs -f "$ROOT_PART"

# 4. Configure Timeshift-compatible Subvolumes (@ and @home)
sudo mount "$ROOT_PART" /mnt
sudo btrfs subvolume create /mnt/@
sudo btrfs subvolume create /mnt/@home
sudo umount /mnt

# 5. Generate optimized fstab entries
UUID=$(blkid -s UUID -o value "$ROOT_PART")
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")

cat <<EOF >./fstab.new
# /etc/fstab: Optimized for Debian 13 Btrfs + Timeshift
UUID=$UUID / btrfs defaults,noatime,compress=zstd:1,subvol=@ 0 0
UUID=$UUID /home btrfs defaults,noatime,compress=zstd:1,subvol=@home 0 0
UUID=$EFI_UUID /boot/efi vfat umask=0077 0 2
EOF

echo "Drive configured. Subvolumes '@' and '@home' created."
echo "Suggested fstab saved to./fstab.new"
