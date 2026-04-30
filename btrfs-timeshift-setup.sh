#!/bin/sh
# =============================================================================
#  btrfs-timeshift-setup.sh
#  Debian 13 installer post-partition helper (automates slides 22-24)
#
#  Run from the Debian installer TTY (Ctrl+Alt+F2) AFTER the base system
#  has been installed but BEFORE the installer completes.
#
#  POSIX sh compatible — works in Debian installer busybox/dash environment
# =============================================================================

set -e

RED='\033[1;31m'
YEL='\033[1;33m'
GRN='\033[1;32m'
CYN='\033[1;36m'
BLD='\033[1m'
RST='\033[0m'

info()   { printf "${CYN}[INFO]${RST}  %s\n" "$*"; }
ok()     { printf "${GRN}[ OK ]${RST}  %s\n" "$*"; }
warn()   { printf "${YEL}[WARN]${RST}  %s\n" "$*"; }
die()    { printf "${RED}[FAIL]${RST}  %s\n" "$*" >&2; exit 1; }
header() { printf "\n${BLD}${YEL}==========================================\n  %s\n==========================================${RST}\n" "$*"; }

# Sanity checks
[ "$(id -u)" -eq 0 ] || die "Must run as root"
for cmd in lsblk blkid btrfs mount umount mkdir; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

# STEP 1: Show drives
header "STEP 1 — Available block devices"
echo ""
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null || lsblk
echo ""
info "Currently mounted (df -h):"
df -h 2>/dev/null || true
echo ""

# STEP 2: Choose partitions
header "STEP 2 — Select partitions"
echo ""
echo "  Partitions detected:"
echo "  -----------------------------------------------"
lsblk -lnpo NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | awk '$1 ~ /[0-9]$/ { printf "    %-22s %-8s %-12s %s\n", $1, $2, $3, $4 }'
echo ""

# BTRFS partition
BTRFS_PART=""
while true; do
    printf "${CYN}Enter BTRFS root partition (e.g. /dev/nvme0n1p2 or /dev/sda2): ${RST}"
    read -r BTRFS_PART
    BTRFS_PART="${BTRFS_PART%/}"
    if [ ! -b "$BTRFS_PART" ]; then
        warn "Not a valid block device: $BTRFS_PART"
        continue
    fi
    FSTYPE=$(lsblk -no FSTYPE "$BTRFS_PART" 2>/dev/null || true)
    if [ "$FSTYPE" != "btrfs" ]; then
        warn "Partition $BTRFS_PART has fstype '${FSTYPE:-<unknown>}', expected btrfs."
        printf "${YEL}Continue anyway? (yes/no): ${RST}"
        read -r FORCE
        [ "$FORCE" = "yes" ] || continue
    fi
    break
done

# EFI partition
EFI_PART=""
while true; do
    printf "${CYN}Enter EFI partition (e.g. /dev/nvme0n1p1 or /dev/sda1): ${RST}"
    read -r EFI_PART
    EFI_PART="${EFI_PART%/}"
    if [ ! -b "$EFI_PART" ]; then
        warn "Not a valid block device: $EFI_PART"
        continue
    fi
    break
done

echo ""
info "BTRFS root : $BTRFS_PART"
info "EFI        : $EFI_PART"
echo ""
printf "${YEL}Confirm and continue? (yes/no): ${RST}"
read -r CONFIRM
[ "$CONFIRM" = "yes" ] || die "Aborted by user."

# STEP 3: Unmount /target
header "STEP 3 — Unmounting /target"

for extra in /target/proc /target/sys /target/dev/pts /target/dev /target/run; do
    if mountpoint -q "$extra" 2>/dev/null; then
        info "Unmounting $extra"
        umount -l "$extra" 2>/dev/null || true
    fi
done

if mountpoint -q /target/boot/efi 2>/dev/null; then
    info "Unmounting /target/boot/efi"
    umount /target/boot/efi
fi

if mountpoint -q /target 2>/dev/null; then
    info "Unmounting /target"
    umount /target
fi
ok "Unmount complete"

# STEP 4: Mount BTRFS to /mnt
header "STEP 4 — Mount BTRFS partition to /mnt"

if mountpoint -q /mnt 2>/dev/null; then
    info "/mnt already mounted — unmounting first"
    umount /mnt
fi
mount "$BTRFS_PART" /mnt
ok "Mounted $BTRFS_PART -> /mnt"
info "Contents of /mnt:"
ls -la /mnt
echo ""

# STEP 5: Rename @rootfs -> @
header "STEP 5 — Rename @rootfs -> @"

if [ -d /mnt/@rootfs ]; then
    mv /mnt/@rootfs /mnt/@
    ok "Renamed @rootfs -> @"
elif [ -d "/mnt/@" ]; then
    warn "/mnt/@ already exists — skipping rename"
