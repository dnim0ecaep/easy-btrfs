#!/bin/bash
# Debian 13 Trixie: Automated Btrfs + Timeshift Disk Setup

# 1. Identify and exclude the Boot/Live USB device
# We find the parent device of the current live mount point
LIVE_DEV=$(lsblk -no PKNAME,MOUNTPOINT | grep -E '/run/live/medium|/cdrom|/live/image' | awk '{print $1}' | head -n1)

# 2. Select the largest 'disk' that is NOT the live device
TARGET_NAME=$(lsblk -dnbo NAME,SIZE,TYPE | grep "disk$" | awk -v live="$LIVE_DEV" '$1!= live {print $1, $2}' | sort -rnk2 | head -n1 | awk '{print $1}')

if; then
    echo "Error: No usable internal disks found."
    exit 1
fi

TARGET_DRIVE="/dev/$TARGET_NAME"
echo "Targeting Drive: $TARGET_DRIVE (Excluded Live USB: /dev/$LIVE_DEV)"

# 3. Wipe any existing signatures to prevent 'busy' errors
sudo wipefs -a "$TARGET_DRIVE"

# 4. Partitioning: GPT, 512M EFI (FAT32), Rest Btrfs
# Using 512MiB for perfect alignment
sudo parted -s "$TARGET_DRIVE" \
    mklabel gpt \
    mkpart "EFI" fat32 1MiB 513MiB \
    set 1 esp on \
    mkpart "ROOT" btrfs 513MiB 100%

# 5. Handle Partition Naming (SATA vs NVMe)
# NVMe partitions are /dev/nvme0n1p1, SATA are /dev/sda1
if]; then
    EFI_PART="${TARGET_DRIVE}p1"
    ROOT_PART="${TARGET_DRIVE}p2"
else
    EFI_PART="${TARGET_DRIVE}1"
    ROOT_PART="${TARGET_DRIVE}2"
fi

# 6. Formatting
sudo mkfs.vfat -F 32 "$EFI_PART"
sudo mkfs.btrfs -f "$ROOT_PART"

# 7. Create Timeshift-Compatible Subvolume Layout (@ and @home)
sudo mount "$ROOT_PART" /mnt
sudo btrfs subvolume create /mnt/@
sudo btrfs subvolume create /mnt/@home
sudo umount /mnt

# 8. Generate Automated fstab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")

# Using zstd:1 for high-speed SSDs and noatime for longevity
cat <<EOF >./fstab.automated
# /etc/fstab generated for Timeshift compatibility
UUID=$ROOT_UUID / btrfs defaults,noatime,compress=zstd:1,subvol=@ 0 0
UUID=$ROOT_UUID /home btrfs defaults,noatime,compress=zstd:1,subvol=@home 0 0
UUID=$EFI_UUID /boot/efi vfat umask=0077 0 2
EOF

echo "-------------------------------------------------------"
echo "SUCCESS: $TARGET_DRIVE has been prepared."
echo "Timeshift subvolumes '@' and '@home' are ready."
echo "Optimized fstab configuration saved to:./fstab.automated"
echo "-------------------------------------------------------"
