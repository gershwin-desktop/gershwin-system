#!/bin/bash

# Copies the running Debian/Devuan/Arch/Artix system to a new disk and make it bootable (UEFI or BIOS)
# WARNING: This will ERASE all data on the target disk!
#
# Usage:
#   installer-linux.sh                                Interactive mode
#   installer-linux.sh --list-disks                   Output JSON list of available disks
#   installer-linux.sh --noninteractive --disk /dev/sdb   Non-interactive install to disk

set -e

# ---- Argument Parsing ----
NONINTERACTIVE=0
ARG_DISK=""
LIST_DISKS=0
ARG_SOURCE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --noninteractive) NONINTERACTIVE=1; shift ;;
        --disk) ARG_DISK="$2"; shift 2 ;;
        --source) ARG_SOURCE="$2"; shift 2 ;;
        --list-disks) LIST_DISKS=1; shift ;;
        --debug) DEBUG=1; shift ;;
        *) ARG_DISK="$1"; shift ;;
    esac
done

# Debug defaults to 0
DEBUG=${DEBUG:-0}

report_progress() {
    # Usage: report_progress "Phase" percent "Message"
    echo "PROGRESS:$1:$2:$3"
}

# Checks
if [ "$(uname -s)" != "Linux" ]; then
    echo "ERROR: This script must be run on Linux."
    exit 1
fi

