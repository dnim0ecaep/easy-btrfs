#!/bin/sh
# =============================================================================
#  btrfs-timeshift-setup.sh
#  Debian 13 installer TTY2 — BTRFS subvolume + Timeshift setup
#
#  Assumes:
#    - Debian installer already partitioned and installed the base system
#    - Partition 1 = EFI (vfat), Partition 2 = BTRFS (installer made @rootfs)
#
#  Run: sh btrfs-timeshift-setup.sh
# =============================================================================

# Colors
CYN='\033[1;36m'
GRN='\033[1;32m'
YEL='\033[1;33m'
RED='\033[1;31m'
BLD='\033[1m'
RST='\033[0m'

info()   { printf "${CYN}[INFO]${RST}  %s\n" "$*"; }
ok()     { printf "${GRN}[ OK ]${RST}  %s\n" "$*"; }
warn()   { printf "${YEL}[WARN]${RST}  %s\n" "$*"; }
die()    { printf "${RED}[ERR ]${RST}  %s\n" "$*" >&2; exit 1; }
header() { printf "\n${BLD}${YEL}=== %s ===${RST}\n\n" "$*"; }

# busybox-safe mounted check
is_mounted() { grep -qs "^[^ ]* $1 " /proc/mounts; }

# Find blkid in common installer locations
find_blkid() {
    for P in blkid /sbin/blkid /usr/sbin/blkid; do
        if [ -x "$P" ] || command -v "$P" >/dev/null 2>&1; then
            printf "%s" "$P"; return 0
        fi
    done
    return 1
}

get_uuid() { $BLKID -s UUID -o value "$1" 2>/dev/null; }
get_type() { $BLKID -s TYPE -o value "$1" 2>/dev/null; }

# Human readable size from /proc/partitions 1K blocks
hr_size() {
    B="$1"
    if   [ "$B" -ge 1073741824 ] 2>/dev/null; then printf "%d TB" $(( B / 1073741824 ))
    elif [ "$B" -ge 1048576    ] 2>/dev/null; then printf "%d GB" $(( B / 1048576 ))
    elif [ "$B" -ge 1024       ] 2>/dev/null; then printf "%d MB" $(( B / 1024 ))
    else printf "%d KB" "$B"
    fi
}

# ── Checks ────────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "Must run as root"

BLKID=$(find_blkid) || die "blkid not found (tried: blkid /sbin/blkid /usr/sbin/blkid)"
info "Using blkid: $BLKID"

command -v btrfs >/dev/null 2>&1 || die "btrfs not found"

# =============================================================================
#  STEP 1 — Show drives and let user pick one
# =============================================================================
header "Available drives"

# Build drive list from /proc/partitions (whole disks only)
IDX=0
NAMES=""   # newline separated drive names

while read -r MAJ MIN BLOCKS NAME; do
    # skip blank / header
    echo "$NAME" | grep -qE '^[a-zA-Z]' || continue
    # skip partitions — they contain a digit immediately after letters
    # sda1, sdb2, nvme0n1p1, mmcblk0p1 etc
    echo "$NAME" | grep -qE 'p[0-9]+$|[a-z][0-9]+$' && continue
    # skip non-drives
    echo "$NAME" | grep -qE '^(loop|ram|sr|fd|dm)' && continue
    [ -b "/dev/$NAME" ] || continue

    SIZE=$(hr_size "$BLOCKS")
    MODEL=""
    [ -r "/sys/block/$NAME/device/model" ] && \
        MODEL=$(tr -d '\n' < "/sys/block/$NAME/device/model")

    IDX=$(( IDX + 1 ))
    printf "  [%d]  /dev/%-12s  %-8s  %s\n" "$IDX" "$NAME" "$SIZE" "$MODEL"
    NAMES="${NAMES}${NAME}
"
done < /proc/partitions

[ "$IDX" -gt 0 ] || die "No drives found in /proc/partitions"
echo ""

