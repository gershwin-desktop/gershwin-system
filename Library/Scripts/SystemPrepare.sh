#!/bin/sh

# System preparation script for Gershwin on FreeBSD systems.
# This script performs a small set of post-install configuration steps required
# for the desktop to work (users->video group, setuid helpers, kernels, sysctls).
# Run this script as root.

# Basic logging helper
log() {
    printf "%s\n" "[SystemPrepare] $*"
}

# Verify we're on FreeBSD or a FreeBSD variant
verify_platform() {
    if ! uname -s | grep -qE "FreeBSD|GhostBSD"; then
        log "Error: This script is only for FreeBSD or FreeBSD variants"
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

# Install required packages for a minimal desktop experience
install_packages() {
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
    configure_kld_list

    add_users_to_video_group
    set_binary_setuid

    enable_loginwindow

    add_sysctl_tuning

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

