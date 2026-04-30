#!/bin/sh
# =============================================================================
#  btrfs-timeshift-setup.sh
#  Debian 13 (trixie) — Full BTRFS + Timeshift drive setup
#
#  Run from installer TTY2 (Ctrl+Alt+F2, press Enter to activate shell)
#  AFTER the Debian base system has been installed.
#
#  What this does:
#    1. Lists all whole drives with sizes — you pick one by number
#    2. Wipes and partitions the drive: 500M EFI + rest BTRFS
#    3. Formats both partitions
#    4. Creates BTRFS subvolumes: @ @home @root @log @tmp @opt
#    5. Mounts everything into /target
#    6. Writes /target/etc/fstab with UUID-based entries
#
#  Compatible with Debian installer busybox environment:
#    - No lsblk, no mountpoint, no set -e/pipefail
#    - Uses: fdisk, blkid, mkfs, btrfs, /proc/partitions, /proc/mounts
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

# Human-readable size from 1K blocks
human_size() {
    KBLOCKS="$1"
    if [ "$KBLOCKS" -ge 1073741824 ] 2>/dev/null; then
        printf "%dT" $(( KBLOCKS / 1073741824 ))
    elif [ "$KBLOCKS" -ge 1048576 ] 2>/dev/null; then
        printf "%dG" $(( KBLOCKS / 1048576 ))
    elif [ "$KBLOCKS" -ge 1024 ] 2>/dev/null; then
        printf "%dM" $(( KBLOCKS / 1024 ))
    else
        printf "%dK" "$KBLOCKS"
    fi
}

# ── Root check ────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "Must run as root"

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in fdisk mkfs.fat mkfs.btrfs btrfs blkid; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

# =============================================================================
#  STEP 1 — List whole drives and let user pick one
# =============================================================================
header "STEP 1 — Available drives"
echo ""
printf "  ${BLD}%-4s  %-12s  %-8s  %s${RST}\n" "Num" "Device" "Size" "Model"
printf "  %s\n" "--------------------------------------------"

IDX=0
DRIVE_LIST=""

# Read whole disks only from /proc/partitions
# A whole disk: name has no trailing digit after the device letters
# (sda, sdb, nvme0n1, vda etc) — but nvme ends in digit so we match
# any name that has NO partition suffix (no p1/p2 for nvme, no digit for sd)
while read -r MAJ MIN BLOCKS NAME; do
    # Skip header and blank
    echo "$NAME" | grep -qE '^[a-z]' || continue
    # Skip partitions: sda1, sdb2, nvme0n1p1, vda1 etc
    echo "$NAME" | grep -qE 'p[0-9]+$|[a-z][0-9]+$' && continue
    # Skip loop, ram, sr
    echo "$NAME" | grep -qE '^(loop|ram|sr|fd)' && continue

    DEV="/dev/${NAME}"
    [ -b "$DEV" ] || continue

    SIZE=$(human_size "$BLOCKS")

    # Try to get model from sysfs
    MODEL=""
    if [ -f "/sys/block/${NAME}/device/model" ]; then
        MODEL=$(cat "/sys/block/${NAME}/device/model" 2>/dev/null | tr -d '\n' | sed 's/  */ /g')
    fi

    IDX=$(( IDX + 1 ))
    printf "  ${CYN}%-4s${RST}  %-12s  %-8s  %s\n" "$IDX" "$DEV" "$SIZE" "${MODEL:-(no model info)}"
    DRIVE_LIST="${DRIVE_LIST}${IDX}|${DEV}|${SIZE}
"
done < /proc/partitions

echo ""

if [ "$IDX" -eq 0 ]; then
    die "No drives detected in /proc/partitions. Cannot continue."
fi

# =============================================================================
#  STEP 2 — User picks the drive
# =============================================================================
header "STEP 2 — Select drive to partition"
echo ""
warn "THIS WILL ERASE ALL DATA ON THE SELECTED DRIVE."
echo ""

CHOSEN_DEV=""
while true; do
    printf "${CYN}Enter drive number (1-${IDX}): ${RST}"
    read -r INPUT

    # Must be a number in range
    if ! echo "$INPUT" | grep -qE '^[0-9]+$'; then
        warn "Please enter a number"
        continue
    fi
    if [ "$INPUT" -lt 1 ] || [ "$INPUT" -gt "$IDX" ] 2>/dev/null; then
        warn "Number must be between 1 and $IDX"
        continue
    fi

    # Resolve number to device
    CHOSEN_DEV=$(echo "$DRIVE_LIST" | while IFS='|' read -r I DEV SZ; do
        [ "$I" = "$INPUT" ] && printf "%s" "$DEV" && break
    done)

    [ -n "$CHOSEN_DEV" ] || { warn "Could not resolve selection — try again"; continue; }
    break
done