# =============================================================================
#  STEP 2 — Pick a drive
# =============================================================================
CHOSEN_NAME=""
while true; do
    printf "${CYN}Select drive number [1-${IDX}]: ${RST}"
    read -r SEL
    echo "$SEL" | grep -qE '^[0-9]+$'        || { warn "Enter a number"; continue; }
    [ "$SEL" -ge 1 ] && [ "$SEL" -le "$IDX" ] || { warn "Must be 1 to $IDX"; continue; }

    # Pull the Nth line from NAMES
    CHOSEN_NAME=$(printf "%s" "$NAMES" | sed -n "${SEL}p")
    [ -n "$CHOSEN_NAME" ] || { warn "Could not resolve selection"; continue; }
    break
done

DISK="/dev/$CHOSEN_NAME"

# Detect partition suffix style: nvme/mmcblk use p1/p2, others use 1/2
case "$CHOSEN_NAME" in
    nvme*|mmcblk*) EFI_PART="${DISK}p1" ; BTRFS_PART="${DISK}p2" ;;
    *)             EFI_PART="${DISK}1"  ; BTRFS_PART="${DISK}2"  ;;
esac

echo ""
info "Disk  : $DISK"
info "EFI   : $EFI_PART"
info "BTRFS : $BTRFS_PART"
echo ""

[ -b "$EFI_PART"   ] || die "$EFI_PART not found — wrong disk?"
[ -b "$BTRFS_PART" ] || die "$BTRFS_PART not found — wrong disk?"

FSTYPE=$(get_type "$BTRFS_PART")
if [ "$FSTYPE" != "btrfs" ]; then
    warn "$BTRFS_PART is type '${FSTYPE:-unknown}', expected btrfs"
    printf "${YEL}Continue anyway? (yes/no): ${RST}"; read -r YN
    [ "$YN" = "yes" ] || die "Aborted"
fi

printf "${YEL}Confirm setup on $DISK? (yes/no): ${RST}"; read -r YN
[ "$YN" = "yes" ] || die "Aborted"

# =============================================================================
#  STEP 3 — Unmount /target and /mnt cleanly
# =============================================================================
header "Unmounting /target"

for MP in /target/proc /target/sys /target/dev/pts /target/dev \
          /target/run  /target/boot/efi /target/home /target/root \
          /target/var/log /target/tmp /target/opt /target /mnt; do
    if is_mounted "$MP"; then
        info "Unmounting $MP"
        umount "$MP" 2>/dev/null || umount -l "$MP" 2>/dev/null || true
    fi
done
ok "Done"

# =============================================================================
#  STEP 4 — Mount top-level BTRFS, rename @rootfs -> @
# =============================================================================
header "Setting up BTRFS subvolumes"

mount -o subvolid=5 "$BTRFS_PART" /mnt || die "Cannot mount top-level BTRFS on $BTRFS_PART"
ok "Mounted top-level -> /mnt"

info "Subvolumes found:"
btrfs subvolume list /mnt | sed 's/^/    /'
echo ""

if [ -d /mnt/@rootfs ] && [ ! -d /mnt/@ ]; then
    mv /mnt/@rootfs /mnt/@ || die "Failed to rename @rootfs -> @"
    ok "Renamed @rootfs -> @"
elif [ -d /mnt/@ ]; then
    warn "@ already exists — skipping rename"
else
    ls /mnt
    die "No @rootfs or @ found on $BTRFS_PART — is this the right disk?"
fi

# Create missing subvolumes
for SV in @home @root @log @tmp @opt; do
    if [ -d "/mnt/$SV" ]; then
        warn "$SV already exists — skipping"
    else
        btrfs subvolume create "/mnt/$SV" || die "Failed to create $SV"
        ok "Created $SV"
    fi
done

info "Final subvolume list:"
btrfs subvolume list /mnt | sed 's/^/    /'

