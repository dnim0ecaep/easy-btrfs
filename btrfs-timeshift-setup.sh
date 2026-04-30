#!/bin/sh
# btrfs-timeshift-wizard.sh
# ---------------------------------------------------------------
# Run from the Debian 13 installer's Alt-F2 shell — even at the
# earliest stage where lsblk, parted, mkfs.vfat etc. are NOT yet
# loaded. The script auto-installs the required udebs via anna-install.
#
# REQUIRES: network already configured in d-i (you wgetted this
# script, so that's already true).
#
# Workflow:
#   1. Alt-F2 from the installer (any time after network is up)
#   2. wget <url>/btrfs-timeshift-wizard.sh
#   3. sh btrfs-timeshift-wizard.sh
#   4. Pick drive, confirm, wait
#   5. Alt-F1, return to installer, do Manual partitioning
#
# POSIX sh, busybox-safe.
# ---------------------------------------------------------------

set -eu

EFI_SIZE_MIB=500
SUBVOLS="@ @home @root @srv @tmp @log @cache @snapshots"
WORK=/tmp/btrfs-prep
STATE=/tmp/btrfs-prep.env

die()   { echo "ERROR: $*" >&2; exit 1; }
info()  { echo "[*] $*"; }
warn()  { echo "[!] $*" >&2; }
banner(){ echo; echo "=== $* ==="; }

# ---- subcommand: fixfstab (post base-install) -----------------
if [ "${1:-}" = "fixfstab" ]; then
    [ "$(id -u)" = "0" ] || die "must run as root"
    [ -f "$STATE" ] || die "no state file at $STATE — run the wizard first"
    . "$STATE"
    TARGET=/target
    [ -d "$TARGET" ] || die "$TARGET does not exist — run after d-i base install"

    info "rewriting $TARGET/etc/fstab"
    [ -f "$WORK/fstab.snippet" ] || die "missing $WORK/fstab.snippet"
    cp "$TARGET/etc/fstab" "$TARGET/etc/fstab.bak.$(date +%s)" 2>/dev/null || true
    cp "$WORK/fstab.snippet" "$TARGET/etc/fstab"
    sed 's/^/    /' "$TARGET/etc/fstab"

    info "creating mount points inside $TARGET"
    for d in home root srv tmp var/log var/cache .snapshots boot/efi; do
        mkdir -p "$TARGET/$d"
    done

    OPTS="defaults,noatime,compress=zstd:3,space_cache=v2"
    for pair in "@home:/home" "@root:/root" "@srv:/srv" "@tmp:/tmp" \
                "@log:/var/log" "@cache:/var/cache" "@snapshots:/.snapshots"; do
        sv=$(echo "$pair" | cut -d: -f1)
        mp=$(echo "$pair" | cut -d: -f2)
        grep -q " $TARGET$mp " /proc/mounts 2>/dev/null && continue
        if mount -o "${OPTS},subvol=${sv}" "$ROOT_PART" "$TARGET$mp" 2>/dev/null; then
            info "  mounted $sv -> $TARGET$mp"
        else
            warn "  failed to mount $sv -> $TARGET$mp"
        fi
    done

    cat <<EOF

================================================================
  fstab fixed.  Backup: $TARGET/etc/fstab.bak.*
  Aux subvolumes mounted under $TARGET.
  Return to installer (Alt-F1) and finish.
================================================================
EOF
    exit 0
fi

# ---- preflight ------------------------------------------------
[ "$(id -u)" = "0" ] || die "must run as root"

# ---- step 0: load required udebs ------------------------------
banner "Step 0 of 3: Loading required d-i components"

need_udebs=""
add_udeb() {
    case " $need_udebs " in
        *" $1 "*) ;;
        *) need_udebs="$need_udebs $1" ;;
    esac
}

# Check each tool, queue its udeb if missing
command -v lsblk      >/dev/null 2>&1 || add_udeb util-linux-udeb
command -v blkid      >/dev/null 2>&1 || add_udeb util-linux-udeb
command -v wipefs     >/dev/null 2>&1 || add_udeb util-linux-udeb
command -v parted     >/dev/null 2>&1 || add_udeb parted-udeb
command -v partprobe  >/dev/null 2>&1 || add_udeb parted-udeb
command -v mkfs.vfat  >/dev/null 2>&1 || add_udeb dosfstools-udeb
command -v mkfs.btrfs >/dev/null 2>&1 || add_udeb partman-btrfs
command -v btrfs      >/dev/null 2>&1 || add_udeb partman-btrfs

