#!/bin/sh
# =============================================================================
#  btrfs-timeshift-setup.sh
#  Debian 13 (trixie) — BTRFS subvolume + Timeshift setup
#
#  Run this from the Debian installer TTY2 shell AFTER the installer has
#  finished installing the base system but BEFORE rebooting.
#
#  How to get here:
#    - During Debian install, partition your disk using the installer:
#        * 500M  -> EFI partition  (FAT32)
#        * rest  -> BTRFS partition (the installer creates @rootfs here)
#    - Let the installer finish installing the base system
#    - Press Ctrl+Alt+F2 to get to TTY2, press Enter to activate the shell
#    - wget this script and run: sh btrfs-timeshift-setup.sh
#
#  What this script does:
#    1. Shows all drives with sizes so you can identify your target disk
#    2. You pick the disk — script auto-detects the EFI + BTRFS partitions
#    3. Unmounts /target cleanly
#    4. Mounts BTRFS top-level, renames @rootfs -> @
#    5. Creates subvolumes: @home @root @log @tmp @opt
#    6. Remounts all subvolumes into /target with noatime,compress=zstd
#    7. Rewrites /target/etc/fstab with correct UUID-based entries
#
#  Busybox-compatible: no lsblk, no mountpoint, no set -e/pipefail
# =============================================================================

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
header() {
    printf "\n${BLD}${YEL}"
    printf "============================================================\n"
    printf "  %s\n" "$*"
    printf "============================================================${RST}\n"
}

is_mounted() {
    grep -q " $1 " /proc/mounts 2>/dev/null
}

human_size() {
    KB="$1"
    if   [ "$KB" -ge 1073741824 ] 2>/dev/null; then printf "%dT" $(( KB / 1073741824 ))
    elif [ "$KB" -ge 1048576    ] 2>/dev/null; then printf "%dG" $(( KB / 1048576 ))
    elif [ "$KB" -ge 1024       ] 2>/dev/null; then printf "%dM" $(( KB / 1024 ))
    else printf "%dK" "$KB"
    fi
}

# ── Sanity ────────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "Must run as root"
command -v btrfs >/dev/null 2>&1 || die "btrfs not found"

# blkid location varies in installer — search common paths
BLKID=""
for TRY in blkid /sbin/blkid /usr/sbin/blkid /bin/blkid; do
    if "$TRY" --version >/dev/null 2>&1 || "$TRY" -h >/dev/null 2>&1; then
        BLKID="$TRY"
        break
    fi
done
[ -n "$BLKID" ] || die "blkid not found - check /sbin/blkid exists"

get_uuid() { "$BLKID" -s UUID -o value "$1" 2>/dev/null; }
get_type() { "$BLKID" -s TYPE -o value "$1" 2>/dev/null; }

# =============================================================================
#  STEP 1 — Show all whole drives with sizes
# =============================================================================
header "STEP 1 — Drives detected on this system"
echo ""
printf "  ${BLD}%-5s %-14s %-8s %s${RST}\n" "Num" "Device" "Size" "Model"
printf "  %s\n" "--------------------------------------------------"

IDX=0
DRIVE_LIST=""

while read -r MAJ MIN BLOCKS NAME; do
    # Skip header / blank lines
    echo "$NAME" | grep -qE '^[a-z]' || continue
    # Skip partitions (end in digit after letter, or have p+digit suffix)
    echo "$NAME" | grep -qE 'p[0-9]+$|[a-z][0-9]+$' && continue
    # Skip non-drives
    echo "$NAME" | grep -qE '^(loop|ram|sr|fd|dm-)' && continue
    DEV="/dev/${NAME}"
    [ -b "$DEV" ] || continue

    SIZE=$(human_size "$BLOCKS")
    MODEL=""
    if [ -f "/sys/block/${NAME}/device/model" ]; then
        MODEL=$(tr -d '\n' < "/sys/block/${NAME}/device/model" 2>/dev/null)
    fi

    IDX=$(( IDX + 1 ))
    printf "  ${CYN}%-5s${RST} %-14s %-8s %s\n" \
        "$IDX" "$DEV" "$SIZE" "${MODEL:-(no model info)}"
    DRIVE_LIST="${DRIVE_LIST}${IDX}|${DEV}
"
done < /proc/partitions

echo ""
[ "$IDX" -gt 0 ] || die "No drives found in /proc/partitions"