umount /mnt || die "Failed to unmount /mnt"

# =============================================================================
#  STEP 5 — Mount subvolumes into /target
# =============================================================================
header "Mounting into /target"

OPT="noatime,compress=zstd"

mkdir -p /target
mount -o "${OPT},subvol=@"     "$BTRFS_PART" /target         || die "mount @ failed"
ok "@ -> /target"

mkdir -p /target/boot/efi /target/home /target/root \
         /target/var/log  /target/tmp  /target/opt

mount -o "${OPT},subvol=@home" "$BTRFS_PART" /target/home    || die "mount @home failed"
ok "@home -> /target/home"

mount -o "${OPT},subvol=@root" "$BTRFS_PART" /target/root    || die "mount @root failed"
ok "@root -> /target/root"

mount -o "${OPT},subvol=@log"  "$BTRFS_PART" /target/var/log || die "mount @log failed"
ok "@log  -> /target/var/log"

mount -o "${OPT},subvol=@tmp"  "$BTRFS_PART" /target/tmp     || die "mount @tmp failed"
ok "@tmp  -> /target/tmp"

mount -o "${OPT},subvol=@opt"  "$BTRFS_PART" /target/opt     || die "mount @opt failed"
ok "@opt  -> /target/opt"

mount "$EFI_PART" /target/boot/efi || die "mount EFI failed"
ok "EFI  -> /target/boot/efi"

# =============================================================================
#  STEP 6 — Write /target/etc/fstab
# =============================================================================
header "Writing /target/etc/fstab"

BUUID=$(get_uuid "$BTRFS_PART")
EUUID=$(get_uuid "$EFI_PART")

[ -n "$BUUID" ] || die "Could not get UUID for $BTRFS_PART"
[ -n "$EUUID" ] || die "Could not get UUID for $EFI_PART"

info "BTRFS UUID : $BUUID"
info "EFI UUID   : $EUUID"

FSTAB="/target/etc/fstab"
[ -f "$FSTAB" ] && cp "$FSTAB" "${FSTAB}.bak" && info "Backup: ${FSTAB}.bak"

cat > "$FSTAB" << FSTAB_EOF
# /etc/fstab
# <file system>                             <mount>      <type>  <options>                       <dump> <pass>
UUID=${BUUID}  /            btrfs  noatime,compress=zstd,subvol=@       0  0
UUID=${BUUID}  /home        btrfs  noatime,compress=zstd,subvol=@home   0  0
UUID=${BUUID}  /root        btrfs  noatime,compress=zstd,subvol=@root   0  0
UUID=${BUUID}  /var/log     btrfs  noatime,compress=zstd,subvol=@log    0  0
UUID=${BUUID}  /tmp         btrfs  noatime,compress=zstd,subvol=@tmp    0  0
UUID=${BUUID}  /opt         btrfs  noatime,compress=zstd,subvol=@opt    0  0
UUID=${EUUID}  /boot/efi    vfat   umask=0077                           0  1
FSTAB_EOF

ok "fstab written"
echo ""
cat "$FSTAB" | sed 's/^/  /'

# =============================================================================
#  Done
# =============================================================================
header "Complete"

printf "  ${BLD}%-10s${RST} %s\n" "Disk:"    "$DISK"
printf "  ${BLD}%-10s${RST} %s\n" "BTRFS:"   "$BTRFS_PART  (UUID: $BUUID)"
printf "  ${BLD}%-10s${RST} %s\n" "EFI:"     "$EFI_PART    (UUID: $EUUID)"
printf "  ${BLD}%-10s${RST} %s\n" "Subvols:" "@  @home  @root  @log  @tmp  @opt"
echo ""
warn "Next steps:"
printf "  1. Ctrl+Alt+F1 to return to the installer\n"
printf "  2. Let the installer finish\n"
printf "  3. After first boot: install timeshift, select BTRFS mode\n"
echo ""

