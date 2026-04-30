#!/bin/bash
# debian13-btrfs-autoinstall.sh
# ---------------------------------------------------------------
# Automated Debian 13 (Trixie) installer with Timeshift-compatible
# BTRFS subvolume layout. Run from a Debian/Ubuntu live ISO as root.
#
# What it does (zero-touch after drive selection):
#   1. Picks a target drive (interactive list, or --drive flag)
#   2. Wipes it, creates 500M EFI + rest BTRFS
#   3. Creates Timeshift subvolumes (@, @home, @root, @srv,
#      @tmp, @log, @cache, @snapshots)
#   4. debootstraps Debian trixie into @
#   5. Configures hostname, locale, timezone, user, fstab
#   6. Installs kernel, grub-efi, btrfs-progs, timeshift, ssh
#   7. Reboots into a working system
#
# REQUIRES: UEFI boot, internet, debootstrap, btrfs-progs, parted,
#           dosfstools, arch-install-scripts (for genfstab) OR fallback.
#           Script will apt-install anything missing in the live env.
#
# DESTRUCTIVE. Read CONFIG below. Run as root.
# ---------------------------------------------------------------

set -euo pipefail

# ============================================================
# CONFIG — edit these or override via flags
# ============================================================
HOSTNAME_DEFAULT="debian-btrfs"
USERNAME_DEFAULT="matt"
USERPASS_DEFAULT="changeme"          # CHANGE THIS or pass --password
ROOTPASS_DEFAULT="changeme"          # CHANGE THIS or pass --root-password
TIMEZONE_DEFAULT="America/New_York"
LOCALE_DEFAULT="en_US.UTF-8"
KEYMAP_DEFAULT="us"
MIRROR_DEFAULT="http://deb.debian.org/debian"
SUITE_DEFAULT="trixie"               # Debian 13
EFI_SIZE_MIB=500
SUBVOLS=(@ @home @root @srv @tmp @log @cache @snapshots)
EXTRA_PKGS_DEFAULT="sudo openssh-server network-manager firmware-linux \
  btrfs-progs timeshift grub-efi-amd64 efibootmgr os-prober \
  vim curl wget ca-certificates locales tzdata bash-completion"

# ============================================================
# Args
# ============================================================
DRIVE=""
HOSTNAME_VAL="$HOSTNAME_DEFAULT"
USERNAME_VAL="$USERNAME_DEFAULT"
USERPASS_VAL="$USERPASS_DEFAULT"
ROOTPASS_VAL="$ROOTPASS_DEFAULT"
TIMEZONE_VAL="$TIMEZONE_DEFAULT"
LOCALE_VAL="$LOCALE_DEFAULT"
KEYMAP_VAL="$KEYMAP_DEFAULT"
MIRROR_VAL="$MIRROR_DEFAULT"
SUITE_VAL="$SUITE_DEFAULT"
EXTRA_PKGS_VAL="$EXTRA_PKGS_DEFAULT"
ASSUME_YES=0
SKIP_REBOOT=0

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --drive /dev/X         Target drive (skip interactive picker)
  --hostname NAME        Hostname (default: $HOSTNAME_DEFAULT)
  --user NAME            Username to create (default: $USERNAME_DEFAULT)
  --password PASS        User password
  --root-password PASS   Root password
  --timezone TZ          e.g. America/New_York
  --locale LOC           e.g. en_US.UTF-8
  --keymap KM            e.g. us
  --mirror URL           Debian mirror
  --suite NAME           Debian suite (default: trixie)
  --extra-packages "p1 p2"  Extra packages to install in chroot
  --yes                  Skip confirmation prompts (UNATTENDED)
  --no-reboot            Don't reboot at the end
  -h, --help             This help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --drive)           DRIVE="$2";          shift 2 ;;
        --hostname)        HOSTNAME_VAL="$2";   shift 2 ;;
        --user)            USERNAME_VAL="$2";   shift 2 ;;
        --password)        USERPASS_VAL="$2";   shift 2 ;;
        --root-password)   ROOTPASS_VAL="$2";   shift 2 ;;
        --timezone)        TIMEZONE_VAL="$2";   shift 2 ;;
        --locale)          LOCALE_VAL="$2";     shift 2 ;;
        --keymap)          KEYMAP_VAL="$2";     shift 2 ;;
        --mirror)          MIRROR_VAL="$2";     shift 2 ;;
        --suite)           SUITE_VAL="$2";      shift 2 ;;
        --extra-packages)  EXTRA_PKGS_VAL="$EXTRA_PKGS_VAL $2"; shift 2 ;;
        --yes)             ASSUME_YES=1;        shift   ;;
        --no-reboot)       SKIP_REBOOT=1;       shift   ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

