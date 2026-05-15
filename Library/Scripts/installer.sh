
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
IMAGE_MODE=0
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
            IMAGE_MODE=1
        else
            printf "Do you want an image-based installation (copy the contents of %s) instead of copying /? [y/N]: " "$MP"
            read -r image_ans
            case "$image_ans" in
                [Yy]*)
                    echo "Image-based install: copying from $MP"
                    SRC="$MP"
                    IMAGE_MODE=1
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

# Create UFS root partition
report_progress "Partitioning" 18 "Creating root partition..."
echo "Creating UFS root partition..."
gpart add -t freebsd-ufs "$DISK"
ROOT_PART="${DISK}p2"

mkdir -p "$MNT"

if [ "$IMAGE_MODE" = "0" ]; then
    # Normal install: a file-level copy of the RUNNING LIVE SESSION.
    #
    # The live root is the in-kernel unionfs (read-only uzip lower + tmpfs
    # writable upper). We copy straight from "/" so that everything done
    # during the live session -- pkg installs, config changes -- lands on
    # the installed disk. Copying the pristine uzip instead would silently
    # drop all of that; capturing the live session is the whole point.
    #
    # The copy is done with `find | cpio -pdmu`, NOT bsdtar. FreeBSD 15
    # unionfs has a bug reading lower-layer symlinks: readlink() through
    # the union intermittently returns EINVAL/EBADF with garbage metadata.
    # bsdtar/libarchive treats that as fatal and aborts the whole archive
    # (observed: a 155k-file system truncated to ~137 files, every run).
    # cpio treats it as a per-file warning -- it skips that one entry and
    # keeps going -- so the copy completes. cpio -pdmu preserves hardlinks
    # (/rescue), file flags (schg), setuid/setgid/sticky, ownership, perms
    # and mtime (all verified on the live ISO).
    #
    # find is given an explicit prune list rather than relying on -x
    # alone, because unionfs st_dev detection isn't trustworthy. Every
    # mount point and bit of live-only cruft is named:
    #   /mnt                          -- the install target (CRITICAL:
    #                                    never walk the tree we are
    #                                    actively writing into)
    #   /dev /proc /tmp /media        -- pseudo / tmpfs mounts
    #   /compat/linux/{proc,sys,dev}  -- linprocfs/linsysfs/devfs submounts
    #   /var/run /var/tmp /var/cache  -- stale runtime cruft
    #   /etc/rc.conf.local            -- the live-only root_rw_mount="NO"
    #                                    override init_script writes into
    #                                    the tmpfs upper
    #
    # Stage 2 re-walks the symlinks and recreates any that cpio's stage-1
    # pass dropped to the unionfs bug. A dedicated readlink() sweep (with
    # a short retry) reliably reads symlinks that are flaky under cpio's
    # access pattern -- a full census read all 7,657 with zero failures.
    if [ ! -e /dev/md0.uzip ]; then
        echo "ERROR: /dev/md0.uzip not found."
        echo "The installer must be run from a booted Gershwin live ISO."
        exit 1
    fi

    report_progress "Formatting" 20 "Formatting root filesystem..."
    newfs -U "$ROOT_PART"

    report_progress "Mounting" 22 "Mounting target filesystems..."
    mount "$ROOT_PART" "$MNT"
    if [ "$BOOT_METHOD" = "UEFI" ]; then
        mkdir -p "$MNT/efi"
        mount -t msdosfs "$EFI_PART" "$MNT/efi"
    fi

    # Shared prune expression for both the cpio copy and the symlink
    # sweep -- keep the two stages in sync by using the same $PRUNE.
    PRUNE="-path /mnt -prune -o -path /dev -prune -o -path /proc -prune -o"
    PRUNE="$PRUNE -path /tmp -prune -o -path /media -prune -o"
    PRUNE="$PRUNE -path /compat/linux/proc -prune -o -path /compat/linux/sys -prune -o -path /compat/linux/dev -prune -o"
    PRUNE="$PRUNE -path /var/run -prune -o -path /var/tmp -prune -o -path /var/cache -prune -o"
    PRUNE="$PRUNE -path /etc/rc.conf.local -prune -o"

    # The devd-suppression workaround at the top of this script mounts an
    # empty tmpfs over /usr/local/sbin. Unmount it before the copy so the
    # real package binaries there (cupsd, avahi-daemon, blkid, automount,
    # ...) are captured -- otherwise find walks the empty tmpfs and the
    # installed system is missing all of /usr/local/sbin. Partitioning is
    # done and the target is already mounted, so devd is no longer a
    # concern; clearing MOUNTED_TMPFS keeps the EXIT trap from retrying.
    if [ "$MOUNTED_TMPFS" = "1" ]; then
        umount /usr/local/sbin 2>/dev/null || true
        MOUNTED_TMPFS=0
    fi

    report_progress "Copying" 30 "Copying live system to $MNT..."
    echo "Copying live system to $MNT (find | cpio) ..."
    # cpio exits non-zero when it skips entries (the unionfs symlink bug),
    # which is expected and handled by the stage-2 sweep -- so don't let
    # set -e abort here. The critical-path check below catches a real
    # (catastrophic) copy failure instead.
    set +e
    # shellcheck disable=SC2086
    find -x / $PRUNE -print 2>/dev/null | cpio -pdmu "$MNT"
    set -e
    for p in bin/sh sbin/init etc/rc boot/kernel/kernel usr/bin/login lib/libc.so.7; do
        if [ ! -e "$MNT/$p" ]; then
            echo "ERROR: copy incomplete -- $MNT/$p is missing after cpio."
            exit 1
        fi
    done
    report_progress "Copying" 78 "File copy complete; repairing symlinks..."

    # Stage 2: recreate any symlinks cpio dropped to the unionfs bug.
    set +e
    # shellcheck disable=SC2086
    find -x / $PRUNE -type l -print 2>/dev/null | while IFS= read -r l; do
        [ -L "$MNT$l" ] && continue
        tgt=""
        n=0
        while [ -z "$tgt" ] && [ "$n" -lt 3 ]; do
            tgt=$(readlink "$l" 2>/dev/null)
            n=$((n + 1))
        done
        if [ -n "$tgt" ]; then
            mkdir -p "$MNT$(dirname "$l")"
            ln -sf "$tgt" "$MNT$l"
        else
            echo "WARNING: unreadable symlink $l -- not recreated on target" >&2
        fi
    done
    set -e
    report_progress "Copying" 80 "Symlink repair complete."

    # Recreate the excluded mount-point / runtime dirs as empty so the
    # installed system's rc can mount over them.
    for d in mnt dev proc tmp media \
             compat/linux/proc compat/linux/sys compat/linux/dev/shm \
             var/run var/tmp var/cache; do
        mkdir -p "$MNT/$d"
    done
    chmod 1777 "$MNT/tmp" 2>/dev/null || true
