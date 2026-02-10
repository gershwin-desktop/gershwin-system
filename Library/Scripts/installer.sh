
#!/bin/sh

# Copies the running FreeBSD system to a new disk and make it bootable (UEFI or BIOS)
# WARNING: This will ERASE all data on the target disk!
#
# Usage:
#   installer.sh                           Interactive mode
#   installer.sh --list-disks              Output JSON list of available disks
#   installer.sh --noninteractive --disk /dev/da1   Non-interactive install to disk

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

# Debug flag defaults to 0
DEBUG=${DEBUG:-0}

report_progress() {
    # Usage: report_progress "Phase" percent "Message"
    echo "PROGRESS:$1:$2:$3"
}

# Checks
if [ "$(uname -s)" != "FreeBSD" ]; then
    echo "ERROR: This script must be run on FreeBSD."
    exit 1
fi

if [ "$LIST_DISKS" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# Temporarily disable automounter to prevent automounting interference.
# `service devd stop` is not working reliably, so mount a tmpfs over /usr/local/sbin as a workaround.
# FIXME: Find a better way
MOUNTED_TMPFS=0
if [ "$LIST_DISKS" != "1" ]; then
    if ! mount | awk '{print $3}' | grep -qx '/usr/local/sbin'; then
        mount -t tmpfs tmpfs /usr/local/sbin
        MOUNTED_TMPFS=1
    fi
fi
trap 'if [ "$MOUNTED_TMPFS" = "1" ]; then umount /usr/local/sbin 2>/dev/null || true; fi' EXIT

# ---- Disk enumeration (shared by --list-disks and interactive selection) ----
MIN_SIZE=2147483648  # 2GB in bytes

# Determine disks to exclude: the disk containing the installer script and the disk mounted as /
SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in /*) ;; *) SCRIPT_PATH="$(pwd)/$SCRIPT_PATH" ;; esac
if command -v realpath >/dev/null 2>&1; then
    SCRIPT_PATH="$(realpath "$SCRIPT_PATH")"
fi
SCRIPT_DEV=$(df -P "$SCRIPT_PATH" 2>/dev/null | awk 'NR==2 {print $1}' || true)
ROOT_DEV=$(mount | awk '$3=="/" {print $1}' || true)
disk_base() { basename "$1" | sed -E 's/p?[0-9]+$//' | sed -E 's/s[0-9]+$//' ; }
SCRIPT_DISK=$(disk_base "$SCRIPT_DEV")
ROOT_DISK=$(disk_base "$ROOT_DEV")

enumerate_disks() {
    # Returns lines of: device_name size_bytes description
    for d in $(sysctl -n kern.disks 2>/dev/null); do
        # Skip the installer or root disk
        if [ -n "$SCRIPT_DISK" ] && [ "$d" = "$SCRIPT_DISK" ]; then continue; fi
        if [ -n "$ROOT_DISK" ] && [ "$d" = "$ROOT_DISK" ]; then continue; fi

        size=$(diskinfo "/dev/$d" 2>/dev/null | awk '{print $3}')
        [ -z "$size" ] && size=0
        if [ -n "$size" ] && awk -v s="$size" -v m="$MIN_SIZE" 'BEGIN { exit !(s >= m) }' 2>/dev/null; then
            desc=$(geom disk list "$d" 2>/dev/null | grep "descr:" | head -n1 | cut -d: -f2 | sed 's/^[[:space:]]*//')
            [ -z "$desc" ] && desc="Unknown Disk"
            if [ "$DEBUG" = "1" ]; then
                echo "DIAG: disk=$d size=$size desc=$desc" >&2
            fi
            echo "$d $size $desc"
        else
            if [ "$DEBUG" = "1" ]; then
                echo "DIAG: skipping $d size=$size" >&2
            fi
        fi
    done
}

# ---- --list-disks mode: output JSON and exit ----
if [ "$LIST_DISKS" = "1" ]; then
    printf '['
    first=1
    enumerate_disks | while IFS= read -r line; do
        dname=$(echo "$line" | awk '{print $1}')
        dsize=$(echo "$line" | awk '{print $2}')
        ddesc=$(echo "$line" | awk '{$1=""; $2=""; sub(/^[[:space:]]+/, ""); print}')
        if [ "$first" = "1" ]; then first=0; else printf ','; fi
        # Human-readable size
        if command -v numfmt >/dev/null 2>&1; then
            size_hr=$(numfmt --to=iec --suffix=B "$dsize")
        else
            size_hr=$(awk -v b="$dsize" 'BEGIN { if (b>=1073741824) printf "%.1f GB", b/1073741824; else if (b>=1048576) printf "%.1f MB", b/1048576; else printf "%d B", b }')
        fi
        printf '{"devicePath":"/dev/%s","name":"%s","description":"%s","sizeBytes":%s,"formattedSize":"%s"}' \
            "$dname" "$dname" "$ddesc" "$dsize" "$size_hr"
    done
    printf ']\n'
    exit 0
