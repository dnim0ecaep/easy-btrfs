#!/bin/sh
# =============================================================================
#  btrfs-timeshift-setup.sh
#  Debian 13 installer TTY2 shell — BTRFS + Timeshift setup
#
#  Run AFTER the Debian installer has installed the base system.
#  Ctrl+Alt+F2 -> press Enter -> sh btrfs-timeshift-setup.sh
#
#  Only uses what the Debian installer busybox shell has:
#    df, mount, umount, mkdir, mv, cat, grep, sed, awk, printf, read
#    btrfs subvolume commands
#    /proc/partitions, /proc/mounts
#    /sbin/blkid or /usr/sbin/blkid
# =============================================================================

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

is_mounted() { grep -qs " $1 " /proc/mounts; }

# Find blkid — not always in PATH in the installer shell
BLKID=""
for _B in /sbin/blkid /usr/sbin/blkid /bin/blkid blkid; do
    if [ -x "$_B" ]; then BLKID="$_B"; break; fi
done
[ -n "$BLKID" ] || die "Cannot find blkid in /sbin or /usr/sbin"

get_uuid() { "$BLKID" -s UUID -o value "$1" 2>/dev/null; }

# Size from /proc/partitions (1K blocks -> human)
hr() {
    B="$1"
    if   [ "$B" -ge 1073741824 ] 2>/dev/null; then printf "%d TB" $(( B/1073741824 ))
    elif [ "$B" -ge 1048576    ] 2>/dev/null; then printf "%d GB" $(( B/1048576 ))
    elif [ "$B" -ge 1024       ] 2>/dev/null; then printf "%d MB" $(( B/1024 ))
    else printf "%d KB" "$B"
    fi
}

[ "$(id -u)" -eq 0 ] || die "Must run as root"
command -v btrfs >/dev/null 2>&1 || die "btrfs not found"

# =============================================================================
#  Show drives — pick one
# =============================================================================
header "Available drives"

printf "  ${BLD}%-5s %-16s %-10s %s${RST}\n" "Num" "Device" "Size" "Model"
printf "  %s\n" "------------------------------------------------"

IDX=0
DNAMES=""
while read -r _maj _min BLOCKS NAME; do
    echo "$NAME" | grep -qE '^[a-zA-Z]'       || continue   # skip header/blank
    echo "$NAME" | grep -qE 'p[0-9]+$|[a-z][0-9]+$' && continue  # skip partitions
    echo "$NAME" | grep -qE '^(loop|ram|sr|fd|dm)' && continue    # skip non-drives
    [ -b "/dev/$NAME" ] || continue
    SIZE=$(hr "$BLOCKS")
    MODEL=""
    [ -r "/sys/block/$NAME/device/model" ] && \
        MODEL=$(tr -d '\n' < "/sys/block/$NAME/device/model")
    IDX=$(( IDX + 1 ))
    printf "  ${CYN}[%d]${RST}   %-16s %-10s %s\n" "$IDX" "/dev/$NAME" "$SIZE" "$MODEL"
    DNAMES="${DNAMES}${NAME}
"
done < /proc/partitions

[ "$IDX" -gt 0 ] || die "No drives found"
echo ""

while true; do
    printf "${CYN}Select drive number [1-${IDX}]: ${RST}"
    read -r SEL
    echo "$SEL" | grep -qE '^[0-9]+$'          || { warn "Enter a number"; continue; }
    [ "$SEL" -ge 1 ] && [ "$SEL" -le "$IDX" ]  || { warn "Must be 1-$IDX"; continue; }
    DNAME=$(printf "%s" "$DNAMES" | sed -n "${SEL}p")
    [ -n "$DNAME" ] && break
done

DISK="/dev/$DNAME"

# Partition names: nvme/mmcblk use p1/p2, sda/vda etc use 1/2
case "$DNAME" in
    nvme*|mmcblk*) EFI="${DISK}p1" ; BTRFS="${DISK}p2" ;;
    *)             EFI="${DISK}1"  ; BTRFS="${DISK}2"  ;;
esac

echo ""
info "Disk  : $DISK"
info "EFI   : $EFI"
info "BTRFS : $BTRFS"
echo ""

[ -b "$EFI"   ] || die "$EFI not found — is the disk partitioned?"
[ -b "$BTRFS" ] || die "$BTRFS not found — is the disk partitioned?"

printf "${YEL}Confirm? (yes/no): ${RST}"; read -r YN
[ "$YN" = "yes" ] || die "Aborted"

# =============================================================================
#  Slide 1: df -h, umount /target/boot/efi, umount /target,
#            mount <btrfs> /mnt, mv @rootfs/ @,
#            btrfs su cr @home @root @log @tmp @opt
# =============================================================================
header "Slide 1 — Unmount, mount to /mnt, create subvolumes"

info "Current mounts (df -h):"
df -h 2>/dev/null | sed 's/^/  /'
echo ""

# Unmount in the exact order shown on slide 1
if is_mounted /target/boot/efi; then
    umount /target/boot/efi || umount -l /target/boot/efi
    ok "umount /target/boot/efi"
fi
if is_mounted /target; then
    umount /target || umount -l /target
    ok "umount /target"
fi

# Also clear any other /target submounts the installer may have added
for MP in /target/proc /target/sys /target/dev/pts /target/dev /target/run \
          /target/home /target/root /target/var/log /target/tmp /target/opt; do
    if is_mounted "$MP"; then
        umount -l "$MP" 2>/dev/null || true
    fi
done

if is_mounted /mnt; then
    umount /mnt 2>/dev/null || umount -l /mnt 2>/dev/null || true
fi