else
    # Image-based install: tree-copy from the mounted source. newfs the
    # target, then rsync (preferred) or a tar pipe. The old `cp -a`
    # fallback is gone -- FreeBSD cp does not preserve hardlinks (it would
    # explode /rescue) and has no exclude mechanism; tar handles both.
    report_progress "Formatting" 20 "Formatting root filesystem..."
    newfs -U "$ROOT_PART"

    report_progress "Mounting" 22 "Mounting target filesystems..."
    echo "Mounting target..."
    mount "$ROOT_PART" "$MNT"
    if [ "$BOOT_METHOD" = "UEFI" ]; then
        mkdir -p "$MNT/efi"
        mount -t msdosfs "$EFI_PART" "$MNT/efi"
    fi

    report_progress "Mounting" 24 "Creating directory structure..."
    for d in dev proc run tmp var/run var/tmp var/cache; do
        mkdir -p "$MNT/$d"
    done
    chmod 1777 "$MNT/tmp" "$MNT/var/tmp"

    report_progress "Copying" 25 "Starting system copy from $SRC..."
    echo "Copying system from $SRC to $MNT..."

    # Runtime dirs that must not be copied from the source tree.
    EXCLUDES="dev proc sys tmp mnt media efi run var/run var/tmp var/cache compat"
    EXCLUDE_ARGS=""
    TAR_EXCLUDE_ARGS=""
    for d in $EXCLUDES; do
        EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude=$d"
        TAR_EXCLUDE_ARGS="$TAR_EXCLUDE_ARGS --exclude=./$d"
    done

    if command -v rsync >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        rsync -aHAX --info=progress2 $EXCLUDE_ARGS "${SRC%/}/" "$MNT" 2>&1 | \
        while IFS= read -r line; do
            echo "$line"
            pct=$(echo "$line" | sed -n 's/.*[[:space:]]\([0-9]*\)%.*/\1/p')
            if [ -n "$pct" ]; then
                scaled=$(awk -v p="$pct" 'BEGIN { printf "%d", 25 + (p * 55 / 100) }')
                report_progress "Copying" "$scaled" "Copying files... ${pct}%"
            fi
        done
    else
        report_progress "Copying" 30 "Copying files (tar)..."
        # shellcheck disable=SC2086
        ( cd "$SRC" && tar -cf - $TAR_EXCLUDE_ARGS . ) | ( cd "$MNT" && tar -xpf - )
        report_progress "Copying" 80 "File copy complete."
    fi

    # Recreate the excluded runtime dirs as empty mount points.
    for d in $EXCLUDES; do
        mkdir -p "$MNT/$d"
    done