fi

# Determine if /dev/da0 is mounted and offer image-based installation only if it is
if [ -n "$ARG_SOURCE" ]; then
    SRC="$ARG_SOURCE"
else
    MP=$(mount | while read -r line; do
        case "$line" in
            /dev/da0*)
                echo "$line" | sed 's/^[^ ]* on \(.*\) (.*)/\1/'
                exit 0
                ;;
        esac
    done)
    if [ -n "$MP" ]; then
        if [ "$NONINTERACTIVE" = "1" ]; then
            echo "Image-based install: copying from $MP"
            SRC="$MP"
        else
            printf "Do you want an image-based installation (copy the contents of %s) instead of copying /? [y/N]: " "$MP"
            read -r image_ans
            case "$image_ans" in
                [Yy]*)
                    echo "Image-based install: copying from $MP"
                    SRC="$MP"
                    ;;
                *) SRC="/" ;;
            esac
        fi
    else
        SRC="/"
    fi
fi

MNT="/mnt"
EFI_SIZE="512M"

# Function: unmount everything under $MNT
umount_recursive() {
    mount | while read -r line; do
        mp=$(echo "$line" | sed 's/^[^ ]* on \(.*\) (.*)/\1/')
        case "$mp" in
            "$MNT"*) echo "$mp" ;;
        esac
    done | sort -r | while read -r mp; do
        umount "$mp" 2>/dev/null || true
    done
}

# Function: unmount all partitions of a disk
umount_disk_partitions() {
    disk_to_unmount="$1"
    [ -z "$disk_to_unmount" ] && return
    
    mount | while read -r line; do
        dev=$(echo "$line" | cut -d' ' -f1)
        case "$dev" in
            "$disk_to_unmount" | "${disk_to_unmount}p"* | "${disk_to_unmount}s"*)
                mp=$(echo "$line" | sed 's/^[^ ]* on \(.*\) (.*)/\1/')
                if [ -n "$mp" ] && [ "$mp" != "/" ]; then
                    echo "Unmounting $mp ($dev)..."
                    umount -f "$mp" 2>/dev/null || true
                fi
                ;;
        esac
    done
}