# Also show partition details so they can see what the installer created
printf "  ${BLD}Partition details:${RST}\n"
printf "  %s\n" "--------------------------------------------------"
while read -r MAJ MIN BLOCKS NAME; do
    echo "$NAME" | grep -qE '^[a-z]' || continue
    # Only partitions this time
    echo "$NAME" | grep -qE 'p[0-9]+$|[a-z][0-9]+$' || continue
    echo "$NAME" | grep -qE '^(loop|ram|sr|fd)' && continue
    DEV="/dev/${NAME}"
    [ -b "$DEV" ] || continue
    SIZE=$(human_size "$BLOCKS")
    FSTYPE=$(get_type "$DEV")
    printf "    %-16s %-8s %s\n" "$DEV" "$SIZE" "${FSTYPE:--}"
done < /proc/partitions
echo ""

# =============================================================================
#  STEP 2 — Pick the target disk
# =============================================================================
header "STEP 2 — Select the disk the installer used"
echo ""
echo "  Pick the disk that Debian was just installed onto."
echo "  This is usually your largest drive or the one without the installer USB."
echo ""

CHOSEN_DISK=""
while true; do
    printf "${CYN}Enter drive number (1-${IDX}): ${RST}"
    read -r INPUT
    echo "$INPUT" | grep -qE '^[0-9]+$' || { warn "Enter a number"; continue; }
    [ "$INPUT" -ge 1 ] && [ "$INPUT" -le "$IDX" ] 2>/dev/null || {
        warn "Must be between 1 and $IDX"; continue; }

    CHOSEN_DISK=$(echo "$DRIVE_LIST" | while IFS='|' read -r I DEV; do
        [ "$I" = "$INPUT" ] && printf "%s" "$DEV" && break
    done)
    [ -n "$CHOSEN_DISK" ] || { warn "Could not resolve — try again"; continue; }
    break
done

# Auto-detect partition suffixes
case "$CHOSEN_DISK" in
    /dev/nvme*|/dev/mmcblk*)
        EFI_PART="${CHOSEN_DISK}p1"
        BTRFS_PART="${CHOSEN_DISK}p2"
        ;;
    *)
        EFI_PART="${CHOSEN_DISK}1"
        BTRFS_PART="${CHOSEN_DISK}2"
        ;;
esac

echo ""
info "Target disk  : $CHOSEN_DISK"
info "EFI partition: $EFI_PART"
info "BTRFS partition: $BTRFS_PART"

# Verify both partitions exist
[ -b "$EFI_PART" ]   || die "EFI partition $EFI_PART not found. Did the installer partition this disk?"
[ -b "$BTRFS_PART" ] || die "BTRFS partition $BTRFS_PART not found."

# Warn if BTRFS partition doesn't look like btrfs
BTRFS_FSTYPE=$(get_type "$BTRFS_PART")
if [ "$BTRFS_FSTYPE" != "btrfs" ]; then
    warn "$BTRFS_PART has type '${BTRFS_FSTYPE:-unknown}' — expected btrfs"
    warn "Make sure you selected BTRFS as the filesystem during the Debian install"
    printf "${YEL}Continue anyway? (yes/no): ${RST}"
    read -r FORCE
    [ "$FORCE" = "yes" ] || die "Aborted."
fi

echo ""
printf "${YEL}Confirm: proceed with $CHOSEN_DISK? (yes/no): ${RST}"
read -r CONFIRM
[ "$CONFIRM" = "yes" ] || die "Aborted."

# =============================================================================
#  STEP 3 — Cleanly unmount /target
# =============================================================================
header "STEP 3 — Unmounting /target"

for MP in /target/proc /target/sys /target/dev/pts /target/dev \
          /target/run /target/boot/efi /target/home /target/root \
          /target/var/log /target/tmp /target/opt /target; do
    if is_mounted "$MP"; then
        info "Unmounting $MP"
        umount "$MP" 2>/dev/null || umount -l "$MP" 2>/dev/null || true
    fi
done
if is_mounted /mnt; then
    umount /mnt 2>/dev/null || umount -l /mnt 2>/dev/null || true
fi
ok "Unmount complete"

# =============================================================================
#  STEP 4 — Mount top-level BTRFS, rename @rootfs -> @
# =============================================================================
header "STEP 4 — Preparing BTRFS subvolumes"

mount -o subvolid=5 "$BTRFS_PART" /mnt || die "Failed to mount top-level BTRFS"
ok "Mounted top-level BTRFS -> /mnt"

info "Current subvolumes:"
btrfs subvolume list /mnt | sed 's/^/  /'
echo ""

if [ -d /mnt/@rootfs ] && [ ! -d "/mnt/@" ]; then
    mv /mnt/@rootfs /mnt/@ || die "Failed to rename @rootfs -> @"
    ok "Renamed @rootfs -> @"
elif [ -d "/mnt/@" ]; then
    warn "Subvolume @ already exists — skipping rename"
    [ -d /mnt/@rootfs ] && warn "@rootfs also exists — you may want to delete it later"