fi

# Initialize Directory Services. dscli init is idempotent -- on the dd
# path /Local is already present (bit-exact from the uzip) and this just
# re-asserts nsswitch/sudoers; on the image path it sets /Local up fresh.
report_progress "Finalizing" 84 "Initializing Directory Services..."
echo "Running dscli init in chroot..."
chroot "$MNT" /System/Library/Tools/dscli init || true

# Install bootloader
report_progress "Bootloader" 86 "Installing bootloader..."
if [ "$BOOT_METHOD" = "UEFI" ]; then
    echo "Installing UEFI bootloader..."
    mkdir -p "$MNT/efi/EFI/BOOT"
    cp /boot/loader.efi "$MNT/efi/EFI/BOOT/BOOTX64.EFI"
    mkdir -p "$MNT/efi/EFI/freebsd"
    cp /boot/loader.efi "$MNT/efi/EFI/freebsd/loader.efi"

    # Register boot entry
    report_progress "Bootloader" 90 "Registering UEFI boot entry..."
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
report_progress "Configuration" 94 "Writing filesystem table..."
if [ "$IMAGE_MODE" = "0" ]; then
    # The copied root already carries the live session's /etc/fstab (the
    # fstab.extra entries: proc, linprocfs, tmpfs /tmp, linsysfs, fdescfs).
    # Prepend the per-install root and EFI entries so those mounts survive.
    {
        echo "$ROOT_PART   /      ufs   rw   1 1"
        if [ "$BOOT_METHOD" = "UEFI" ]; then
            echo "$EFI_PART    /efi   msdos rw   0 0"
        fi
        [ -f "$MNT/etc/fstab" ] && cat "$MNT/etc/fstab"
    } > "$MNT/etc/fstab.new"
    mv "$MNT/etc/fstab.new" "$MNT/etc/fstab"
else
    # Image-based install: write a fresh fstab.
    {
        echo "$ROOT_PART   /      ufs   rw   1 1"
        if [ "$BOOT_METHOD" = "UEFI" ]; then
            echo "$EFI_PART    /efi   msdos rw   0 0"
        fi
        echo "proc         /proc  procfs rw  0 0"
    } > "$MNT/etc/fstab"
fi

# Configure loader
report_progress "Configuration" 97 "Configuring boot loader..."
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