CHOSEN_SIZE=$(echo "$DRIVE_LIST" | while IFS='|' read -r I DEV SZ; do
    [ "$DEV" = "$CHOSEN_DEV" ] && printf "%s" "$SZ" && break
done)

echo ""
printf "  ${BLD}Selected : ${CYN}%s${RST}  (%s)\n" "$CHOSEN_DEV" "$CHOSEN_SIZE"
echo ""
warn "ALL DATA ON $CHOSEN_DEV WILL BE PERMANENTLY DESTROYED."
printf "${RED}Type YES in capitals to confirm: ${RST}"
read -r CONFIRM
[ "$CONFIRM" = "YES" ] || die "Aborted — drive not modified."

# Derive partition names (nvme/mmcblk use p1/p2, others use 1/2)
case "$CHOSEN_DEV" in
    /dev/nvme*|/dev/mmcblk*)
        EFI_PART="${CHOSEN_DEV}p1"
        BTRFS_PART="${CHOSEN_DEV}p2"
        ;;
    *)
        EFI_PART="${CHOSEN_DEV}1"
        BTRFS_PART="${CHOSEN_DEV}2"
        ;;
esac

# =============================================================================
#  STEP 3 — Unmount anything using this drive
# =============================================================================
header "STEP 3 — Unmounting any existing mounts on $CHOSEN_DEV"

for extra in /target/proc /target/sys /target/dev/pts /target/dev /target/run; do
    if is_mounted "$extra"; then
        info "Unmounting $extra"
        umount -l "$extra" 2>/dev/null || true
    fi
done

# Unmount all partitions of this drive (reverse order)
for MP in /target/boot/efi /target/home /target/root /target/var/log \
          /target/tmp /target/opt /target /mnt; do
    if is_mounted "$MP"; then
        info "Unmounting $MP"
        umount "$MP" 2>/dev/null || umount -l "$MP" 2>/dev/null || true
    fi
done

# Also unmount any partition on the chosen drive directly
grep "^${CHOSEN_DEV}" /proc/mounts 2>/dev/null | awk '{print $2}' | sort -r | while read -r MP; do
    info "Unmounting leftover: $MP"
    umount "$MP" 2>/dev/null || umount -l "$MP" 2>/dev/null || true
done

ok "Unmount complete"

# =============================================================================
#  STEP 4 — Partition the drive
# =============================================================================
header "STEP 4 — Partitioning $CHOSEN_DEV"
info "Creating GPT partition table with:"
info "  Partition 1 : 500M  EFI System (FAT32)"
info "  Partition 2 : rest  Linux filesystem (BTRFS)"
echo ""

# Use fdisk with a heredoc — compatible with busybox fdisk
# g = new GPT, n = new partition, t = type, w = write
fdisk "$CHOSEN_DEV" <<FDISK_CMDS
g
n
1

+500M
t
1
n
2


w
FDISK_CMDS

ok "Partition table written"

# Give kernel a moment to register new partitions
sleep 2

# Force kernel re-read (busybox-safe)
blockdev --rereadpt "$CHOSEN_DEV" 2>/dev/null || true
sleep 1

# Verify partitions exist
[ -b "$EFI_PART" ]   || die "EFI partition $EFI_PART not found after partitioning"
[ -b "$BTRFS_PART" ] || die "BTRFS partition $BTRFS_PART not found after partitioning"
ok "Partitions confirmed: $EFI_PART  $BTRFS_PART"

# =============================================================================
#  STEP 5 — Format partitions
# =============================================================================
header "STEP 5 — Formatting partitions"

info "Formatting $EFI_PART as FAT32 (EFI)..."
mkfs.fat -F32 "$EFI_PART" || die "Failed to format EFI partition"
ok "EFI partition formatted"

info "Formatting $BTRFS_PART as BTRFS..."
mkfs.btrfs -f "$BTRFS_PART" || die "Failed to format BTRFS partition"
ok "BTRFS partition formatted"

# =============================================================================
#  STEP 6 — Create BTRFS subvolumes
# =============================================================================
header "STEP 6 — Creating BTRFS subvolumes"

if is_mounted /mnt; then
    umount /mnt 2>/dev/null || umount -l /mnt 2>/dev/null || true
fi

mount "$BTRFS_PART" /mnt || die "Failed to mount $BTRFS_PART to /mnt"
ok "Mounted $BTRFS_PART -> /mnt"

# If installer already created @rootfs, rename it; otherwise create @
if [ -d /mnt/@rootfs ]; then
    mv /mnt/@rootfs /mnt/@ || die "Failed to rename @rootfs -> @"
    ok "Renamed @rootfs -> @"
elif [ ! -d "/mnt/@" ]; then
    btrfs subvolume create /mnt/@ || die "Failed to create @ subvolume"
    ok "Created subvolume @"
else
    warn "Subvolume @ already exists — skipping"
fi

