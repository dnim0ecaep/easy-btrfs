#!/bin/sh
# =============================================================================
#  btrfs-timeshift-setup.sh
#  Debian 13 (trixie) installer BTRFS + Timeshift subvolume setup
#  Automates slides 22-24 of the setup guide
#
#  Compatible with Debian installer busybox-udeb environment:
#  - No lsblk (not in installer busybox)
#  - No mountpoint command (not reliable in installer)
#  - No set -e / pipefail (busybox ash limitation)
#  - Uses: fdisk, blkid, df, cat /proc/partitions, /proc/mounts
#
#  Run from installer TTY2 (Ctrl+Alt+F2, press Enter to activate shell)
#  AFTER base system install, BEFORE installer finishes
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
header() { printf "\n${BLD}${YEL}==========================================\n  %s\n==========================================${RST}\n" "$*"; }

is_mounted() {
    grep -q " $1 " /proc/mounts 2>/dev/null
}

# ── Root check ────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "Must run as root"

# ── Check for btrfs tool ──────────────────────────────────────────────────────
command -v btrfs >/dev/null 2>&1 || die "'btrfs' not found. Is btrfs-progs installed?"
command -v blkid >/dev/null 2>&1 || die "'blkid' not found"

# ── STEP 1: Show drives ───────────────────────────────────────────────────────
header "STEP 1 — Available drives and partitions"
echo ""

# Build a clean numbered list from /proc/partitions + blkid
# /proc/partitions columns: major minor #blocks name
# We skip whole disks (no digit at end of name after letters) and
# the ramdisk/loop/cdrom entries, keeping only real partitions

printf "  ${BLD}%-4s %-16s %-10s %-10s %-36s${RST}\n" \
    "Num" "Device" "Size" "Type" "UUID / Label"
printf "  %s\n" "-----------------------------------------------------------------------"

IDX=0
PART_LIST=""   # newline-separated: "idx|device|size|type"

while read -r MAJ MIN BLOCKS NAME; do
    # Skip header line and blank lines
    echo "$NAME" | grep -qE '^[a-z]' || continue
    # Skip whole disks (sda, nvme0n1 etc — no trailing digit after letters+digits pattern)
    # A partition always ends in a digit AND has a parent disk
    echo "$NAME" | grep -qE '[0-9]$' || continue
    # Skip loop, ram, sr devices
    echo "$NAME" | grep -qE '^(loop|ram|sr)' && continue

    DEV="/dev/${NAME}"
    [ -b "$DEV" ] || continue

    # Size: blocks are 1K, convert to human readable
    KBLOCKS="$BLOCKS"
    if [ "$KBLOCKS" -ge 1073741824 ] 2>/dev/null; then
        SIZE="$(( KBLOCKS / 1073741824 ))T"
    elif [ "$KBLOCKS" -ge 1048576 ] 2>/dev/null; then
        SIZE="$(( KBLOCKS / 1048576 ))G"
    elif [ "$KBLOCKS" -ge 1024 ] 2>/dev/null; then
        SIZE="$(( KBLOCKS / 1024 ))M"
    else
        SIZE="${KBLOCKS}K"
    fi

    TYPE=$(blkid -s TYPE  -o value "$DEV" 2>/dev/null || true)
    UUID=$(blkid -s UUID  -o value "$DEV" 2>/dev/null || true)
    LABEL=$(blkid -s LABEL -o value "$DEV" 2>/dev/null || true)

    EXTRA="${UUID}"
    [ -n "$LABEL" ] && EXTRA="${LABEL} (${UUID})"

    IDX=$(( IDX + 1 ))
    printf "  ${CYN}%-4s${RST} %-16s %-10s %-10s %-36s\n" \
        "$IDX" "$DEV" "$SIZE" "${TYPE:--}" "${EXTRA:--}"

    PART_LIST="${PART_LIST}${IDX}|${DEV}|${SIZE}|${TYPE}
"
done < /proc/partitions

echo ""

if [ "$IDX" -eq 0 ]; then
    warn "No partitions detected via /proc/partitions — showing raw fdisk output instead:"
    fdisk -l 2>/dev/null || true
    echo ""
fi