# ============================================================
# Helpers
# ============================================================
TARGET=/mnt/target
LOG=/var/log/debian13-btrfs-autoinstall.log

die()  { printf '\033[1;31m[X]\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;32m[*]\033[0m %s\n'  "$*" | tee -a "$LOG"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n'  "$*" >&2 | tee -a "$LOG"; }
step() { printf '\n\033[1;36m===\033[0m %s\n'  "$*" | tee -a "$LOG"; }

confirm() {
    [ "$ASSUME_YES" = "1" ] && return 0
    printf '%s\nType YES to proceed: ' "$1"
    read -r ans
    [ "$ans" = "YES" ] || die "aborted by user"
}

cleanup() {
    rc=$?
    set +e
    info "cleanup: unmounting $TARGET"
    for fs in dev/pts dev proc sys run; do
        mountpoint -q "$TARGET/$fs" && umount -lf "$TARGET/$fs" 2>/dev/null
    done
    mount | awk -v t="$TARGET" '$3 ~ "^"t {print $3}' | sort -r \
        | while read -r mp; do umount -lf "$mp" 2>/dev/null; done
    [ $rc -ne 0 ] && warn "exited with code $rc — see $LOG"
    exit $rc
}
trap cleanup EXIT INT TERM

require_root() { [ "$(id -u)" = "0" ] || die "must run as root"; }

require_uefi() {
    [ -d /sys/firmware/efi ] || die "system not booted in UEFI mode — this script requires UEFI"
}

ensure_tools() {
    step "ensuring required tools in live environment"
    local need_install=()
    for t in parted wipefs mkfs.vfat mkfs.btrfs btrfs debootstrap blkid lsblk partprobe curl; do
        command -v "$t" >/dev/null 2>&1 || need_install+=("$t")
    done
    if [ ${#need_install[@]} -gt 0 ]; then
        info "installing missing tools: ${need_install[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >>"$LOG" 2>&1 || warn "apt update failed (continuing)"
        apt-get install -y \
            parted dosfstools btrfs-progs debootstrap util-linux \
            arch-install-scripts curl gpg ca-certificates \
            >>"$LOG" 2>&1 || die "failed to install required tools — fix network/apt and retry"
    fi
}

# ============================================================
# Drive selection
# ============================================================
list_drives() {
    info "candidate drives:"
    printf '\n  %-4s %-14s %-10s %s\n' "IDX" "DEVICE" "SIZE" "MODEL"
    printf '  %-4s %-14s %-10s %s\n'   "---" "------" "----" "-----"
    : > /tmp/drives.list
    local i=1
    while IFS= read -r line; do
        local name size type model
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        type=$(echo "$line" | awk '{print $3}')
        model=$(echo "$line" | awk '{for(j=4;j<=NF;j++) printf "%s ",$j; print ""}')
        [ "$type" = "disk" ] || continue
        case "$name" in loop*|sr*|zram*|fd*) continue ;; esac
        printf '  %-4s %-14s %-10s %s\n' "$i" "/dev/$name" "$size" "$model"
        printf '%s\n' "/dev/$name" >> /tmp/drives.list
        i=$((i+1))
    done < <(lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null)
    echo
    [ -s /tmp/drives.list ] || die "no usable disks found"
}

pick_drive_interactive() {
    list_drives
    printf 'Select drive number: '
    read -r sel
    [[ "$sel" =~ ^[0-9]+$ ]] || die "invalid selection"
    DRIVE=$(sed -n "${sel}p" /tmp/drives.list)
    [ -n "$DRIVE" ] && [ -b "$DRIVE" ] || die "selection out of range"
}

part_name() {
    case "$1" in
        *nvme*|*mmcblk*|*loop*) echo "${1}p${2}" ;;
        *)                      echo "${1}${2}"  ;;
    esac
}

ensure_unmounted() {
    if mount | grep -q "^$DRIVE"; then
        warn "partitions on $DRIVE are mounted — unmounting"
        mount | awk -v d="$DRIVE" '$1 ~ "^"d {print $3}' | sort -r \
            | while read -r mp; do umount -lf "$mp" 2>/dev/null || true; done
    fi
    if grep -q "^$DRIVE" /proc/swaps 2>/dev/null; then
        for s in $(awk -v d="$DRIVE" '$1 ~ "^"d {print $1}' /proc/swaps); do
            swapoff "$s" || true
        done
    fi
}