for SUBVOL in @home @root @log @tmp @opt; do
    if [ -d "/mnt/${SUBVOL}" ]; then
        warn "Subvolume ${SUBVOL} already exists — skipping"
    else
        btrfs subvolume create "/mnt/${SUBVOL}" || die "Failed to create ${SUBVOL}"
        ok "Created subvolume ${SUBVOL}"
    fi
done

echo ""
info "All subvolumes:"
btrfs subvolume list /mnt
echo ""

umount /mnt || die "Failed to unmount /mnt"

# =============================================================================
#  STEP 7 — Mount subvolumes into /target
# =============================================================================
header "STEP 7 — Mounting subvolumes into /target"

BTRFS_OPTS="noatime,compress=zstd"

mkdir -p /target
mount -o "${BTRFS_OPTS},subvol=@" "$BTRFS_PART" /target \
    || die "Failed to mount @ -> /target"
ok "Mounted @ -> /target"

mkdir -p /target/boot/efi /target/home /target/root \
         /target/var/log /target/tmp /target/opt

mount -o "${BTRFS_OPTS},subvol=@home" "$BTRFS_PART" /target/home \
    || die "Failed to mount @home"
ok "Mounted @home    -> /target/home"

mount -o "${BTRFS_OPTS},subvol=@root" "$BTRFS_PART" /target/root \
    || die "Failed to mount @root"
ok "Mounted @root    -> /target/root"

mount -o "${BTRFS_OPTS},subvol=@log"  "$BTRFS_PART" /target/var/log \
    || die "Failed to mount @log"
ok "Mounted @log     -> /target/var/log"

mount -o "${BTRFS_OPTS},subvol=@tmp"  "$BTRFS_PART" /target/tmp \
    || die "Failed to mount @tmp"
ok "Mounted @tmp     -> /target/tmp"

mount -o "${BTRFS_OPTS},subvol=@opt"  "$BTRFS_PART" /target/opt \
    || die "Failed to mount @opt"
ok "Mounted @opt     -> /target/opt"

mount "$EFI_PART" /target/boot/efi \
    || die "Failed to mount EFI partition"
ok "Mounted EFI      -> /target/boot/efi"

# =============================================================================
#  STEP 8 — Write /target/etc/fstab
# =============================================================================
header "STEP 8 — Writing /target/etc/fstab"

BTRFS_UUID=$(blkid -s UUID -o value "$BTRFS_PART" 2>/dev/null)
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART" 2>/dev/null)

[ -n "$BTRFS_UUID" ] || die "Could not get UUID for $BTRFS_PART"
[ -n "$EFI_UUID" ]   || die "Could not get UUID for $EFI_PART"

info "BTRFS UUID : $BTRFS_UUID"
info "EFI UUID   : $EFI_UUID"

mkdir -p /target/etc

FSTAB="/target/etc/fstab"
[ -f "$FSTAB" ] && cp "$FSTAB" "${FSTAB}.bak" && info "Backed up old fstab to ${FSTAB}.bak"

cat > "$FSTAB" <<FSTAB
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name
# devices that works even if disks are added and removed. See fstab(5).
#
# systemd generates mount units based on this file, see systemd.mount(5).
# Please run 'systemctl daemon-reload' after making changes here.
#
# <file system>                              <mount point>   <type>   <options>                       <dump>  <pass>

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
info "Contents of new fstab:"
printf "  %s\n" "------------------------------------------------------"
cat "$FSTAB" | sed 's/^/  /'
printf "  %s\n" "------------------------------------------------------"

# =============================================================================
#  STEP 9 — Summary
# =============================================================================
header "STEP 9 — Verification"

echo ""
info "Active mounts under /target:"
grep "/target" /proc/mounts | awk '{printf "  %-35s -> %s\n", $1, $2}'

echo ""
info "BTRFS subvolumes on $BTRFS_PART:"
btrfs subvolume list /target | sed 's/^/  /'

echo ""
ok "============================================================"
ok "  Drive setup complete and ready for Timeshift!"
ok "============================================================"
echo ""
printf "  ${BLD}Drive   :${RST} %s\n"  "$CHOSEN_DEV"
printf "  ${BLD}EFI     :${RST} %s  (UUID: %s)\n" "$EFI_PART" "$EFI_UUID"
printf "  ${BLD}BTRFS   :${RST} %s  (UUID: %s)\n" "$BTRFS_PART" "$BTRFS_UUID"
printf "  ${BLD}Subvols :${RST} @  @home  @root  @log  @tmp  @opt\n"
echo ""
warn "Next steps:"
printf "  1. Press Ctrl+Alt+F1 to return to the Debian installer\n"
printf "  2. Complete the installation normally\n"
printf "  3. After first boot: install timeshift, select BTRFS mode\n"
printf "     Timeshift will auto-detect all subvolumes\n"
echo ""