# Helper: look up device by number from PART_LIST
get_part_by_num() {
    NUM="$1"
    echo "$PART_LIST" | while IFS='|' read -r I DEV SZ TY; do
        [ "$I" = "$NUM" ] && printf "%s" "$DEV" && break
    done
}

# ── STEP 2: Choose partitions ────────────────────────────────────────────────
header "STEP 2 — Select partitions"
echo ""
echo "  Enter the NUMBER from the list above, or type the full device path."
echo "  BTRFS partition = the large one with type 'btrfs'"
echo "  EFI partition   = the small ~500M one with type 'vfat'"
echo ""

# BTRFS partition
BTRFS_PART=""
while true; do
    printf "${CYN}BTRFS root partition (number or path): ${RST}"
    read -r INPUT
    INPUT="${INPUT%/}"

    # If numeric, resolve to device
    if echo "$INPUT" | grep -qE '^[0-9]+$'; then
        BTRFS_PART=$(get_part_by_num "$INPUT")
        if [ -z "$BTRFS_PART" ]; then
            warn "No partition with number $INPUT — try again"
            continue
        fi
        info "Selected: $BTRFS_PART"
    else
        BTRFS_PART="$INPUT"
    fi

    if [ ! -b "$BTRFS_PART" ]; then
        warn "Not a valid block device: $BTRFS_PART — try again"
        continue
    fi
    FSTYPE=$(blkid -s TYPE -o value "$BTRFS_PART" 2>/dev/null || true)
    if [ "$FSTYPE" != "btrfs" ]; then
        warn "$BTRFS_PART has type '${FSTYPE:-unknown}', expected btrfs."
        printf "${YEL}Continue anyway? (yes/no): ${RST}"
        read -r FORCE
        [ "$FORCE" = "yes" ] || continue
    fi
    break
done

# EFI partition
EFI_PART=""
while true; do
    printf "${CYN}EFI partition (number or path): ${RST}"
    read -r INPUT
    INPUT="${INPUT%/}"

    if echo "$INPUT" | grep -qE '^[0-9]+$'; then
        EFI_PART=$(get_part_by_num "$INPUT")
        if [ -z "$EFI_PART" ]; then
            warn "No partition with number $INPUT — try again"
            continue
        fi
        info "Selected: $EFI_PART"
    else
        EFI_PART="$INPUT"
    fi

    if [ ! -b "$EFI_PART" ]; then
        warn "Not a valid block device: $EFI_PART — try again"
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
[ "$CONFIRM" = "yes" ] || die "Aborted."

# ── STEP 3: Unmount /target ───────────────────────────────────────────────────
header "STEP 3 — Unmounting /target (slide 22)"

for extra in /target/proc /target/sys /target/dev/pts /target/dev /target/run; do
    if is_mounted "$extra"; then
        info "Unmounting $extra"
        umount -l "$extra" 2>/dev/null || true
    fi
done

if is_mounted /target/boot/efi; then
    info "Unmounting /target/boot/efi"
    umount /target/boot/efi || die "Failed to unmount /target/boot/efi"
fi

if is_mounted /target; then
    info "Unmounting /target"
    umount /target || die "Failed to unmount /target"
fi

ok "Unmount complete"

# ── STEP 4: Mount BTRFS to /mnt ──────────────────────────────────────────────
header "STEP 4 — Mount BTRFS to /mnt (slide 22)"

if is_mounted /mnt; then
    info "/mnt is mounted — unmounting"
    umount /mnt || die "Failed to unmount /mnt"
fi

mount "$BTRFS_PART" /mnt || die "Failed to mount $BTRFS_PART to /mnt"
ok "Mounted $BTRFS_PART -> /mnt"

echo ""
info "Contents of /mnt:"
ls -la /mnt
echo ""

# ── STEP 5: Rename @rootfs -> @ ──────────────────────────────────────────────
header "STEP 5 — Rename @rootfs -> @ (slide 22)"

if [ -d /mnt/@rootfs ]; then
    mv /mnt/@rootfs /mnt/@ || die "Failed to rename @rootfs -> @"
    ok "Renamed @rootfs -> @"
elif [ -d "/mnt/@" ]; then
    warn "/mnt/@ already exists — skipping rename"
