#!/bin/sh

# System preparation script for Gershwin on FreeBSD systems.
# This script performs a small set of post-install configuration steps required
# for the desktop to work (users->video group, setuid helpers, kernels, sysctls).
# Run this script as root.

# Basic logging helper
log() {
    printf "%s\n" "[SystemPrepare] $*"
}

# Verify platform and detect OS family
get_os_like() {
    OS_LIKE=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_LIKE="${ID_LIKE:-${ID:-}}"
        OS_LIKE="$(printf "%s" "$OS_LIKE" | tr '[:upper:]' '[:lower:]')"
    fi
}

is_debian_like() {
    echo "${OS_LIKE}" | grep -qE 'debian|devuan' 2>/dev/null
}

is_freebsd() {
    uname -s | grep -qE 'FreeBSD|GhostBSD' 2>/dev/null || echo "${OS_LIKE}" | grep -qE 'freebsd' 2>/dev/null
}

verify_platform() {
    get_os_like
    if is_freebsd || is_debian_like; then
        log "Detected platform: ${OS_LIKE:-$(uname -s)}"
    else
        log "Error: This script is intended for FreeBSD or Debian-like systems"
        exit 1
    fi
}

# Ensure we are running as root
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log "This script must be run as root"
        exit 1
    fi
}

# Use consistent, small functions for each task so behaviour is clear and testable

# Configure pkg repository type: some packages needed are only available in 'latest'
configure_pkg_repo() {
    log "Configuring pkg repository channel to 'latest' (temporary improvement for xlibre packages)"
    sed -i'' -e 's|quarterly|latest|g' /etc/pkg/FreeBSD.conf || log "Warning: failed to update /etc/pkg/FreeBSD.conf"
}

# Helpers for Debian/Devuan package management and groups
apt_pkg_exists() {
    command -v apt-cache >/dev/null 2>&1 && apt-cache show "$1" >/dev/null 2>&1
}

ensure_group_exists() {
    grp="$1"
    if ! getent group "$grp" >/dev/null 2>&1; then
        log "Group $grp not found; creating"
        groupadd "$grp" || log "Warning: failed to create group $grp"
    fi
}

pick_package() {
    # Print first available package from arguments
    for p in "$@"; do
        if apt_pkg_exists "$p"; then
            printf "%s" "$p"
            return 0
        fi
    done
    return 1
}

is_devuan() {
    if [ -f /etc/os-release ]; then
        grep -qi '^ID=devuan' /etc/os-release >/dev/null 2>&1 && return 0
        echo "${OS_LIKE}" | grep -q devuan 2>/dev/null && return 0
    fi
    return 1
}

install_debian_packages() {
    log "Installing Debian/Devuan packages (via apt)"
    apt-get update || log "Warning: apt-get update failed"

    TO_INSTALL=""
    add_pkg() {
        TO_INSTALL="$TO_INSTALL $1"
        log "Selected package: $1"
    }

    if pkg=$(pick_package nano); then add_pkg "$pkg"; fi
    if pkg=$(pick_package xserver-xorg xserver-xorg-core); then add_pkg "$pkg"; fi
    if pkg=$(pick_package xinit); then add_pkg "$pkg"; fi
    if pkg=$(pick_package x11-utils); then add_pkg "$pkg"; fi
    if pkg=$(pick_package xdotool); then add_pkg "$pkg"; fi
    if pkg=$(pick_package x11-xkb-utils); then add_pkg "$pkg"; fi
    if pkg=$(pick_package autofs); then add_pkg "$pkg"; fi
    if pkg=$(pick_package fuse fuse3); then add_pkg "$pkg"; fi
    if pkg=$(pick_package exfatprogs exfat-fuse); then add_pkg "$pkg"; fi
    if pkg=$(pick_package ntfs-3g); then add_pkg "$pkg"; fi
    if pkg=$(pick_package hfsprogs); then add_pkg "$pkg"; fi
    if pkg=$(pick_package squashfuse); then add_pkg "$pkg"; fi
    if pkg=$(pick_package xserver-xorg-video-intel); then add_pkg "$pkg"; fi
    if pkg=$(pick_package mesa-utils); then add_pkg "$pkg"; fi

    if [ -n "${TO_INSTALL}" ]; then
        log "Installing: ${TO_INSTALL}"
        apt-get install -y ${TO_INSTALL} || log "Warning: apt-get install failed"
    else
        log "No candidate Debian packages available to install"
    fi
}

add_users_to_video_group_debian() {
    log "Adding local users (UID >= 1000) to sudo and video groups (Debian-like)"
    ensure_group_exists video
    ensure_group_exists sudo

    for user in $(awk -F: '$3 >= 1000 {print $1}' /etc/passwd); do
        if id -nG "$user" | grep -qw sudo; then
            log "$user already in sudo group"
        else
            usermod -a -G sudo "$user" 2>/dev/null && log "Added $user to sudo group" || log "Failed to add $user to sudo group"
        fi

        if id -nG "$user" | grep -qw video; then
            log "$user already in video group"
        else
            usermod -a -G video "$user" 2>/dev/null && log "Added $user to video group" || log "Failed to add $user to video group"
        fi
    done
}