if [ -n "$need_udebs" ]; then
    info "missing tools detected, fetching udebs:$need_udebs"

    if ! command -v anna-install >/dev/null 2>&1; then
        die "anna-install not present — must run inside the Debian installer"
    fi

    # Verify network is actually up
    has_route=0
    if command -v ip >/dev/null 2>&1; then
        ip route 2>/dev/null | grep -q '^default' && has_route=1
    fi
    if [ "$has_route" = "0" ] && command -v route >/dev/null 2>&1; then
        route -n 2>/dev/null | grep -q '^0\.0\.0\.0' && has_route=1
    fi
    [ "$has_route" = "1" ] || die "no default route — configure network in installer first (main menu -> Configure the network)"

    for u in $need_udebs; do
        info "  anna-install $u"
        if ! anna-install "$u" >/tmp/anna.log 2>&1; then
            warn "anna-install $u failed; log:"
            cat /tmp/anna.log >&2
            die "could not load $u"
        fi
    done

    # Verify
    still_missing=""
    for t in lsblk wipefs blkid parted partprobe mkfs.vfat mkfs.btrfs btrfs; do
        command -v "$t" >/dev/null 2>&1 || still_missing="$still_missing $t"
    done
    [ -z "$still_missing" ] || die "still missing after udeb install:$still_missing"
    info "all required tools now available"
else
    info "all required tools already present"
fi

# ---- step 1: list drives --------------------------------------
echo
echo "================================================================"
echo "  Debian 13 BTRFS + Timeshift Drive Preparation Wizard"
echo "================================================================"

banner "Step 1 of 3: Choose a drive"
echo

mkdir -p "$WORK"
: > "$WORK/drives.list"

printf '  %-4s %-14s %-10s %s\n' "NUM" "DEVICE" "SIZE" "MODEL"
printf '  %-4s %-14s %-10s %s\n' "---" "------" "----" "-----"

# Identify root device to flag/refuse it
ROOTSRC=$(awk '$2=="/"{print $1; exit}' /proc/mounts 2>/dev/null || true)
ROOTDISK=""
if [ -n "$ROOTSRC" ]; then
    rn=$(basename "$ROOTSRC")
    case "$rn" in
        nvme*|mmcblk*) ROOTDISK=$(echo "$rn" | sed 's/p[0-9]*$//') ;;
        *)             ROOTDISK=$(echo "$rn" | sed 's/[0-9]*$//')  ;;
    esac
fi

i=1
lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null > "$WORK/disks.raw"
while IFS= read -r line; do
    name=$(echo  "$line" | awk '{print $1}')
    size=$(echo  "$line" | awk '{print $2}')
    type=$(echo  "$line" | awk '{print $3}')
    model=$(echo "$line" | awk '{for(j=4;j<=NF;j++) printf "%s ",$j; print ""}')
    [ "$type" = "disk" ] || continue
    case "$name" in loop*|sr*|zram*|fd*|ram*) continue ;; esac
    flag=""
    [ "$name" = "$ROOTDISK" ] && flag=" (LIVE/IN-USE)"
    printf '  %-4s %-14s %-10s %s%s\n' "$i" "/dev/$name" "$size" "$model" "$flag"
    echo "/dev/$name" >> "$WORK/drives.list"
    i=$((i+1))
done < "$WORK/disks.raw"

echo
[ -s "$WORK/drives.list" ] || die "no drives detected"

count=$(wc -l < "$WORK/drives.list" | tr -d ' ')
printf 'Enter drive number (1-%s), or q to quit: ' "$count"
read sel

case "$sel" in
    q|Q) info "cancelled"; exit 0 ;;
    '') die "empty selection" ;;
    *[!0-9]*) die "not a number: $sel" ;;
esac
[ "$sel" -ge 1 ] && [ "$sel" -le "$count" ] || die "selection $sel out of range"

DRIVE=$(sed -n "${sel}p" "$WORK/drives.list")
[ -b "$DRIVE" ] || die "$DRIVE is not a block device"

DRIVE_NAME=$(basename "$DRIVE")
[ "$DRIVE_NAME" = "$ROOTDISK" ] && die "$DRIVE is the live/running drive — refusing"

DRIVE_SIZE=$(lsblk -dn -o SIZE "$DRIVE" | tr -d ' ')

# ---- step 2: confirm ------------------------------------------
banner "Step 2 of 3: Confirm"
cat <<EOF

  Selected drive:   $DRIVE   ($DRIVE_SIZE)

  Will create:
    Partition 1:    ${EFI_SIZE_MIB} MiB  FAT32   EFI System Partition
    Partition 2:    remainder           BTRFS   Timeshift layout

  BTRFS subvolumes (Timeshift-compatible):
    @            -> /            (root subvolume)
    @home        -> /home
    @root        -> /root
    @srv         -> /srv
    @tmp         -> /tmp
    @log         -> /var/log     (excluded from snapshots)
    @cache       -> /var/cache   (excluded from snapshots)
    @snapshots   -> /.snapshots  (Timeshift target)

  WARNING: ALL DATA on $DRIVE will be PERMANENTLY DESTROYED.

EOF

printf 'Type YES (uppercase) to proceed: '
read ans
[ "$ans" = "YES" ] || die "aborted"

# ---- step 3: execute ------------------------------------------
banner "Step 3 of 3: Preparing $DRIVE"

if grep -q "^${DRIVE}" /proc/mounts; then
    info "unmounting existing partitions on $DRIVE"
    awk -v d="$DRIVE" '$1 ~ "^"d {print $2}' /proc/mounts | sort -r \
        | while read mp; do umount -lf "$mp" 2>/dev/null || true; done