# ============================================================
# Phase 1: partition + format
# ============================================================
do_partition() {
    step "partitioning $DRIVE"
    info "wiping signatures"
    wipefs -a "$DRIVE" >>"$LOG" 2>&1
    sgdisk --zap-all "$DRIVE" >>"$LOG" 2>&1 || true

    info "creating GPT + EFI(${EFI_SIZE_MIB}M) + BTRFS(remainder)"
    parted -s "$DRIVE" \
        mklabel gpt \
        mkpart ESP fat32 1MiB "${EFI_SIZE_MIB}MiB" \
        set 1 esp on \
        mkpart primary btrfs "${EFI_SIZE_MIB}MiB" 100% >>"$LOG" 2>&1

    partprobe "$DRIVE" || true
    sleep 2

    EFI_PART=$(part_name "$DRIVE" 1)
    ROOT_PART=$(part_name "$DRIVE" 2)
    [ -b "$EFI_PART"  ] || die "EFI partition not found: $EFI_PART"
    [ -b "$ROOT_PART" ] || die "BTRFS partition not found: $ROOT_PART"

    info "formatting $EFI_PART as FAT32"
    mkfs.vfat -F32 -n EFI "$EFI_PART" >>"$LOG" 2>&1

    info "formatting $ROOT_PART as BTRFS"
    mkfs.btrfs -f -L debian-root "$ROOT_PART" >>"$LOG" 2>&1

    EFI_UUID=$(blkid  -s UUID -o value "$EFI_PART")
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    info "EFI  UUID=$EFI_UUID"
    info "ROOT UUID=$ROOT_UUID"
}

# ============================================================
# Phase 2: subvolumes + mount tree
# ============================================================
do_subvolumes_and_mount() {
    step "creating Timeshift subvolumes"
    mkdir -p "$TARGET"
    mount -o "compress=zstd:3,noatime" "$ROOT_PART" "$TARGET"
    for sv in "${SUBVOLS[@]}"; do
        btrfs subvolume create "$TARGET/$sv" >>"$LOG" 2>&1
        info "  $sv"
    done
    # Make @ the default (Timeshift likes this)
    local id
    id=$(btrfs subvolume list "$TARGET" | awk '/path @$/{print $2; exit}')
    [ -n "$id" ] && btrfs subvolume set-default "$id" "$TARGET"
    umount "$TARGET"

    step "mounting subvolume tree at $TARGET"
    local OPTS="defaults,noatime,compress=zstd:3,space_cache=v2"
    mount -o "${OPTS},subvol=@" "$ROOT_PART" "$TARGET"
    mkdir -p "$TARGET"/{home,root,srv,tmp,var/log,var/cache,.snapshots,boot/efi}
    mount -o "${OPTS},subvol=@home"      "$ROOT_PART" "$TARGET/home"
    mount -o "${OPTS},subvol=@root"      "$ROOT_PART" "$TARGET/root"
    mount -o "${OPTS},subvol=@srv"       "$ROOT_PART" "$TARGET/srv"
    mount -o "${OPTS},subvol=@tmp"       "$ROOT_PART" "$TARGET/tmp"
    mount -o "${OPTS},subvol=@log"       "$ROOT_PART" "$TARGET/var/log"
    mount -o "${OPTS},subvol=@cache"     "$ROOT_PART" "$TARGET/var/cache"
    mount -o "${OPTS},subvol=@snapshots" "$ROOT_PART" "$TARGET/.snapshots"
    mount "$EFI_PART" "$TARGET/boot/efi"
}

# ============================================================
# Phase 3: debootstrap
# ============================================================
do_debootstrap() {
    step "debootstrapping Debian $SUITE_VAL into $TARGET (this takes a few minutes)"
    debootstrap --arch=amd64 \
        --include=ca-certificates,locales,gnupg \
        "$SUITE_VAL" "$TARGET" "$MIRROR_VAL" >>"$LOG" 2>&1 \
        || die "debootstrap failed — check $LOG"
    info "base system installed"
}

# ============================================================
# Phase 4: fstab
# ============================================================
do_fstab() {
    step "writing /etc/fstab"
    local OPTS="defaults,noatime,compress=zstd:3,space_cache=v2"
    cat > "$TARGET/etc/fstab" <<EOF
# /etc/fstab — generated by debian13-btrfs-autoinstall.sh
# Timeshift-compatible BTRFS layout. Do not rename @ or @home.

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
    sed 's/^/    /' "$TARGET/etc/fstab" | tee -a "$LOG"
}

