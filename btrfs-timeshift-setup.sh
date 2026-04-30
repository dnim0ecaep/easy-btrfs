#!/bin/sh
# btrfs-timeshift-wizard.sh
# ---------------------------------------------------------------
# Run from the Debian 13 installer's shell (Alt-F2 during install).
# Interactive wizard that prepares a drive for a Timeshift-compatible
# BTRFS subvolume layout, then hands back to the installer.
#
# Workflow:
#   1. Boot Debian installer, start install normally
#   2. When you reach (or before) the partitioning step, press Alt-F2
#   3. Press Enter to activate the console
#   4. Fetch and run this script:
#         wget <url>/btrfs-timeshift-wizard.sh
#         sh btrfs-timeshift-wizard.sh
#   5. Pick drive, confirm, let it run
#   6. Press Alt-F1 to return to the installer
#   7. In the partitioner: choose "Manual", assign existing partitions
#
# POSIX sh, busybox-safe. No bashisms. No colors (d-i tty is plain).
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

# ---- subcommand: fixfstab (run after d-i base install) --------
if [ "${1:-}" = "fixfstab" ]; then
    [ "$(id -u)" = "0" ] || die "must run as root"
    [ -f "$STATE" ] || die "no state file at $STATE — run the wizard first"
    . "$STATE"
    TARGET=/target
    [ -d "$TARGET" ] || die "$TARGET does not exist — run after d-i base install"

    info "rewriting $TARGET/etc/fstab"
    if [ ! -f "$WORK/fstab.snippet" ]; then
        die "missing $WORK/fstab.snippet — re-run the wizard"
    fi
    cp "$TARGET/etc/fstab" "$TARGET/etc/fstab.bak.$(date +%s)" 2>/dev/null || true
    cp "$WORK/fstab.snippet" "$TARGET/etc/fstab"
    sed 's/^/    /' "$TARGET/etc/fstab"

    # Make sure the auxiliary mount points exist inside target
    info "creating mount points inside $TARGET"
    for d in home root srv tmp var/log var/cache .snapshots boot/efi; do
        mkdir -p "$TARGET/$d"
    done

    # Mount the aux subvolumes now so any remaining d-i steps see them
    OPTS="defaults,noatime,compress=zstd:3,space_cache=v2"
    for pair in "@home:/home" "@root:/root" "@srv:/srv" "@tmp:/tmp" \
                "@log:/var/log" "@cache:/var/cache" "@snapshots:/.snapshots"; do
        sv=$(echo "$pair" | cut -d: -f1)
        mp=$(echo "$pair" | cut -d: -f2)
        mountpoint -q "$TARGET$mp" 2>/dev/null && continue
        mount -o "${OPTS},subvol=${sv}" "$ROOT_PART" "$TARGET$mp" \
            && info "  mounted $sv -> $TARGET$mp" \
            || warn "  failed to mount $sv -> $TARGET$mp (non-fatal)"
    done

    cat <<EOF

================================================================
  fstab fixed.
  Backup of original (if any): $TARGET/etc/fstab.bak.*
  Aux subvolumes mounted under $TARGET.

  Return to the installer (Alt-F1) and finish the install.
================================================================
EOF
    exit 0
fi

# ---- preflight ------------------------------------------------
[ "$(id -u)" = "0" ] || die "must run as root"

# d-i loads partman-btrfs udeb when btrfs is selected as a fs type;
# if the user hasn't done that yet, btrfs tools aren't present.
missing=""
for c in lsblk parted wipefs mkfs.vfat mkfs.btrfs btrfs blkid mount umount partprobe; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ -n "$missing" ]; then
    warn "missing tools:$missing"
    warn "in the installer, go back to the partitioner step once and pick"
    warn "'btrfs' as a filesystem on any partition — this loads the btrfs"
    warn "udeb. Then cancel out, return here (Alt-F2), and re-run."
    die  "required tools not available yet"
fi

# ---- step 1: list drives --------------------------------------
echo "================================================================"
echo "  Debian 13 BTRFS + Timeshift Drive Preparation Wizard"
echo "================================================================"

banner "Step 1 of 3: Choose a drive"
echo

mkdir -p "$WORK"
: > "$WORK/drives.list"

# Header
printf '  %-4s %-14s %-10s %s\n' "NUM" "DEVICE" "SIZE" "MODEL"
printf '  %-4s %-14s %-10s %s\n' "---" "------" "----" "-----"

# Find the device backing / so we can flag/refuse it
ROOTSRC=$(awk '$2=="/"{print $1; exit}' /proc/mounts 2>/dev/null || true)
# strip partition suffix to get parent disk name
ROOTDISK=""
if [ -n "$ROOTSRC" ]; then
    rn=$(basename "$ROOTSRC")
    case "$rn" in
        nvme*|mmcblk*) ROOTDISK=$(echo "$rn" | sed 's/p[0-9]*$//') ;;
        *)             ROOTDISK=$(echo "$rn" | sed 's/[0-9]*$//')  ;;
    esac
fi

i=1
lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null > "$WORK/lsblk.out"
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
done < "$WORK/lsblk.out"