else
    info "Contents of /mnt:"
    ls -la /mnt
    die "Neither /mnt/@rootfs nor /mnt/@ found. Is $BTRFS_PART the right partition?"
fi

# ── STEP 6: Create subvolumes ─────────────────────────────────────────────────
header "STEP 6 — Creating BTRFS subvolumes (slide 22)"

for SUBVOL in @home @root @log @tmp @opt; do
    if [ -d "/mnt/${SUBVOL}" ]; then
        warn "Subvolume ${SUBVOL} already exists — skipping"
    else
        btrfs subvolume create "/mnt/${SUBVOL}" || die "Failed to create subvolume ${SUBVOL}"
        ok "Created ${SUBVOL}"
    fi
done

echo ""
info "All subvolumes:"
btrfs subvolume list /mnt

# ── STEP 7: Remount into /target ──────────────────────────────────────────────
header "STEP 7 — Remounting subvolumes into /target (slide 23)"

umount /mnt || die "Failed to unmount /mnt before subvol remount"
info "Unmounted /mnt — remounting via subvolumes"

mkdir -p /target || die "Failed to create /target"
mount -o noatime,compress=zstd,subvol=@ "$BTRFS_PART" /target \
    || die "Failed to mount @ -> /target"
ok "Mounted @ -> /target"

mkdir -p /target/boot/efi /target/home /target/root \
         /target/var/log /target/tmp /target/opt

mount -o noatime,compress=zstd,subvol=@home "$BTRFS_PART" /target/home \
    || die "Failed to mount @home"
ok "Mounted @home -> /target/home"

mount -o noatime,compress=zstd,subvol=@root "$BTRFS_PART" /target/root \
    || die "Failed to mount @root"
ok "Mounted @root -> /target/root"

mount -o noatime,compress=zstd,subvol=@log "$BTRFS_PART" /target/var/log \
    || die "Failed to mount @log"
ok "Mounted @log  -> /target/var/log"

mount -o noatime,compress=zstd,subvol=@tmp "$BTRFS_PART" /target/tmp \
    || die "Failed to mount @tmp"
ok "Mounted @tmp  -> /target/tmp"

mount -o noatime,compress=zstd,subvol=@opt "$BTRFS_PART" /target/opt \
    || die "Failed to mount @opt"
ok "Mounted @opt  -> /target/opt"

mount "$EFI_PART" /target/boot/efi \
    || die "Failed to mount EFI partition"
ok "Mounted EFI $EFI_PART -> /target/boot/efi"

# ── STEP 8: Write fstab ───────────────────────────────────────────────────────
header "STEP 8 — Writing /target/etc/fstab (slide 24)"

BTRFS_UUID=$(blkid -s UUID -o value "$BTRFS_PART" 2>/dev/null)
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART" 2>/dev/null)

[ -n "$BTRFS_UUID" ] || die "Could not get UUID for $BTRFS_PART"
[ -n "$EFI_UUID" ]   || die "Could not get UUID for $EFI_PART"

info "BTRFS UUID : $BTRFS_UUID"
info "EFI UUID   : $EFI_UUID"

FSTAB="/target/etc/fstab"

if [ -f "$FSTAB" ]; then
    cp "$FSTAB" "${FSTAB}.bak"
    info "Backed up existing fstab to ${FSTAB}.bak"
fi

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
info "New fstab contents:"
echo "------------------------------------------------------"
cat "$FSTAB"
echo "------------------------------------------------------"

# ── STEP 9: Verify ────────────────────────────────────────────────────────────
header "STEP 9 — Verification"

info "Mounts under /target:"
grep "/target" /proc/mounts || true

echo ""
info "BTRFS subvolumes:"
btrfs subvolume list /target

echo ""
ok "========================================="
ok "  Done! BTRFS + Timeshift setup complete."
ok "========================================="
echo ""
warn "Next steps:"
printf "  1. Press Ctrl+Alt+F1 to return to the installer\n"
printf "  2. Finish the Debian installation normally\n"
printf "  3. After first boot, install Timeshift, select BTRFS mode\n"
printf "     (auto-detects @, @home, @root, @log, @tmp, @opt)\n"
echo ""