# Disk Selection
if [ -n "$ARG_DISK" ]; then
    DISK="$ARG_DISK"
    # Add /dev/ if missing and it doesn't start with /
    case "$DISK" in
        /*) ;;
        *) DISK="/dev/$DISK" ;;
    esac
    
    if [ ! -c "$DISK" ]; then
        echo "ERROR: $DISK is not a character device"
        exit 1
    fi
else
    if [ "$NONINTERACTIVE" = "1" ]; then
        echo "ERROR: --disk is required in non-interactive mode"
        exit 1
    fi
    echo "Scanning for disks over 2GB..."
    VALID_DISKS=""

    EXCLUDED_MSG=""
    if [ -n "$SCRIPT_DISK" ]; then EXCLUDED_MSG="$EXCLUDED_MSG installer:$SCRIPT_DISK"; fi
    if [ -n "$ROOT_DISK" ] && [ "$ROOT_DISK" != "$SCRIPT_DISK" ]; then EXCLUDED_MSG="$EXCLUDED_MSG root:$ROOT_DISK"; fi
    if [ -n "$EXCLUDED_MSG" ]; then echo "Excluding disks: $EXCLUDED_MSG"; fi
    
    # shellcheck disable=SC2046
    for d in $(sysctl -n kern.disks 2>/dev/null); do
        # Skip the installer or root disk
        if [ -n "$SCRIPT_DISK" ] && [ "$d" = "$SCRIPT_DISK" ]; then
            continue
        fi
        if [ -n "$ROOT_DISK" ] && [ "$d" = "$ROOT_DISK" ]; then
            continue
        fi

        # diskinfo without flags returns: device sectorsize size_bytes size_sectors ...
        size=$(diskinfo "/dev/$d" 2>/dev/null | awk '{print $3}')
        [ -z "$size" ] && size=0
        # Use awk for comparison to handle large integers (> 32-bit)
        if [ -n "$size" ] && awk -v s="$size" -v m="$MIN_SIZE" 'BEGIN { exit !(s >= m) }' 2>/dev/null; then
            VALID_DISKS="$VALID_DISKS $d"
        fi
    done

    if [ -z "$VALID_DISKS" ]; then
        echo "ERROR: No disks larger than 2GB found (after excluding installer/root disks)."
        echo "Ensure you are running on FreeBSD and have permissions to access disks."
        exit 1
    fi

    echo "Available disks (>2GB):"
    count=0
    for d in $VALID_DISKS; do
        count=$((count + 1))
        size_bytes=$(diskinfo "/dev/$d" 2>/dev/null | awk '{print $3}')
        [ -z "$size_bytes" ] && size_bytes=0
        size_gb=$(awk -v b="$size_bytes" 'BEGIN { printf "%.0f", b / 1073741824 }')
        # Try to get a description from geom
        desc=$(geom disk list "$d" 2>/dev/null | grep "descr:" | head -n1 | cut -d: -f2 | sed 's/^[[:space:]]*//')
        [ -z "$desc" ] && desc="Unknown Disk"
        echo "$count) $d - $desc (${size_gb}GB)"
    done

    printf "Select a disk (1-%d): " "$count"
    read -r choice
    
    # Ensure choice is a valid decimal number
    case "$choice" in
        ''|*[!0-9]*) choice=0 ;;
    esac
    
    item_count=0
    for d in $VALID_DISKS; do
        item_count=$((item_count + 1))
        if [ "$item_count" -eq "$choice" ] 2>/dev/null; then
            DISK="/dev/$d"
            break
        fi
    done

    if [ -z "$DISK" ]; then
        echo "Invalid selection."
        exit 1
    fi
fi

echo "Target disk: $DISK"

# Detect Boot Method
BOOT_METHOD=$(sysctl -n machdep.bootmethod)
echo "Detected boot method: $BOOT_METHOD"

# Confirmation prompt
if [ "$NONINTERACTIVE" = "1" ]; then
    echo "Non-interactive mode: proceeding with installation to $DISK"
else
    echo "WARNING: This will ERASE all data on $DISK!"
    printf "Are you sure you want to continue? [y/N]: "
    read -r ans
    case "$ans" in
        [Yy]*) echo "Proceeding..." ;;
        *) echo "Aborting."; exit 1 ;;
    esac
fi

sleep 1

report_progress "Preparing" 5 "Unmounting existing partitions..."

set -x

# Cleanup
umount_disk_partitions "$DISK"
umount_recursive

report_progress "Partitioning" 8 "Destroying old partition table..."
echo "Destroying old partition table..."
gpart destroy -F "$DISK" 2>/dev/null || true

report_progress "Partitioning" 10 "Creating GPT partition table..."
echo "Creating GPT..."
gpart create -s gpt "$DISK"

if [ "$BOOT_METHOD" = "UEFI" ]; then
    # Create EFI partition
    report_progress "Partitioning" 12 "Creating EFI partition..."
    echo "Creating EFI partition..."
    gpart add -t efi -s "$EFI_SIZE" "$DISK"
    EFI_PART="${DISK}p1"
    report_progress "Formatting" 15 "Formatting EFI partition..."
    echo "Formatting EFI..."
    newfs_msdos -F 32 -c 1 "$EFI_PART"
else
    # Create BIOS boot partition
    report_progress "Partitioning" 12 "Creating BIOS boot partition..."
    echo "Creating BIOS boot partition..."
    gpart add -t freebsd-boot -s 512k "$DISK"
    gpart bootcode -b /boot/pmbr -p /boot/gptboot -i 1 "$DISK"
fi

# Create UFS root
report_progress "Partitioning" 18 "Creating root partition..."
echo "Creating UFS root partition..."
gpart add -t freebsd-ufs "$DISK"
ROOT_PART="${DISK}p2"
report_progress "Formatting" 20 "Formatting root filesystem..."
newfs -U "$ROOT_PART"

# Mount filesystems
report_progress "Mounting" 22 "Mounting target filesystems..."
echo "Mounting target..."
mkdir -p "$MNT"
mount "$ROOT_PART" "$MNT"

