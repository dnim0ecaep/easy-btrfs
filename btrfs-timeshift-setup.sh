#!/usr/bin/env bash
# =============================================================================
#  btrfs-timeshift-setup.sh
#  Debian 13 installer post-partition helper (automates slides 22-24)
#
#  Run from the Debian installer TTY (Ctrl+Alt+F2) AFTER the base system
#  has been installed but BEFORE the installer completes.
#
#  What this script does:
#    1. Lists available block devices with sizes so you can confirm the right one
#    2. Prompts you to pick your BTRFS partition AND your EFI partition
#    3. Unmounts /target/boot/efi and /target (slide 22 top block)
#    4. Mounts the BTRFS partition to /mnt
#    5. Renames @rootfs → @ (slide 22 mv command)
#    6. Creates subvolumes: @home @root @log @tmp @opt (slide 22 btrfs su cr)
#    7. Remounts all subvolumes into /target (slide 23 mount commands)
#    8. Writes a corrected /target/etc/fstab (slide 24 – replaces nano edits)
#
#  Tested against: Debian 13 (trixie) installer, UEFI NVMe/SATA targets
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[1;31m'; YEL='\033[1;33m'; GRN='\033[1;32m'
CYN='\033[1;36m'; BLD='\033[1m'; RST='\033[0m'

info()    { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()      { echo -e "${GRN}[ OK ]${RST}  $*"; }
warn()    { echo -e "${YEL}[WARN]${RST}  $*"; }
die()     { echo -e "${RED}[FAIL]${RST}  $*" >&2; exit 1; }
header()  { echo -e "\n${BLD}${YEL}══════════════════════════════════════════${RST}"; \
            echo -e "${BLD}${YEL}  $*${RST}"; \
            echo -e "${BLD}${YEL}══════════════════════════════════════════${RST}"; }

# ── Sanity checks ─────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Must run as root (try: sudo bash $0)"
for cmd in lsblk blkid btrfs mount umount mkdir sed grep awk; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
done

# ── STEP 1: Show all drives / partitions ─────────────────────────────────────
header "STEP 1 — Available block devices"
echo ""
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL 2>/dev/null || lsblk
echo ""
info "Also showing df -h for any already-mounted filesystems:"
df -h 2>/dev/null || true
echo ""

# ── STEP 2: Choose partitions ────────────────────────────────────────────────
header "STEP 2 — Select partitions"

# Build a numbered list of partitions for easier selection
mapfile -t PARTS < <(lsblk -lnpo NAME,SIZE,FSTYPE,MOUNTPOINT | awk '$1~/[0-9]$/ {print $0}')

echo ""
echo "  #   Device               Size    FSType      Mountpoint"
echo "  ─────────────────────────────────────────────────────────"
for i in "${!PARTS[@]}"; do
    printf "  %-3s %s\n" "$((i+1))" "${PARTS[$i]}"
done
echo ""

# ── BTRFS partition ──────────────────────────────────────────────────────────
while true; do
    read -rp "$(echo -e "${CYN}Enter the BTRFS root partition (e.g. /dev/nvme0n1p2 or /dev/sda2): ${RST}")" BTRFS_PART
    BTRFS_PART="${BTRFS_PART%/}"           # strip trailing slash
    [[ -b "$BTRFS_PART" ]] || { warn "Not a valid block device: $BTRFS_PART"; continue; }
    FSTYPE=$(lsblk -no FSTYPE "$BTRFS_PART" 2>/dev/null || true)
    if [[ "$FSTYPE" != "btrfs" ]]; then
        warn "Partition $BTRFS_PART has fstype '${FSTYPE:-<unknown>}', not btrfs."
        read -rp "$(echo -e "${YEL}Continue anyway? (yes/no): ${RST}")" FORCE
        [[ "$FORCE" == "yes" ]] || continue
    fi
    break
done

# ── EFI partition ────────────────────────────────────────────────────────────
while true; do
    read -rp "$(echo -e "${CYN}Enter the EFI partition (e.g. /dev/nvme0n1p1 or /dev/sda1): ${RST}")" EFI_PART
    EFI_PART="${EFI_PART%/}"
    [[ -b "$EFI_PART" ]] || { warn "Not a valid block device: $EFI_PART"; continue; }
    break
done

echo ""
info "BTRFS root : $BTRFS_PART"
info "EFI        : $EFI_PART"
echo ""
read -rp "$(echo -e "${YEL}Confirm and continue? (yes/no): ${RST}")" CONFIRM
[[ "$CONFIRM" == "yes" ]] || die "Aborted by user."

# ── STEP 3: Unmount /target (slide 22 top) ───────────────────────────────────
header "STEP 3 — Unmounting /target bind mounts"

# Unmount any bind-mounts the installer may have set up (proc/sys/dev etc.)
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

# ── STEP 4: Mount BTRFS to /mnt ──────────────────────────────────────────────
header "STEP 4 — Mount BTRFS partition to /mnt"
if mountpoint -q /mnt 2>/dev/null; then
    info "/mnt already mounted — unmounting first"
    umount /mnt
fi
mount "$BTRFS_PART" /mnt
ok "Mounted $BTRFS_PART → /mnt"

info "Contents of /mnt:"
ls -la /mnt
echo ""

# ── STEP 5: Rename @rootfs → @ ───────────────────────────────────────────────
header "STEP 5 — Rename @rootfs → @"

if [[ -d /mnt/@rootfs ]]; then
    mv /mnt/@rootfs/ /mnt/@
    ok "Renamed @rootfs → @"
elif [[ -d /mnt/@ ]]; then
    warn "/mnt/@ already exists — skipping rename (installer may have used @ already)"
else
    warn "Neither /mnt/@rootfs nor /mnt/@ found. Contents of /mnt:"
    ls -la /mnt
    die "Cannot continue — expected @rootfs or @ subvolume not found."
fi

# ── STEP 6: Create BTRFS subvolumes ──────────────────────────────────────────
header "STEP 6 — Creating BTRFS subvolumes"

for SUBVOL in @home @root @log @tmp @opt; do
    if [[ -d "/mnt/${SUBVOL}" ]]; then
        warn "Subvolume ${SUBVOL} already exists — skipping"
    else
        btrfs subvolume create "/mnt/${SUBVOL}"
        ok "Created subvolume ${SUBVOL}"
    fi
done

info "All subvolumes in /mnt:"
btrfs subvolume list /mnt

# ── STEP 7: Remount subvolumes into /target (slide 23) ───────────────────────
header "STEP 7 — Remounting subvolumes into /target"

umount /mnt
info "Unmounted /mnt (will now mount via subvolumes)"

# Mount root subvolume @
mkdir -p /target
mount -o noatime,compress=zstd,subvol=@ "$BTRFS_PART" /target
ok "Mounted @ → /target"

# Create mountpoint directories
for DIR in /target/boot/efi /target/home /target/root /target/var/log /target/tmp /target/opt; do
    mkdir -p "$DIR"
done

# Mount remaining subvolumes
declare -A SUBVOL_MAP=(
    [@home]="/target/home"
    [@root]="/target/root"
    [@log]="/target/var/log"
    [@tmp]="/target/tmp"
    [@opt]="/target/opt"
)

for SUBVOL in "${!SUBVOL_MAP[@]}"; do
    MOUNTPOINT="${SUBVOL_MAP[$SUBVOL]}"
    mount -o noatime,compress=zstd,subvol="$SUBVOL" "$BTRFS_PART" "$MOUNTPOINT"
    ok "Mounted ${SUBVOL} → ${MOUNTPOINT}"
done

# Mount EFI partition
mount "$EFI_PART" /target/boot/efi
ok "Mounted EFI ${EFI_PART} → /target/boot/efi"

# ── STEP 8: Rewrite /target/etc/fstab (slide 24) ─────────────────────────────
header "STEP 8 — Writing /target/etc/fstab"

# Get UUIDs
BTRFS_UUID=$(blkid -s UUID -o value "$BTRFS_PART")
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")

[[ -n "$BTRFS_UUID" ]] || die "Could not determine UUID for $BTRFS_PART"
[[ -n "$EFI_UUID" ]]   || die "Could not determine UUID for $EFI_PART"

info "BTRFS UUID : $BTRFS_UUID"
info "EFI UUID   : $EFI_UUID"

FSTAB_PATH="/target/etc/fstab"

# Back up existing fstab
if [[ -f "$FSTAB_PATH" ]]; then
    cp "$FSTAB_PATH" "${FSTAB_PATH}.bak.$(date +%Y%m%d_%H%M%S)"
    info "Backed up existing fstab to ${FSTAB_PATH}.bak.*"
fi

cat > "$FSTAB_PATH" <<EOF
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

# / was on ${BTRFS_PART} during installation
UUID=${BTRFS_UUID}  /            btrfs  noatime,compress=zstd,subvol=@       0  0
UUID=${BTRFS_UUID}  /home        btrfs  noatime,compress=zstd,subvol=@home   0  0
UUID=${BTRFS_UUID}  /root        btrfs  noatime,compress=zstd,subvol=@root   0  0
UUID=${BTRFS_UUID}  /var/log     btrfs  noatime,compress=zstd,subvol=@log    0  0
UUID=${BTRFS_UUID}  /tmp         btrfs  noatime,compress=zstd,subvol=@tmp    0  0
UUID=${BTRFS_UUID}  /opt         btrfs  noatime,compress=zstd,subvol=@opt    0  0

# /boot/efi was on ${EFI_PART} during installation
UUID=${EFI_UUID}    /boot/efi    vfat   umask=0077                           0  1
EOF

ok "fstab written to $FSTAB_PATH"

echo ""
info "New fstab contents:"
echo "──────────────────────────────────────────────────────"
cat "$FSTAB_PATH"
echo "──────────────────────────────────────────────────────"

# ── STEP 9: Verification ──────────────────────────────────────────────────────
header "STEP 9 — Verification"

info "Mounted filesystems under /target:"
findmnt --target /target 2>/dev/null || mount | grep target

echo ""
info "BTRFS subvolume list:"
btrfs subvolume list /target

echo ""
ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "  All done! BTRFS subvolumes set up for Timeshift."
ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
warn "Next steps:"
echo "  1. Press Ctrl+Alt+F1 to return to the installer"
echo "  2. Continue/finish the Debian installation normally"
echo "  3. After first boot, install Timeshift and set snapshot type to BTRFS"
echo "     Timeshift will auto-detect: @, @home, @root, @log, @tmp, @opt"
echo ""