if [ "$LIST_DISKS" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# Detect Distro
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
else
    DISTRO="unknown"
fi

# ---- Disk enumeration (shared by --list-disks and interactive selection) ----
# Determine root disk to exclude
ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || true)
ROOT_DISK=""
if [ -n "$ROOT_DEV" ]; then
    ROOT_DISK=$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null | head -n1)
    [ -z "$ROOT_DISK" ] && ROOT_DISK=$(echo "$ROOT_DEV" | sed -E 's/p?[0-9]+$//')
    [[ "$ROOT_DISK" == /* ]] || ROOT_DISK="/dev/$ROOT_DISK"
fi

enumerate_disks() {
    # Output lines of: device|model|size_bytes
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -dbno NAME,SIZE,MODEL 2>/dev/null | while IFS= read -r line; do
            dname=$(echo "$line" | awk '{print $1}')
            dsize=$(echo "$line" | awk '{print $2}')
            dmodel=$(echo "$line" | awk '{$1=""; $2=""; sub(/^[[:space:]]+/, ""); print}')
            dev="/dev/$dname"
            # Exclude loop, zram, and root disk
            case "$dname" in loop*|zram*) continue ;; esac
            [ -z "$dsize" ] && dsize=0
            [ "$dsize" -le 2147483648 ] 2>/dev/null && continue
            [ "$dev" = "$ROOT_DISK" ] && continue
            # Also check if root disk starts with this device
            case "$ROOT_DISK" in "$dev"*) continue ;; esac
            [ -z "$dmodel" ] && dmodel="Unknown Disk"
            echo "$dev|$dmodel|$dsize"
        done
    else
        # Fallback: parse /proc/partitions and /sys/block for model info
        awk 'NR>2 {print $4, $3}' /proc/partitions 2>/dev/null | while IFS= read -r name blocks; do
            # Skip partition entries (names ending in digit) and loop/zram
            if [[ "$name" =~ [0-9]$ ]] || [[ "$name" == loop* ]] || [[ "$name" == zram* ]]; then
                continue
            fi
            dev="/dev/$name"
            # blocks is in 1K units; convert to bytes
            dsize=$((blocks * 1024))
            [ "$dsize" -le 2147483648 ] 2>/dev/null && continue
            [ "$dev" = "$ROOT_DISK" ] && continue
            case "$ROOT_DISK" in "$dev"*) continue ;; esac
            # read model if present
            if [ -r "/sys/block/$name/device/model" ]; then
                dmodel=$(tr -d '\0' < /sys/block/$name/device/model 2>/dev/null || true)
                dmodel=$(echo "$dmodel" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            else
                dmodel="Unknown Disk"
            fi
            echo "$dev|$dmodel|$dsize"
        done
    fi
}

# ---- --list-disks mode: output JSON and exit ----
if [ "$LIST_DISKS" = "1" ]; then
    printf '['
    first=1
    enumerate_disks | while IFS='|' read -r ddev dmodel dsize; do
        if [ "$first" = "1" ]; then first=0; else printf ','; fi
        dname=$(basename "$ddev")
        # format size human-readable
        if command -v numfmt >/dev/null 2>&1; then
            size_hr=$(numfmt --to=iec --suffix=B "$dsize")
        else
            size_hr=$(awk -v b="$dsize" 'BEGIN { if (b>=1073741824) printf "%.1f GB", b/1073741824; else if (b>=1048576) printf "%.1f MB", b/1048576; else printf "%d B", b }')
        fi
        printf '{"devicePath":"%s","name":"%s","description":"%s","sizeBytes":%s,"formattedSize":"%s"}' \
            "$ddev" "$dname" "$dmodel" "$dsize" "$size_hr"
    done
    printf ']\n'
    exit 0
fi

# Source detection: if ISO9660 filesystem is mounted, offer to use that
# Otherwise default to / (cloning the running system)
if [ -n "$ARG_SOURCE" ]; then
    SRC="$ARG_SOURCE"
else
    SRC="/"
    if mount | grep -q "type iso9660"; then
        # Find out where it is mounted
        ISO_MP=$(mount | awk '$5 == "iso9660" {print $3; exit}')
        echo "Detected ISO9660 filesystem mounted at $ISO_MP."
        if [ "$NONINTERACTIVE" = "1" ]; then
            echo "Image-based install: copying from $ISO_MP"
            SRC="$ISO_MP"
        else
            printf "Found ISO9660 installation media. Use it as source? [Y/n]: "
            read -r image_ans
            case "$image_ans" in
                [Nn]*) SRC="/" ;;
                *) SRC="$ISO_MP" ;;
            esac
        fi
    fi
fi

MNT="/mnt/target"
EFI_SIZE="512MiB"

umount_recursive() {
    # Unmount everything under $MNT
    mount | grep "$MNT" | awk '{print $3}' | sort -r | while read -r mp; do
        umount -l "$mp" 2>/dev/null || true
    done
}

# Temporary mount for live squashfs images (if using ISO as source)
TMP_LIVE=""
cleanup_tmp_live() {
    if [ -n "$TMP_LIVE" ] && mountpoint -q "$TMP_LIVE"; then
        echo "Unmounting temporary live squashfs at $TMP_LIVE"
        umount -l "$TMP_LIVE" >/dev/null 2>&1 || true
        rmdir "$TMP_LIVE" >/dev/null 2>&1 || true
    fi
}
trap cleanup_tmp_live EXIT

# Disk Selection
if [ -n "$ARG_DISK" ]; then
    DISK="$ARG_DISK"
    [[ "$DISK" == /* ]] || DISK="/dev/$DISK"
    if [ ! -b "$DISK" ]; then
        echo "ERROR: $DISK is not a block device"
        exit 1
    fi
else
    if [ "$NONINTERACTIVE" = "1" ]; then
        echo "ERROR: --disk is required in non-interactive mode"
        exit 1
    fi
    echo "Scanning for disks over 2GB..."

    DISKS_LIST=$(enumerate_disks)

    if [ -z "$DISKS_LIST" ]; then
        echo "ERROR: No suitable destination disks > 2GB found."
        echo "Root device: $ROOT_DEV ($ROOT_DISK)"
        exit 1
    fi

    echo "Available disks for installation:"
    i=1
    while IFS='|' read -r dev model size; do
        [ -z "$model" ] && model="Unknown Model"
        size_gb=$(awk -v b="$size" 'BEGIN { printf "%.1f", b / 1073741824 }')
        echo "$i) $dev - $model (${size_gb}G)"
        i=$((i+1))
    done <<< "$DISKS_LIST"

    printf "Select a disk (1-%d): " "$((i-1))"
    read -r choice
    DISK=$(echo "$DISKS_LIST" | sed -n "${choice}p" | cut -d'|' -f1)

    if [ -z "$DISK" ]; then
        echo "Invalid selection."
        exit 1
    fi
fi

echo "Target disk: $DISK"

# Detect Boot Method
BOOT_METHOD="BIOS"
if [ -d /sys/firmware/efi ]; then
    BOOT_METHOD="UEFI"
elif [ -d /boot/broadcom ] || [ -d /boot/firmware ]; then
    BOOT_METHOD="BROADCOM"
    if [ -d /boot/broadcom ]; then
        RPI_BOOT_DIR="/boot/broadcom"
    else
        RPI_BOOT_DIR="/boot/firmware"
    fi
fi
echo "Detected boot method: $BOOT_METHOD"

# Confirmation
if [ "$NONINTERACTIVE" = "1" ]; then
    echo "Non-interactive mode: proceeding with installation to $DISK"
else
    printf "WARNING: This will ERASE all data on %s! Continue? [y/N]: " "$DISK"
    read -r ans
    [[ "$ans" =~ ^[Yy] ]] || { echo "Aborting."; exit 1; }
fi

report_progress "Preparing" 5 "Unmounting existing partitions..."

set -x

# Cleanup
umount_recursive
mkdir -p "$MNT"

# Partitioning
report_progress "Partitioning" 8 "Wiping old partition table..."
echo "Creating new partition table on $DISK..."
# Wipe filesystem signatures
wipefs -a "$DISK"

report_progress "Partitioning" 10 "Creating partition table..."
if [ "$BOOT_METHOD" = "UEFI" ]; then
    # Partition 1: EFI System Partition (512MB)
    # Partition 2: Linux Root (Remaining)
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart primary fat32 1MiB "$EFI_SIZE"
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart primary ext4 "$EFI_SIZE" 100%
elif [ "$BOOT_METHOD" = "BROADCOM" ]; then
    # Partition 1: Broadcom Boot (512MB) - Raspberry Pi
    # Partition 2: Linux Root (Remaining)
    parted -s "$DISK" mklabel msdos
    parted -s "$DISK" mkpart primary fat32 1MiB "$EFI_SIZE"
    parted -s "$DISK" set 1 boot on
    parted -s "$DISK" mkpart primary ext4 "$EFI_SIZE" 100%
else
    # Partition 1: BIOS Boot Partition (1MB) - Required for GRUB on GPT
    # Partition 2: Linux Root (Remaining)
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart primary 1MiB 2MiB
    parted -s "$DISK" set 1 bios_grub on
    parted -s "$DISK" mkpart primary ext4 2MiB 100%
fi

report_progress "Partitioning" 14 "Waiting for partition devices..."
# Find partitions
partprobe "$DISK" || true
udevadm settle
sleep 2

# Handle partition naming (nvme0n1p1 vs sda1)
if [[ "$DISK" == *nvme* ]] || [[ "$DISK" == *mmcblk* ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# Verification
[ -b "$ROOT_PART" ] || { echo "ERROR: Root partition $ROOT_PART not found"; exit 1; }

# Formatting
report_progress "Formatting" 18 "Formatting root partition..."
echo "Formatting partitions..."
mkfs.ext4 -F -L "Root" "$ROOT_PART"
if [ "$BOOT_METHOD" = "UEFI" ] || [ "$BOOT_METHOD" = "BROADCOM" ]; then
    report_progress "Formatting" 20 "Formatting boot partition..."
    mkfs.vfat -F 32 -n "BOOT" "$EFI_PART"
fi

# Mounting
report_progress "Mounting" 22 "Mounting target filesystems..."
echo "Mounting target filesystems..."
mount "$ROOT_PART" "$MNT"
if [ "$BOOT_METHOD" = "UEFI" ]; then
    mkdir -p "$MNT/boot/efi"
    mount "$EFI_PART" "$MNT/boot/efi"
elif [ "$BOOT_METHOD" = "BROADCOM" ]; then
    mkdir -p "$MNT$RPI_BOOT_DIR"
    mount "$EFI_PART" "$MNT$RPI_BOOT_DIR"
fi

# Copying System
report_progress "Copying" 25 "Starting system copy from $SRC..."
echo "Copying system from $SRC to $MNT..."
# If src is an ISO that contains a squashfs (live image), prefer filesystem.squashfs or the largest squashfs and mount it
if mount | grep -q "type iso9660" && [ -n "$SRC" ] && [ -d "$SRC" ]; then
    echo "Searching for squashfs images under $SRC..."

    # Prefer a file named 'filesystem.squashfs' if present
    SQUASH_PREF=$(find "$SRC" -maxdepth 6 -type f -iname 'filesystem.squashfs' -print -quit || true)
    if [ -n "$SQUASH_PREF" ]; then
        SQUASH_FILE="$SQUASH_PREF"
        echo "Found preferred squashfs 'filesystem.squashfs' at: $SQUASH_FILE"
    else
        # Otherwise pick the largest squashfs file found
        SQUASH_FILE=$(find "$SRC" -maxdepth 6 -type f -iname '*.squashfs' -printf '%s\t%p\n' | sort -n | tail -n1 | cut -f2- || true)
        if [ -n "$SQUASH_FILE" ]; then
            SIZE=$(stat -c%s "$SQUASH_FILE" 2>/dev/null || true)
            echo "Selected largest squashfs: $SQUASH_FILE (size ${SIZE:-unknown} bytes)"
        fi
    fi

    if [ -n "$SQUASH_FILE" ]; then
        echo "Detected squashfs image at $SQUASH_FILE. Attempting to mount to access live rootfs..."
        TMP_LIVE=$(mktemp -d /tmp/live-root.XXXXXX)
        if mount -t squashfs -o loop "$SQUASH_FILE" "$TMP_LIVE" 2>/dev/null; then
            echo "Mounted squashfs at $TMP_LIVE; using it as source."
            SRC="$TMP_LIVE"
        else
            echo "Warning: Failed to mount $SQUASH_FILE. Proceeding with ISO root ($SRC) instead."
            rmdir "$TMP_LIVE" >/dev/null 2>&1 || true
            TMP_LIVE=""
        fi
    else
        echo "No squashfs images found in $SRC; using ISO root ($SRC) as source."
    fi
fi

# Excludes (relative to SRC)
EXCLUDES=(
    "dev/*" "proc/*" "sys/*" "tmp/*" "run/*" "mnt/*" "media/*" "lost+found"
    "var/lib/dhcp/*" "var/lib/dhcpcd/*" "var/run/*" "var/tmp/*" "var/cache/*"
    "boot/efi/*"
)
[ "$BOOT_METHOD" = "BROADCOM" ] && EXCLUDES+=("${RPI_BOOT_DIR#/}/*")

EXCLUDE_ARGS=""
for e in "${EXCLUDES[@]}"; do
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude=$e"
done

if command -v rsync >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    rsync -aHAX --info=progress2 $EXCLUDE_ARGS "${SRC%/}/" "$MNT/" 2>&1 | \
    while IFS= read -r line; do
        echo "$line"
        # Parse rsync progress output for percentage
        pct=$(echo "$line" | sed -n 's/.*[[:space:]]\([0-9]*\)%.*/\1/p')
        if [ -n "$pct" ]; then
            # Scale rsync 0-100% to our 25-80% range
            scaled=$(awk -v p="$pct" 'BEGIN { printf "%d", 25 + (p * 55 / 100) }')
            report_progress "Copying" "$scaled" "Copying files... ${pct}%"
        fi
    done
else
    report_progress "Copying" 30 "Copying files (fallback mode)..."
    echo "rsync not found, using cp -ax..."
    # cp -ax is the best POSIX fallback for cloning
    cp -ax "${SRC%/}/." "$MNT/"
    report_progress "Copying" 80 "File copy complete."
fi

# Re-create excluded mount point directories
for d in dev proc sys run tmp mnt media; do
    mkdir -p "$MNT/$d"
done
chmod 1777 "$MNT/tmp"

# Prepare for chroot
report_progress "Bootloader" 82 "Preparing chroot environment..."
echo "Preparing chroot environment..."
for dir in dev proc sys run; do
    mount --bind /$dir "$MNT/$dir"
done

# Bootloader Installation
report_progress "Bootloader" 84 "Installing bootloader..."
echo "Installing bootloader..."
if [ "$BOOT_METHOD" = "UEFI" ]; then
    # We install with --removable to ensure it works even if NVRAM is not updated
    chroot "$MNT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Linux --recheck --removable
elif [ "$BOOT_METHOD" = "BROADCOM" ]; then
    report_progress "Bootloader" 85 "Copying Broadcom firmware..."
    echo "Copying Broadcom firmware to boot partition from $RPI_BOOT_DIR..."
    # Copy from the host's RPI_BOOT_DIR as it contains the working firmware
    cp -rv "$RPI_BOOT_DIR"/* "$MNT$RPI_BOOT_DIR/"
    
    echo "Updating cmdline.txt with new ROOT PARTUUID..."
    ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PART")
    if [ -n "$ROOT_PARTUUID" ]; then
        CMDLINE_FILE="$MNT$RPI_BOOT_DIR/cmdline.txt"
        if [ -f "$CMDLINE_FILE" ]; then
            # Update root=PARTUUID=... in cmdline.txt if it exists
            sed -i "s/root=PARTUUID=[^ ]*/root=PARTUUID=$ROOT_PARTUUID/" "$CMDLINE_FILE"
            # Also handle root=/dev/... cases just in case
            sed -i "s/root=\/dev\/[a-z0-9]*\([ ]\|$\)/root=PARTUUID=$ROOT_PARTUUID\1/" "$CMDLINE_FILE"
        fi
    fi
else
    chroot "$MNT" grub-install --target=i386-pc "$DISK"
fi

# Update GRUB config inside chroot (skip for Broadcom/RPi)
if [ "$BOOT_METHOD" != "BROADCOM" ]; then
    report_progress "Bootloader" 88 "Updating GRUB configuration..."
    echo "Updating GRUB configuration..."
    if [ "$DISTRO" = "debian" ] || [ "$DISTRO" = "devuan" ]; then
        chroot "$MNT" update-grub
    else
        # Arch and others
        chroot "$MNT" grub-mkconfig -o /boot/grub/grub.cfg
    fi
fi

# Generate fstab using UUIDs for stability
report_progress "Configuration" 90 "Writing filesystem table..."
echo "Generating /etc/fstab..."
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
echo "UUID=$ROOT_UUID / ext4 errors=remount-ro 0 1" > "$MNT/etc/fstab"

if [ "$BOOT_METHOD" = "UEFI" ]; then
    EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
    echo "UUID=$EFI_UUID /boot/efi vfat umask=0077 0 2" >> "$MNT/etc/fstab"
elif [ "$BOOT_METHOD" = "BROADCOM" ]; then
    EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
    echo "UUID=$EFI_UUID $RPI_BOOT_DIR vfat defaults 0 2" >> "$MNT/etc/fstab"
fi

# Finalizing
report_progress "Finalizing" 96 "Syncing filesystems..."
echo "Finalizing installation..."
sync

report_progress "Finalizing" 98 "Unmounting target..."
umount_recursive

report_progress "Complete" 100 "Installation complete."
echo "=== COMPLETE ==="
echo "The system is now installed on $DISK."
echo "You may now restart your computer."