echo
[ -s "$WORK/drives.list" ] || die "no drives detected"

count=$(wc -l < "$WORK/drives.list" | tr -d ' ')
printf 'Enter drive number (1-%s), or q to quit: ' "$count"
read sel

case "$sel" in
    q|Q) info "cancelled"; exit 0 ;;
    '')        die "empty selection" ;;
    *[!0-9]*)  die "not a number: $sel" ;;
esac

if [ "$sel" -lt 1 ] || [ "$sel" -gt "$count" ]; then
    die "selection $sel out of range (1-$count)"
fi

DRIVE=$(sed -n "${sel}p" "$WORK/drives.list")
[ -b "$DRIVE" ] || die "$DRIVE is not a block device"

# Refuse the live drive
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

# Unmount anything currently on this drive
if mount | grep -q "^${DRIVE}"; then
    info "unmounting existing partitions on $DRIVE"
    mount | awk -v d="$DRIVE" '$1 ~ "^"d {print $3}' | sort -r \
        | while read mp; do
            umount -lf "$mp" 2>/dev/null || true
        done
fi

# Disable swap on this drive
if grep -q "^${DRIVE}" /proc/swaps 2>/dev/null; then
    for s in $(awk -v d="$DRIVE" '$1 ~ "^"d {print $1}' /proc/swaps); do
        info "swapoff $s"
        swapoff "$s" || true
    done
fi

info "wiping existing signatures"
wipefs -a "$DRIVE" >/dev/null

info "creating GPT + ${EFI_SIZE_MIB}M EFI + BTRFS partitions"
parted -s "$DRIVE" \
    mklabel gpt \
    mkpart ESP fat32 1MiB "${EFI_SIZE_MIB}MiB" \
    set 1 esp on \
    mkpart primary btrfs "${EFI_SIZE_MIB}MiB" 100%

partprobe "$DRIVE" >/dev/null 2>&1 || true
sleep 2

# Partition naming: nvme/mmc use pN; sd/vd/hd use plain N
case "$DRIVE" in
    *nvme*|*mmcblk*|*loop*) EFI_PART="${DRIVE}p1"; ROOT_PART="${DRIVE}p2" ;;
    *)                      EFI_PART="${DRIVE}1";  ROOT_PART="${DRIVE}2"  ;;
esac

[ -b "$EFI_PART"  ] || die "EFI partition $EFI_PART not visible after partprobe"
[ -b "$ROOT_PART" ] || die "BTRFS partition $ROOT_PART not visible after partprobe"

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

# Set @ as the default subvolume so Timeshift behaves
DEFAULT_ID=$(btrfs subvolume list "$WORK/mnt" | awk '/path @$/{print $2; exit}')
if [ -n "${DEFAULT_ID:-}" ]; then
    btrfs subvolume set-default "$DEFAULT_ID" "$WORK/mnt"
    info "set @ (id $DEFAULT_ID) as default subvolume"
fi

umount "$WORK/mnt"

# Capture UUIDs for the post-install fstab fix
EFI_UUID=$(blkid  -s UUID -o value "$EFI_PART")
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

cat > "$STATE" <<EOF
DRIVE=$DRIVE
EFI_PART=$EFI_PART
ROOT_PART=$ROOT_PART
EFI_UUID=$EFI_UUID
ROOT_UUID=$ROOT_UUID
EOF

# Pre-build the fstab the user will need post-install
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

# ---- done -----------------------------------------------------
cat <<EOF

================================================================
  DONE
================================================================
  Drive prepared:  $DRIVE
  EFI partition:   $EFI_PART   UUID=$EFI_UUID
  BTRFS root:      $ROOT_PART  UUID=$ROOT_UUID
  Subvolumes:      $SUBVOLS

  State saved to:  $STATE
  fstab snippet:   $WORK/fstab.snippet

  ---------------------------------------------------------------
  NEXT STEPS
  ---------------------------------------------------------------
  1) Press Alt-F1 to return to the Debian installer.

  2) When the partitioner runs (or re-run it from the menu):
     - Choose:  Manual partitioning
     - You will see the existing partitions on $DRIVE.

     For $EFI_PART:
        Use as:           EFI System Partition
        Mount point:      /boot/efi
        Format:           NO (do not reformat)

     For $ROOT_PART:
        Use as:           btrfs journaling file system
        Mount point:      /
        Mount options:    noatime
        Format:           NO (do not reformat)
        ** subvol=@ is set as the DEFAULT subvolume, so the
        installer will land on @ automatically. **

  3) Continue install. When base install finishes and the installer
     offers to reboot, instead choose:
        "Execute a shell in the installer environment"
     ...and run the post-install fstab step:

        sh btrfs-timeshift-wizard.sh fixfstab

     That copies the full Timeshift fstab into /target/etc/fstab,
     so /home, /var/log, /.snapshots etc. all mount correctly.

  4) Exit shell, finish install, reboot. After first boot:
        sudo apt install -y timeshift
        sudo timeshift-launcher
        -> choose BTRFS mode. Done.
================================================================
EOF

