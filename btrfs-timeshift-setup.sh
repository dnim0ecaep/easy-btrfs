#!/bin/sh
# btrfs-timeshift-prep.sh
# Debian 13 (Trixie) installer helper: prepare a drive with EFI + BTRFS
# in the Timeshift-compatible subvolume layout (@, @home, etc.).
#
# Designed to run inside the Debian installer's busybox/ash shell
# (Alt-F2 during install). POSIX sh, no bashisms.
#
# USAGE:
#   Phase 1 (BEFORE running the installer's partitioner):
#       sh btrfs-timeshift-prep.sh prep
#     -> wipes selected drive, creates EFI + BTRFS, makes subvolumes.
#     -> Then in d-i, choose "Manual" partitioning and assign:
#            partition 1 (vfat)  -> /boot/efi
#            partition 2 (btrfs) -> / with mount option subvol=@
#                                   (or skip mountpoint here and use
#                                   `finalize` afterwards — recommended)
#
#   Phase 2 (AFTER d-i finishes base install, BEFORE first reboot):
#     From the installer menu pick "Execute a shell" (or Alt-F2):
#       sh btrfs-timeshift-prep.sh finalize
#     -> mounts subvolumes under /target with correct options,
#     -> rewrites /target/etc/fstab,
#     -> ensures grub/efi paths are correct.
#
# Idempotent within a phase. Run with care — `prep` IS DESTRUCTIVE.

set -eu

EFI_SIZE_MIB=500
SUBVOLS="@ @home @root @srv @tmp @log @cache @snapshots"
MNT=/mnt/btrfs-prep
TARGET=/target

# ---- helpers ---------------------------------------------------------------

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[*] %s\n'  "$*"; }
warn() { printf '[!] %s\n'  "$*" >&2; }

need() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "missing required tool: $c"
    done
}

confirm() {
    # $1 = prompt, requires literal "YES"
    printf '%s\nType YES (uppercase) to proceed: ' "$1"
    read ans
    [ "$ans" = "YES" ] || die "aborted by user"
}

is_uefi() { [ -d /sys/firmware/efi ]; }

# ---- drive listing ---------------------------------------------------------

list_drives() {
    # Print: index  name  size  model
    info "Detected block devices (whole disks only):"
    printf '\n  %-4s %-12s %-10s %s\n' "IDX" "DEVICE" "SIZE" "MODEL"
    printf '  %-4s %-12s %-10s %s\n'   "---" "------"  "----"  "-----"
    i=1
    : > /tmp/drives.list
    # lsblk -dn: disks only, no header. Filter loop/rom/zram.
    lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null | while IFS= read -r line; do
        type=$(echo "$line" | awk '{print $3}')
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        model=$(echo "$line" | awk '{for(j=4;j<=NF;j++) printf "%s ",$j; print ""}')
        case "$type" in
            disk) ;;
            *) continue ;;
        esac
        case "$name" in
            loop*|sr*|zram*|fd*) continue ;;
        esac
        printf '  %-4s %-12s %-10s %s\n' "$i" "/dev/$name" "$size" "$model"
        printf '%s\n' "/dev/$name" >> /tmp/drives.list
        i=$((i+1))
    done
    echo
    [ -s /tmp/drives.list ] || die "no usable disks found"
}

pick_drive() {
    list_drives
    printf 'Select drive number to partition: '
    read sel
    case "$sel" in
        ''|*[!0-9]*) die "invalid selection: $sel" ;;
    esac
    DRIVE=$(sed -n "${sel}p" /tmp/drives.list)
    [ -n "${DRIVE:-}" ] || die "selection $sel out of range"
    [ -b "$DRIVE" ]      || die "$DRIVE is not a block device"
    info "Selected: $DRIVE"
}

# ---- partition naming (nvme0n1p1 vs sda1) ----------------------------------

part_name() {
    # $1=disk (/dev/nvme0n1 or /dev/sda), $2=part number
    case "$1" in
        *nvme*|*mmcblk*|*loop*) echo "${1}p${2}" ;;
        *)                      echo "${1}${2}"  ;;
    esac
}

# ---- safety: nothing on the target drive may be mounted --------------------

ensure_unmounted() {
    drive=$1
    # bail if any partition of this drive is mounted
    if grep -E "^${drive}[p0-9]*\s" /proc/mounts >/dev/null 2>&1; then
        warn "the following partitions on $drive are mounted:"
        grep -E "^${drive}[p0-9]*\s" /proc/mounts >&2
        die "unmount them first (umount ...) and retry"
    fi
    # turn off any active swap on this drive
    if grep -E "^${drive}" /proc/swaps >/dev/null 2>&1; then
        warn "disabling swap on $drive partitions"
        for s in $(awk -v d="$drive" '$1 ~ "^"d {print $1}' /proc/swaps); do
            swapoff "$s" || die "swapoff $s failed"
        done
    fi
}