else
    ls -la /mnt
    die "Neither /mnt/@rootfs nor /mnt/@ found — wrong partition?"
fi

# STEP 6: Create subvolumes
header "STEP 6 — Creating BTRFS subvolumes"

for SUBVOL in @home @root @log @tmp @opt; do
    if [ -d "/mnt/${SUBVOL}" ]; then
        warn "Subvolume ${SUBVOL} already exists — skipping"
    else
        btrfs subvolume create "/mnt/${SUBVOL}"
        ok "Created subvolume ${SUBVOL}"
    fi
done

info "All subvolumes:"
btrfs subvolume list /mnt

# STEP 7: Remount into /target
header "STEP 7 — Remounting subvolumes into /target"

umount /mnt
info "Unmounted /mnt — remounting via subvolumes"

mkdir -p /target
mount -o noatime,compress=zstd,subvol=@ "$BTRFS_PART" /target
ok "Mounted @ -> /target"

mkdir -p /target/boot/efi /target/home /target/root /target/var/log /target/tmp /target/opt

mount -o noatime,compress=zstd,subvol=@home "$BTRFS_PART" /target/home
ok "Mounted @home -> /target/home"

mount -o noatime,compress=zstd,subvol=@root "$BTRFS_PART" /target/root
ok "Mounted @root -> /target/root"

mount -o noatime,compress=zstd,subvol=@log  "$BTRFS_PART" /target/var/log
ok "Mounted @log  -> /target/var/log"

mount -o noatime,compress=zstd,subvol=@tmp  "$BTRFS_PART" /target/tmp
ok "Mounted @tmp  -> /target/tmp"

mount -o noatime,compress=zstd,subvol=@opt  "$BTRFS_PART" /target/opt
ok "Mounted @opt  -> /target/opt"

mount "$EFI_PART" /target/boot/efi
ok "Mounted EFI $EFI_PART -> /target/boot/efi"

# STEP 8: Write fstab
header "STEP 8 — Writing /target/etc/fstab"

BTRFS_UUID=$(blkid -s UUID -o value "$BTRFS_PART")
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")

[ -n "$BTRFS_UUID" ] || die "Could not get UUID for $BTRFS_PART"
[ -n "$EFI_UUID" ]   || die "Could not get UUID for $EFI_PART"

info "BTRFS UUID : $BTRFS_UUID"
info "EFI UUID   : $EFI_UUID"

FSTAB_PATH="/target/etc/fstab"

if [ -f "$FSTAB_PATH" ]; then
    cp "$FSTAB_PATH" "${FSTAB_PATH}.bak"
    info "Backed up existing fstab to ${FSTAB_PATH}.bak"
fi

cat > "$FSTAB_PATH" <<FSTAB
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name
# devices that works even if disks are added and removed. See fstab(5).
#
# systemd generates mount units based on this file, see systemd.mount(5).
# Please run 'systemctl daemon-reload' after making changes here.
#
# <file system>                              <mount point>  <type>  <options>                      <dump>  <pass>

# / was on ${BTRFS_PART} during installation
UUID=${BTRFS_UUID}  /            btrfs  noatime,compress=zstd,subvol=@       0  0
UUID=${BTRFS_UUID}  /home        btrfs  noatime,compress=zstd,subvol=@home   0  0
UUID=${BTRFS_UUID}  /root        btrfs  noatime,compress=zstd,subvol=@root   0  0
UUID=${BTRFS_UUID}  /var/log     btrfs  noatime,compress=zstd,subvol=@log    0  0
UUID=${BTRFS_UUID}  /tmp         btrfs  noatime,compress=zstd,subvol=@tmp    0  0
UUID=${BTRFS_UUID}  /opt         btrfs  noatime,compress=zstd,subvol=@opt    0  0

# /boot/efi was on ${EFI_PART} during installation
UUID=${EFI_UUID}    /boot/efi    vfat   umask=0077                           0  1
FSTAB

ok "fstab written"
echo ""
info "New fstab:"
echo "------------------------------------------------------"
cat "$FSTAB_PATH"
echo "------------------------------------------------------"

# STEP 9: Verify
header "STEP 9 — Verification"

info "Mounts under /target:"
mount | grep target || true
echo ""
info "BTRFS subvolumes:"
btrfs subvolume list /target

echo ""
ok "========================================="
ok "  Done! BTRFS subvolumes ready for Timeshift."
ok "========================================="
echo ""
warn "Next steps:"
printf "  1. Press Ctrl+Alt+F1 to return to the installer\n"
printf "  2. Finish the Debian installation normally\n"
printf "  3. After first boot, install Timeshift and select BTRFS mode\n"
printf "     (auto-detects @, @home, @root, @log, @tmp, @opt)\n"
echo ""