if [ "$BOOT_METHOD" = "UEFI" ]; then
    mkdir -p "$MNT/efi"
    mount -t msdosfs "$EFI_PART" "$MNT/efi"
fi

# Create all needed directories
report_progress "Mounting" 24 "Creating directory structure..."
echo "Creating directories..."
for d in dev proc run tmp var/run var/tmp var/cache; do
    mkdir -p "$MNT/$d"
done
chmod 1777 "$MNT/tmp" "$MNT/var/tmp"

report_progress "Copying" 25 "Starting system copy from $SRC..."
echo "Copying system from $SRC to $MNT..."

# Exclude runtime dirs
EXCLUDES="dev proc sys tmp mnt media efi run var/run var/tmp var/cache compat"
EXCLUDE_ARGS=""
for d in $EXCLUDES; do
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude=$d"
done

# POSIX-safe cp -a with excludes using rsync if available, else fallback to find+cp
if command -v rsync >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    rsync -aHAX --info=progress2 $EXCLUDE_ARGS "${SRC%/}/" "$MNT" 2>&1 | \
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
    # fallback
    report_progress "Copying" 30 "Copying files (fallback mode)..."
    cd "$SRC"
    for item in * .*; do
        # Skip '.' and '..'
        if [ "$item" = "." ] || [ "$item" = ".." ]; then continue; fi
        # Skip excluded dirs
        skip=0
        for e in $EXCLUDES; do
            [ "$item" = "$e" ] && skip=1
        done
        [ "$skip" -eq 1 ] && continue
        cp -a "$item" "$MNT/" || true
    done
    report_progress "Copying" 80 "File copy complete."
fi

# Create the directories we skipped during copying
for d in $EXCLUDES; do
    mkdir -p "$MNT/$d"
done

# Install bootloader
report_progress "Bootloader" 82 "Installing bootloader..."
if [ "$BOOT_METHOD" = "UEFI" ]; then
    echo "Installing UEFI bootloader..."
    mkdir -p "$MNT/efi/EFI/BOOT"
    cp /boot/loader.efi "$MNT/efi/EFI/BOOT/BOOTX64.EFI"
    mkdir -p "$MNT/efi/EFI/freebsd"
    cp /boot/loader.efi "$MNT/efi/EFI/freebsd/loader.efi"

    # Register boot entry
    report_progress "Bootloader" 86 "Registering UEFI boot entry..."
    echo "Registering UEFI boot entry..."
    # Mount EFI partition to /boot/efi temporarily to help efibootmgr translate path
    umount "$MNT/efi"
    mkdir -p /boot/efi
    mount -t msdosfs "$EFI_PART" /boot/efi
    efibootmgr -c -d "$DISK" -p 1 -L "FreeBSD" -l /boot/efi/EFI/freebsd/loader.efi
    # Set as BootNext to ensure it boots from the new disk next time
    NEW_BOOT_ENTRY=$(efibootmgr | grep "FreeBSD" | head -n 1 | sed -E 's/.*Boot([0-9A-Fa-f]{4}).*/\1/')
    if [ -n "$NEW_BOOT_ENTRY" ]; then
        echo "Setting BootNext to $NEW_BOOT_ENTRY"
        efibootmgr -n -b "$NEW_BOOT_ENTRY"
    fi
    umount /boot/efi
else
    echo "BIOS bootloader already installed via gpart bootcode."
fi

# Write fstab
report_progress "Configuration" 90 "Writing filesystem table..."
cat > "$MNT/etc/fstab" <<EOF
$ROOT_PART   /      ufs   rw   1 1
EOF
if [ "$BOOT_METHOD" = "UEFI" ]; then
    cat >> "$MNT/etc/fstab" <<EOF
$EFI_PART    /efi   msdos rw   0 0
EOF
fi
cat >> "$MNT/etc/fstab" <<EOF
proc         /proc  procfs rw  0 0
EOF

# Configure loader
report_progress "Configuration" 93 "Configuring boot loader..."
cat >> "$MNT/boot/loader.conf" <<EOF
nvme_load="YES"
vfs.root.mountfrom="ufs:$ROOT_PART"
EOF

report_progress "Finalizing" 96 "Syncing filesystems..."
sync

report_progress "Finalizing" 98 "Unmounting target..."
umount_recursive

report_progress "Complete" 100 "Installation complete."
echo "=== COMPLETE ==="
echo "The system is now installed on $DISK."
echo "You may now restart your computer."