enable_display_manager_debian() {
    log "Attempting to enable a display manager (Debian-like)"

    # systemd-based systems
    if command -v systemctl >/dev/null 2>&1; then
        for svc in gdm3 sddm lightdm gdm; do
            if systemctl list-unit-files | grep -q "^${svc}"; then
                systemctl enable "$svc" || log "Warning: failed to enable $svc"
                return
            fi
        done
        log "No known display manager systemd service found"
    fi

    # sysvinit (Devuan) using update-rc.d
    if [ -d /etc/init.d ] && command -v update-rc.d >/dev/null 2>&1; then
        for svc in gdm3 sddm lightdm; do
            if [ -x "/etc/init.d/$svc" ]; then
                update-rc.d "$svc" defaults || log "Warning: failed to setup $svc via update-rc.d"
                return
            fi
        done
        log "No known display manager init.d script found; skipping"
    fi
}

create_devuan_loginwindow_init() {
    if is_devuan && [ -d /etc/init.d ]; then
        log "Creating /etc/init.d/loginwindow for Devuan (sysvinit)"
        cat >/etc/init.d/loginwindow <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          loginwindow
# Required-Start:    $remote_fs $syslog
# Required-Stop:     $remote_fs $syslog
# Default-Start: 5
# Default-Stop:
# Short-Description: Run LoginWindow script at runlevel 5
### END INIT INFO

SCRIPT="/System/Library/Scripts/LoginWindow.sh"

case "$1" in
  start)
    echo "Starting LoginWindow script"
    "$SCRIPT" &
    ;;
  stop)
    echo "Nothing to stop for LoginWindow script"
    ;;
  restart)
    $0 stop
    $0 start
    ;;
  *)
    echo "Usage: /etc/init.d/loginwindow {start|stop|restart}"
    exit 1
    ;;
esac

exit 0
EOF
        chmod +x /etc/init.d/loginwindow || log "Warning: failed to chmod /etc/init.d/loginwindow"
        if command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d loginwindow defaults || log "Warning: update-rc.d failed"
        fi

        if [ -f /etc/inittab ]; then
            sed -i.bak -E 's/^id:[0-9]+:initdefault:/id:5:initdefault:/; t; $a id:5:initdefault:' /etc/inittab || log "Warning: failed to update /etc/inittab (id)"
            grep -q '^lw:5:respawn:/System/Library/Scripts/LoginWindow.sh' /etc/inittab || echo 'lw:5:respawn:/System/Library/Scripts/LoginWindow.sh' >> /etc/inittab
            if command -v telinit >/dev/null 2>&1; then
                telinit q || log "Warning: telinit q failed"
                telinit 5 || log "Warning: telinit 5 failed"
            fi
        fi
    fi
}

install_packages() {
    if is_debian_like; then
        install_debian_packages
        return
    fi

    log "Installing base packages (editor, X11 stack, filesystem helpers)"
    pkg install -y nano \
        drm-kmod xlibre-server xlibre-drivers setxkbmap \
        xkill xwininfo xdotool \
        automount \
        fusefs-exfat fusefs-ext2 fusefs-hfsfuse fusefs-lkl fusefs-ntfs fusefs-squashfuse || \
        log "Warning: one or more pkg installs failed"
}

# Load kernel module for Intel GPUs in late boot; required for proper acceleration
configure_kld_list() {
    log "Ensuring i915kms is in kld_list (for Intel iGPU support)"
    sysrc kld_list+="i915kms" || log "Warning: sysrc failed to update kld_list"

    # Try to load the module now so users don't need to reboot to get basic acceleration
    if command -v kldload >/dev/null 2>&1; then
        if kldstat 2>/dev/null | grep -q 'i915kms'; then
            log "i915kms already loaded"
        else
            if kldload i915kms >/dev/null 2>&1; then
                log "Loaded i915kms module now"
            else
                log "Warning: failed to load i915kms now; it will be loaded at next boot"
            fi
        fi
    fi
}

# Add interactive desktop users to groups that allow access to video and privileged helpers
# Rationale: GUI users need access to video devices; adding to wheel also convenient for local admin tasks
add_users_to_video_group() {
    log "Adding local users (UID >= 1000) to wheel and video groups"
    # Find all users with UID >= 1000
    for user in $(awk -F: '$3 >= 1000 {print $1}' /etc/passwd); do
        pw groupmod wheel -m "$user" 2>/dev/null && log "Added $user to wheel group"
        pw groupmod video -m "$user" 2>/dev/null && log "Added $user to video group"
    done
}