# ============================================================
# Phase 5: chroot configuration
# ============================================================
do_chroot_config() {
    step "configuring system inside chroot"

    # Bind mounts for chroot
    mount --bind /dev      "$TARGET/dev"
    mount --bind /dev/pts  "$TARGET/dev/pts"
    mount -t proc  proc    "$TARGET/proc"
    mount -t sysfs sys     "$TARGET/sys"
    mount -t tmpfs run     "$TARGET/run"

    # APT sources
    cat > "$TARGET/etc/apt/sources.list" <<EOF
deb $MIRROR_VAL $SUITE_VAL main contrib non-free non-free-firmware
deb $MIRROR_VAL $SUITE_VAL-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $SUITE_VAL-security main contrib non-free non-free-firmware
EOF

    # Hostname / hosts
    echo "$HOSTNAME_VAL" > "$TARGET/etc/hostname"
    cat > "$TARGET/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME_VAL
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

    # The big chroot script — single heredoc, runs all config inside target
    cat > "$TARGET/root/configure.sh" <<CHROOT_EOF
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

# Locale
echo "$LOCALE_VAL UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=$LOCALE_VAL

# Timezone
ln -sf "/usr/share/zoneinfo/$TIMEZONE_VAL" /etc/localtime
echo "$TIMEZONE_VAL" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

# Keymap
echo "KEYMAP=$KEYMAP_VAL" > /etc/vconsole.conf 2>/dev/null || true

# APT update + install kernel + everything else
apt-get update
apt-get install -y linux-image-amd64 linux-headers-amd64 initramfs-tools
apt-get install -y $EXTRA_PKGS_VAL

# Root password
echo "root:$ROOTPASS_VAL" | chpasswd

# Create user
if ! id -u "$USERNAME_VAL" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,adm,plugdev,users "$USERNAME_VAL"
    echo "$USERNAME_VAL:$USERPASS_VAL" | chpasswd
fi

# Enable services
systemctl enable ssh         2>/dev/null || true
systemctl enable NetworkManager 2>/dev/null || true

# GRUB install to EFI
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
             --bootloader-id=Debian --recheck

# Make sure GRUB picks up BTRFS subvol
sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="rootflags=subvol=@"|' /etc/default/grub
update-grub
update-initramfs -u -k all

# Timeshift default config: BTRFS mode
mkdir -p /etc/timeshift
cat > /etc/timeshift/timeshift.json <<TSEOF
{
  "backup_device_uuid" : "$ROOT_UUID",
  "parent_device_uuid" : "",
  "do_first_run" : "false",
  "btrfs_mode" : "true",
  "include_btrfs_home_for_backup" : "false",
  "include_btrfs_home_for_restore" : "false",
  "stop_cron_emails" : "true",
  "schedule_monthly" : "false",
  "schedule_weekly"  : "true",
  "schedule_daily"   : "true",
  "schedule_hourly"  : "false",
  "schedule_boot"    : "true",
  "count_monthly" : "2",
  "count_weekly"  : "3",
  "count_daily"   : "5",
  "count_hourly"  : "6",
  "count_boot"    : "5"
}
TSEOF

echo "[chroot] configuration complete"
CHROOT_EOF

    chmod +x "$TARGET/root/configure.sh"
    chroot "$TARGET" /root/configure.sh 2>&1 | tee -a "$LOG"
    rm -f "$TARGET/root/configure.sh"
}

# ============================================================
# Phase 6: finish
# ============================================================
do_finish() {
    step "syncing and unmounting"
    sync
    # cleanup() trap will handle umounts
    info "install complete. log: $LOG"
    if [ "$SKIP_REBOOT" = "1" ]; then
        info "skipping reboot (--no-reboot). Eject media and reboot manually."
    else
        info "rebooting in 10s. Ctrl-C to cancel."
        sleep 10
        systemctl reboot || reboot
    fi
}

# ============================================================
# Main
# ============================================================
main() {
    require_root
    require_uefi
    : > "$LOG"
    info "log file: $LOG"

    ensure_tools

    if [ -z "$DRIVE" ]; then
        pick_drive_interactive
    fi
    [ -b "$DRIVE" ] || die "$DRIVE is not a block device"

    cat <<EOF

================================================================
AUTOMATED DEBIAN $SUITE_VAL INSTALL — REVIEW BEFORE PROCEEDING
================================================================
Target drive:    $DRIVE  ($(lsblk -dn -o SIZE "$DRIVE" | tr -d ' '))
Hostname:        $HOSTNAME_VAL
Username:        $USERNAME_VAL
Timezone:        $TIMEZONE_VAL
Locale:          $LOCALE_VAL
Mirror:          $MIRROR_VAL
Layout:          ${EFI_SIZE_MIB}M EFI + BTRFS (@, @home, @root,
                 @srv, @tmp, @log, @cache, @snapshots)
Extras:          $EXTRA_PKGS_VAL

THIS WILL DESTROY ALL DATA ON $DRIVE.
================================================================
EOF
    confirm "Proceed with full automated install?"

    ensure_unmounted
    do_partition
    do_subvolumes_and_mount
    do_debootstrap
    do_fstab
    do_chroot_config
    do_finish
}

main "$@"