# ---- PHASE 1: prep ---------------------------------------------------------

do_prep() {
    need lsblk parted wipefs mkfs.vfat mkfs.btrfs mount umount blkid partprobe

    is_uefi || warn "system is NOT booted in UEFI mode — a 500M EFI partition will still be created, but you must boot the installer in UEFI for it to be usable."

    pick_drive
    ensure_unmounted "$DRIVE"

    cat <<EOF

About to PERMANENTLY ERASE: $DRIVE
Layout:
   p1  ${EFI_SIZE_MIB}MiB  FAT32   EFI System Partition
   p2  remainder          BTRFS   subvols: $SUBVOLS

EOF
    confirm "This will destroy ALL data on $DRIVE."

    info "wiping signatures on $DRIVE"
    wipefs -a "$DRIVE" >/dev/null

    info "creating GPT + partitions with parted"
    parted -s "$DRIVE" \
        mklabel gpt \
        mkpart ESP fat32 1MiB "${EFI_SIZE_MIB}MiB" \
        set 1 esp on \
        mkpart primary btrfs "${EFI_SIZE_MIB}MiB" 100%

    partprobe "$DRIVE" || true
    sleep 1

    EFI_PART=$(part_name "$DRIVE" 1)
    ROOT_PART=$(part_name "$DRIVE" 2)
    [ -b "$EFI_PART"  ] || die "EFI partition $EFI_PART not found after partprobe"
    [ -b "$ROOT_PART" ] || die "BTRFS partition $ROOT_PART not found after partprobe"

    info "formatting EFI ($EFI_PART) as FAT32"
    mkfs.vfat -F32 -n EFI "$EFI_PART" >/dev/null

    info "formatting root ($ROOT_PART) as BTRFS"
    mkfs.btrfs -f -L debian-root "$ROOT_PART" >/dev/null

    info "creating Timeshift-compatible subvolumes"
    mkdir -p "$MNT"
    mount -o compress=zstd:3 "$ROOT_PART" "$MNT"
    for sv in $SUBVOLS; do
        btrfs subvolume create "$MNT/$sv" >/dev/null
        info "  created $sv"
    done
    # Set @ as default so naive boots land on it; Timeshift relies on this too.
    DEFAULT_ID=$(btrfs subvolume list "$MNT" | awk '/path @$/{print $2; exit}')
    [ -n "$DEFAULT_ID" ] && btrfs subvolume set-default "$DEFAULT_ID" "$MNT"
    umount "$MNT"

    # Persist info for finalize phase
    EFI_UUID=$(blkid -s UUID  -o value "$EFI_PART")
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    cat > /tmp/btrfs-prep.env <<EOF
DRIVE=$DRIVE
EFI_PART=$EFI_PART
ROOT_PART=$ROOT_PART
EFI_UUID=$EFI_UUID
ROOT_UUID=$ROOT_UUID
EOF

    cat <<EOF

================================================================
PREP COMPLETE
================================================================
Drive:        $DRIVE
EFI:          $EFI_PART  UUID=$EFI_UUID
BTRFS root:   $ROOT_PART UUID=$ROOT_UUID
Subvolumes:   $SUBVOLS

NEXT STEPS in the Debian installer:
  1. Return to the installer menu (Alt-F1).
  2. Choose "Detect disks" / restart the partitioner step.
  3. Use "Manual" partitioning. The partitions already exist —
     do NOT reformat them. Assign:
        $EFI_PART   -> use as: EFI System Partition,  mount: /boot/efi
        $ROOT_PART  -> use as: btrfs, mount: /,
                       options: subvol=@,compress=zstd:3,noatime,space_cache=v2
  4. Continue install. When base install finishes and the
     installer offers to reboot, instead pick "Execute a shell"
     and run:
            sh /path/to/btrfs-timeshift-prep.sh finalize
     to rewrite /target/etc/fstab with the full subvolume layout.
================================================================
EOF
}

# ---- PHASE 2: finalize -----------------------------------------------------