fi

if grep -q "^${DRIVE}" /proc/swaps 2>/dev/null; then
    for s in $(awk -v d="$DRIVE" '$1 ~ "^"d {print $1}' /proc/swaps); do
        info "swapoff $s"
        swapoff "$s" || true
    done
fi

info "wiping existing signatures"
wipefs -a "$DRIVE" >/dev/null

info "creating GPT + ${EFI_SIZE_MIB}M EFI + BTRFS"
parted -s "$DRIVE" \
    mklabel gpt \
    mkpart ESP fat32 1MiB "${EFI_SIZE_MIB}MiB" \
    set 1 esp on \
    mkpart primary btrfs "${EFI_SIZE_MIB}MiB" 100%

partprobe "$DRIVE" >/dev/null 2>&1 || true
sleep 2

case "$DRIVE" in
    *nvme*|*mmcblk*|*loop*) EFI_PART="${DRIVE}p1"; ROOT_PART="${DRIVE}p2" ;;
    *)                      EFI_PART="${DRIVE}1";  ROOT_PART="${DRIVE}2"  ;;
esac
[ -b "$EFI_PART"  ] || die "EFI partition $EFI_PART not visible"
[ -b "$ROOT_PART" ] || die "BTRFS partition $ROOT_PART not visible"

info "formatting $EFI_PART as FAT32"
mkfs.vfat -F32 -n EFI "$EFI_PART" >/dev/null

info "formatting $ROOT_PART as BTRFS"
mkfs.btrfs -f -L debian-root "$ROOT_PART" >/dev/null

info "creating Timeshift subvolumes"
mkdir -p "$WORK/mnt"
mount -o compress=zstd:3,noatime "$ROOT_PART" "$WORK/mnt"
for sv in $SUBVOLS; do
    btrfs subvolume create "$WORK/mnt/$sv" >/dev/null
    echo "    + $sv"
done

DEFAULT_ID=$(btrfs subvolume list "$WORK/mnt" | awk '/path @$/{print $2; exit}')
if [ -n "${DEFAULT_ID:-}" ]; then
    btrfs subvolume set-default "$DEFAULT_ID" "$WORK/mnt"
    info "set @ (id $DEFAULT_ID) as default subvolume"
fi
umount "$WORK/mnt"

EFI_UUID=$(blkid  -s UUID -o value "$EFI_PART")
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

cat > "$STATE" <<EOF
DRIVE=$DRIVE
EFI_PART=$EFI_PART
ROOT_PART=$ROOT_PART
EFI_UUID=$EFI_UUID
ROOT_UUID=$ROOT_UUID
EOF

OPTS="defaults,noatime,compress=zstd:3,space_cache=v2"
cat > "$WORK/fstab.snippet" <<EOF
# Timeshift-compatible BTRFS layout — generated by btrfs-timeshift-wizard.sh
UUID=$ROOT_UUID  /              btrfs  ${OPTS},subvol=@           0 0
UUID=$ROOT_UUID  /home          btrfs  ${OPTS},subvol=@home       0 0
UUID=$ROOT_UUID  /root          btrfs  ${OPTS},subvol=@root       0 0
UUID=$ROOT_UUID  /srv           btrfs  ${OPTS},subvol=@srv        0 0
UUID=$ROOT_UUID  /tmp           btrfs  ${OPTS},subvol=@tmp        0 0
UUID=$ROOT_UUID  /var/log       btrfs  ${OPTS},subvol=@log        0 0
UUID=$ROOT_UUID  /var/cache     btrfs  ${OPTS},subvol=@cache      0 0
UUID=$ROOT_UUID  /.snapshots    btrfs  ${OPTS},subvol=@snapshots  0 0
UUID=$EFI_UUID   /boot/efi      vfat   umask=0077,shortname=winnt 0 1
EOF

cat <<EOF

================================================================
  DONE
================================================================
  Drive prepared:  $DRIVE
  EFI partition:   $EFI_PART   UUID=$EFI_UUID
  BTRFS root:      $ROOT_PART  UUID=$ROOT_UUID
  Subvolumes:      $SUBVOLS

  State saved:     $STATE
  fstab snippet:   $WORK/fstab.snippet

  ---------------------------------------------------------------
  NEXT STEPS
  ---------------------------------------------------------------
  1) Press Alt-F1 to return to the installer.

  2) In "Partition disks" choose Manual partitioning.

     For $EFI_PART:
        Use as:           EFI System Partition
        Mount point:      /boot/efi
        Format:           NO (do not reformat)

     For $ROOT_PART:
        Use as:           btrfs journaling file system
        Mount point:      /
        Mount options:    noatime
        Format:           NO (do not reformat)

  3) When base install completes and the installer offers reboot,
     instead choose "Execute a shell" and run:

        sh /path/to/btrfs-timeshift-wizard.sh fixfstab

     That writes /target/etc/fstab with the full subvolume layout.

  4) Exit shell, finish install, reboot. Then:
        sudo apt install -y timeshift
        sudo timeshift --btrfs --create --comments "baseline"
================================================================
EOF