else
    info "Contents of /mnt:"
    ls /mnt
    die "No @rootfs or @ subvolume found. Is $BTRFS_PART the right partition?"
fi

# =============================================================================
#  STEP 5 — Create additional subvolumes
# =============================================================================
header "STEP 5 — Creating subvolumes"

for SUBVOL in @home @root @log @tmp @opt; do
    if [ -d "/mnt/${SUBVOL}" ]; then
        warn "${SUBVOL} already exists — skipping"
    else
        btrfs subvolume create "/mnt/${SUBVOL}" || die "Failed to create ${SUBVOL}"
        ok "Created ${SUBVOL}"
    fi
done

echo ""
info "All subvolumes:"
btrfs subvolume list /mnt | sed 's/^/  /'

umount /mnt || die "Failed to unmount /mnt"

# =============================================================================
#  STEP 6 — Mount everything into /target
# =============================================================================
header "STEP 6 — Mounting subvolumes into /target"

OPTS="noatime,compress=zstd"

mkdir -p /target
mount -o "${OPTS},subvol=@"     "$BTRFS_PART" /target          || die "Failed to mount @"
ok "@ -> /target"

mkdir -p /target/boot/efi /target/home /target/root \
         /target/var/log  /target/tmp  /target/opt

mount -o "${OPTS},subvol=@home" "$BTRFS_PART" /target/home     || die "Failed to mount @home"
ok "@home -> /target/home"

mount -o "${OPTS},subvol=@root" "$BTRFS_PART" /target/root     || die "Failed to mount @root"
ok "@root -> /target/root"

mount -o "${OPTS},subvol=@log"  "$BTRFS_PART" /target/var/log  || die "Failed to mount @log"
ok "@log  -> /target/var/log"

mount -o "${OPTS},subvol=@tmp"  "$BTRFS_PART" /target/tmp      || die "Failed to mount @tmp"
ok "@tmp  -> /target/tmp"

mount -o "${OPTS},subvol=@opt"  "$BTRFS_PART" /target/opt      || die "Failed to mount @opt"
ok "@opt  -> /target/opt"

mount "$EFI_PART" /target/boot/efi                              || die "Failed to mount EFI"
ok "EFI  -> /target/boot/efi"

# =============================================================================
#  STEP 7 — Rewrite /target/etc/fstab
# =============================================================================
header "STEP 7 — Writing /target/etc/fstab"

BTRFS_UUID=$(get_uuid "$BTRFS_PART")
EFI_UUID=$(get_uuid   "$EFI_PART")

[ -n "$BTRFS_UUID" ] || die "Could not get UUID for $BTRFS_PART"
[ -n "$EFI_UUID"   ] || die "Could not get UUID for $EFI_PART"

info "BTRFS UUID: $BTRFS_UUID"
info "EFI UUID  : $EFI_UUID"

FSTAB="/target/etc/fstab"
[ -f "$FSTAB" ] && cp "$FSTAB" "${FSTAB}.bak" && info "Old fstab backed up to ${FSTAB}.bak"

cat > "$FSTAB" <<FSTAB
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a device.
# See fstab(5) and systemd.mount(5) for details.
#
# <file system>                             <mount point>  <type>  <options>                       <dump>  <pass>

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
cat "$FSTAB" | sed 's/^/  /'

# =============================================================================
#  STEP 8 — Summary
# =============================================================================
header "STEP 8 — Done"
echo ""
info "Active mounts:"
grep "target" /proc/mounts | awk '{printf "  %-35s %s\n", $1, $2}'
echo ""
info "BTRFS subvolumes:"
btrfs subvolume list /target | sed 's/^/  /'
echo ""
ok "============================================================"
ok "  Setup complete — system is ready for Timeshift!"
ok "============================================================"
echo ""
printf "  ${BLD}Disk   :${RST} %s\n"           "$CHOSEN_DISK"
printf "  ${BLD}EFI    :${RST} %s  UUID: %s\n" "$EFI_PART"   "$EFI_UUID"
printf "  ${BLD}BTRFS  :${RST} %s  UUID: %s\n" "$BTRFS_PART" "$BTRFS_UUID"
printf "  ${BLD}Subvols:${RST} @  @home  @root  @log  @tmp  @opt\n"
echo ""
warn "NEXT STEPS:"
printf "  1. Press Ctrl+Alt+F1 to return to the Debian installer\n"
printf "  2. Let the installer finish (it may update GRUB / initramfs)\n"
printf "  3. Reboot into your new Debian system\n"
printf "  4. Install timeshift, open it, select BTRFS mode\n"
printf "     Timeshift will auto-detect all @ subvolumes\n"
echo ""