do_finalize() {
    need mount umount blkid btrfs

    # Recover env if available, else re-detect.
    if [ -f /tmp/btrfs-prep.env ]; then
        # shellcheck disable=SC1091
        . /tmp/btrfs-prep.env
    else
        warn "no /tmp/btrfs-prep.env found; please re-select the drive"
        pick_drive
        EFI_PART=$(part_name  "$DRIVE" 1)
        ROOT_PART=$(part_name "$DRIVE" 2)
        EFI_UUID=$(blkid  -s UUID -o value "$EFI_PART")
        ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    fi

    info "EFI=$EFI_PART  ROOT=$ROOT_PART"
    info "EFI_UUID=$EFI_UUID  ROOT_UUID=$ROOT_UUID"

    # The installer mounts / at /target. We need the BTRFS top-level to
    # rebind the rest of the subvolumes properly.
    if ! mountpoint -q "$TARGET" 2>/dev/null; then
        die "$TARGET is not mounted — run this AFTER the installer base step"
    fi

    # Mount points inside the target
    info "creating mountpoints inside $TARGET"
    mkdir -p \
        "$TARGET/boot/efi" \
        "$TARGET/home" \
        "$TARGET/root" \
        "$TARGET/srv"  \
        "$TARGET/tmp"  \
        "$TARGET/var/log" \
        "$TARGET/var/cache" \
        "$TARGET/.snapshots"

    OPTS_BASE="defaults,noatime,compress=zstd:3,space_cache=v2"

    # If the installer already mounted root without subvol=@, remount it.
    # Easiest: trust the installer mounted subvol=@; we only add the rest.
    info "mounting auxiliary subvolumes under $TARGET"
    mount_sv() {
        sv=$1; mp=$2
        mountpoint -q "$mp" && umount "$mp" 2>/dev/null || true
        mount -o "${OPTS_BASE},subvol=${sv}" "$ROOT_PART" "$mp"
    }
    mount_sv @home      "$TARGET/home"
    mount_sv @root      "$TARGET/root"
    mount_sv @srv       "$TARGET/srv"
    mount_sv @tmp       "$TARGET/tmp"
    mount_sv @log       "$TARGET/var/log"
    mount_sv @cache     "$TARGET/var/cache"
    mount_sv @snapshots "$TARGET/.snapshots"

    # Mount EFI if not already
    if ! mountpoint -q "$TARGET/boot/efi"; then
        mount "$EFI_PART" "$TARGET/boot/efi"
    fi

    info "writing $TARGET/etc/fstab"
    cat > "$TARGET/etc/fstab" <<EOF
# /etc/fstab — generated by btrfs-timeshift-prep.sh
# Timeshift-compatible BTRFS layout. Do not rename @ or @home.

# /  (subvol=@)
UUID=$ROOT_UUID  /              btrfs  ${OPTS_BASE},subvol=@           0 0

# /home
UUID=$ROOT_UUID  /home          btrfs  ${OPTS_BASE},subvol=@home      0 0

# /root
UUID=$ROOT_UUID  /root          btrfs  ${OPTS_BASE},subvol=@root      0 0

# /srv
UUID=$ROOT_UUID  /srv           btrfs  ${OPTS_BASE},subvol=@srv       0 0

# /tmp  (excluded from snapshots)
UUID=$ROOT_UUID  /tmp           btrfs  ${OPTS_BASE},subvol=@tmp       0 0

# /var/log  (excluded from snapshots — keep logs across rollback)
UUID=$ROOT_UUID  /var/log       btrfs  ${OPTS_BASE},subvol=@log       0 0

# /var/cache  (excluded from snapshots)
UUID=$ROOT_UUID  /var/cache     btrfs  ${OPTS_BASE},subvol=@cache     0 0

# /.snapshots  (Timeshift target)
UUID=$ROOT_UUID  /.snapshots    btrfs  ${OPTS_BASE},subvol=@snapshots 0 0

# EFI
UUID=$EFI_UUID   /boot/efi      vfat   umask=0077,shortname=winnt     0 1
EOF

    info "fstab written:"
    sed 's/^/    /' "$TARGET/etc/fstab"

    # Bind /dev /proc /sys /run for chroot work the installer may still do
    for fs in dev proc sys run; do
        mountpoint -q "$TARGET/$fs" || mount --bind "/$fs" "$TARGET/$fs" || true
    done

    cat <<EOF

================================================================
FINALIZE COMPLETE
================================================================
fstab:           $TARGET/etc/fstab  (rewritten)
Subvolumes mounted under $TARGET as Timeshift expects.

Recommended next steps BEFORE reboot:
  1. chroot into the target if you need to reinstall grub:
         chroot $TARGET /bin/bash
         apt update && apt install -y btrfs-progs timeshift
         update-initramfs -u
         update-grub
         exit
  2. Exit shell, return to installer, finish & reboot.

After first boot:
  - Open Timeshift, choose BTRFS as the snapshot type.
  - Timeshift will detect @ and @home automatically.
================================================================
EOF
}

# ---- entrypoint ------------------------------------------------------------

case "${1:-}" in
    prep)     do_prep ;;
    finalize) do_finalize ;;
    list)     list_drives ;;
    *)
        cat <<EOF
Usage: $0 <command>

Commands:
  list       list candidate drives and exit
  prep       wipe + partition + format + create subvolumes (PHASE 1)
  finalize   mount subvolumes under /target and write fstab (PHASE 2)

Run 'prep' BEFORE the Debian installer's partitioner step, then run
'finalize' AFTER the installer's base install step but BEFORE reboot.
EOF
        exit 1
        ;;
esac