# mount top-level BTRFS volume (subvolid=5 gives the real root, not a subvol)
mount -o subvolid=5 "$BTRFS" /mnt || die "mount $BTRFS /mnt failed"
ok "mount -o subvolid=5 $BTRFS /mnt"

info "Contents of /mnt:"
ls /mnt | sed 's/^/  /'
echo ""

info "Subvolumes on $BTRFS:"
btrfs subvolume list /mnt | sed 's/^/  /'
echo ""

# mv @rootfs/ @  (slide 1)
if [ -d /mnt/@rootfs ] && [ ! -d /mnt/@ ]; then
    mv /mnt/@rootfs /mnt/@ || die "mv @rootfs @ failed"
    ok "mv @rootfs/ @"
elif [ -d /mnt/@ ]; then
    warn "@ already exists — skipping mv"
    [ -d /mnt/@rootfs ] && warn "@rootfs also still present — you may delete it later"
else
    warn "Contents of /mnt:"
    ls -la /mnt | sed 's/^/  /'
    die "No @rootfs or @ found — mount may not be showing top-level BTRFS"
fi

# btrfs su cr @home @root @log @tmp @opt  (slide 1)
for SV in @home @root @log @tmp @opt; do
    if [ -d "/mnt/$SV" ]; then
        warn "$SV already exists — skipping"
    else
        btrfs subvolume create "/mnt/$SV" || die "btrfs su cr $SV failed"
        ok "btrfs su cr $SV"
    fi
done

# =============================================================================
#  Slide 2: mount -o noatime,compress=zstd,subvol=@ <btrfs> /target
#            mkdir -p all dirs
#            mount each subvolume
#            mount <efi> /target/boot/efi
# =============================================================================
header "Slide 2 — Mount subvolumes into /target"

umount /mnt || die "umount /mnt failed"

OPT="noatime,compress=zstd"

mkdir -p /target
mount -o "${OPT},subvol=@" "$BTRFS" /target || die "mount subvol=@ failed"
ok "mount -o ${OPT},subvol=@ $BTRFS /target"

mkdir -p /target/boot/efi
mkdir -p /target/home
mkdir -p /target/root
mkdir -p /target/var/log
mkdir -p /target/tmp
mkdir -p /target/opt

mount -o "${OPT},subvol=@home" "$BTRFS" /target/home    || die "mount @home failed"
ok "mount subvol=@home -> /target/home"

mount -o "${OPT},subvol=@root" "$BTRFS" /target/root    || die "mount @root failed"
ok "mount subvol=@root -> /target/root"

mount -o "${OPT},subvol=@log"  "$BTRFS" /target/var/log || die "mount @log failed"
ok "mount subvol=@log  -> /target/var/log"

mount -o "${OPT},subvol=@tmp"  "$BTRFS" /target/tmp     || die "mount @tmp failed"
ok "mount subvol=@tmp  -> /target/tmp"

mount -o "${OPT},subvol=@opt"  "$BTRFS" /target/opt     || die "mount @opt failed"
ok "mount subvol=@opt  -> /target/opt"

mount "$EFI" /target/boot/efi || die "mount $EFI /target/boot/efi failed"
ok "mount $EFI /target/boot/efi"

# =============================================================================
#  Slide 3: write /target/etc/fstab
# =============================================================================
header "Slide 3 — Write /target/etc/fstab"

BUUID=$(get_uuid "$BTRFS")
EUUID=$(get_uuid "$EFI")

[ -n "$BUUID" ] || die "Could not get UUID for $BTRFS"
[ -n "$EUUID" ] || die "Could not get UUID for $EFI"

info "BTRFS UUID : $BUUID"
info "EFI UUID   : $EUUID"

FSTAB="/target/etc/fstab"
[ -f "$FSTAB" ] && cp "$FSTAB" "${FSTAB}.bak" && info "Old fstab saved to ${FSTAB}.bak"

cat > "$FSTAB" << FSTAB_END
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name
# devices that works even if disks are added and removed. See fstab(5).
#
# systemd generates mount units based on this file, see systemd.mount(5).
# Please run 'systemctl daemon-reload' after making changes here.
#
# <file system>                             <mount point>  <type>  <options>                       <dump>  <pass>
# / was on $BTRFS during installation
UUID=$BUUID  /            btrfs  noatime,compress=zstd,subvol=@       0  0
UUID=$BUUID  /home        btrfs  noatime,compress=zstd,subvol=@home   0  0
UUID=$BUUID  /root        btrfs  noatime,compress=zstd,subvol=@root   0  0
UUID=$BUUID  /var/log     btrfs  noatime,compress=zstd,subvol=@log    0  0
UUID=$BUUID  /tmp         btrfs  noatime,compress=zstd,subvol=@tmp    0  0
UUID=$BUUID  /opt         btrfs  noatime,compress=zstd,subvol=@opt    0  0
# /boot/efi was on $EFI during installation
UUID=$EUUID  /boot/efi    vfat   umask=0077                           0  1
FSTAB_END

ok "fstab written"
echo ""
cat "$FSTAB" | sed 's/^/  /'

# =============================================================================
#  Done
# =============================================================================
header "Complete"

printf "  ${BLD}%-8s${RST} %s\n" "Disk:"    "$DISK"
printf "  ${BLD}%-8s${RST} %s  (UUID: %s)\n" "BTRFS:"  "$BTRFS" "$BUUID"
printf "  ${BLD}%-8s${RST} %s  (UUID: %s)\n" "EFI:"    "$EFI"   "$EUUID"
echo ""
warn "Press Ctrl+Alt+F1 to return to the installer, then let it finish."
echo ""