# Set setuid on a small number of system helpers so GUI tools and non-root users can perform common actions
# Rationale: mount/umount/eject/shutdown/reboot/halt are commonly invoked from GUI tools and expect setuid
set_binary_setuid() {
    log "Setting setuid on helper binaries (mount, umount, eject, shutdown, halt, reboot)"
    binaries="/sbin/mount /sbin/umount /sbin/eject /sbin/shutdown /sbin/halt /sbin/reboot"
    for binary in $binaries; do
        if [ -x "$binary" ]; then
            chmod u+s "$binary" && log "Set setuid on $binary" || log "Failed to set setuid on $binary"
        else
            log "Binary $binary does not exist or is not executable"
        fi
    done
}

# Enable LoginWindow service so the graphical login is started at boot
enable_loginwindow() {
    log "Enabling LoginWindow service (graphical login)"
    service loginwindow enable || log "Warning: failed to enable loginwindow"
}

# Insert sysctl settings block with explanatory comments
add_sysctl_tuning() {
    SYSCTL_CONF="/etc/sysctl.conf"

    log "Appending Gershwin sysctl tuning block into $SYSCTL_CONF"

    cat >> "$SYSCTL_CONF" <<'EOF'
# Enhance shared memory X11 interface
kern.ipc.shmmax=67108864
kern.ipc.shmall=32768

# Enhance desktop responsiveness under high CPU use (200/224)
kern.sched.preempt_thresh=224

# Disable PC Speaker
hw.syscons.bell=0

# Shared memory for Chromium
kern.ipc.shm_allow_removed=1

# Needed for Baloo local file indexing
kern.maxfiles=3000000
kern.maxvnodes=1000000

# Uncomment this to prevent users from seeing information about processes that
# are being run under another UID.
# security.bsd.see_other_uids=0
# Note: to display the correct icons in Dock for processes running as root, users must be able to see information on root processes
security.bsd.see_other_gids=0
security.bsd.see_jail_proc=0

# Allow dmesg for normal users
security.bsd.unprivileged_read_msgbuf=1

# Allow truss for normal users
security.bsd.unprivileged_proc_debug=1

# kern.randompid=1
kern.evdev.rcpt_mask=6

# Allow non-root users to run truss
security.bsd.unprivileged_proc_debug=1

# Allow non-root users to mount
vfs.usermount=1

# Automatically switch audio devices (e.g., from HDMI to USB sound device when plugged in)
# https://www.reddit.com/r/freebsd/comments/454j5p/
hw.snd.default_auto=2

# Enable 5.1 audio systems, e.g., BOSE Companion 5 (USB)
hw.usb.uaudio.default_channels=6

# Optimize sound settings for "studio quality", thanks @mekanix
# https://archive.fosdem.org/2019/schedule/event/freebsd_in_audio_studio/
# https://meka.rs/blog/2017/01/25/sing-beastie-sing/
# But the author does not recommend them for general desktop use, as they may drain the battery faster
# https://github.com/helloSystem/ISO/issues/217#issuecomment-863812623
# kern.timecounter.alloweddeviation=0
# hw.usb.uaudio.buffer_ms=2
# hw.snd.latency=0
# # sysctl dev.pcm.0.bitperfect=1

# Remove crackling on Intel HDA
# https://github.com/helloSystem/hello/issues/395
hw.snd.latency=7

# Increase sound volume
hw.snd.vpc_0db=20

# Enable sleep on lid close
hw.acpi.lid_switch_state="S3"

kern.coredump=0

# Fix "FATAL: kernel too old" when running Linux binaries
compat.linux.osrelease="5.0.0"
# END gershwin system tuning
EOF
}

# Reboot at the end to ensure modules and kernel settings are applied
perform_reboot() {
    log "Rebooting to finish system preparation..."
    reboot
}

# Main execution: orchestrates high-level steps without changing behaviour
main() {
    verify_platform
    require_root

    configure_pkg_repo
    install_packages

    if is_debian_like; then
        # Debian/Devuan-specific steps
        add_users_to_video_group_debian
        enable_display_manager_debian
        create_devuan_loginwindow_init
        log "Skipping FreeBSD-specific configuration on Debian-like system"
    else
        configure_kld_list

        add_users_to_video_group
        set_binary_setuid

        enable_loginwindow

        add_sysctl_tuning
    fi

    # TODO: set nextboot (once) to the newly installed system via efi
    # Do not reboot automatically by default; allow caller to request reboot via
    # REBOOT=1 environment variable (e.g., REBOOT=1 ./SystemPrepare.sh)
    if [ "${REBOOT}" = "1" ]; then
        perform_reboot
    else
        log "Reboot skipped by SystemPrepare. Set REBOOT=1 to reboot automatically, or reboot now to apply kernel/module changes."
    fi
}

# Run the main function
main

