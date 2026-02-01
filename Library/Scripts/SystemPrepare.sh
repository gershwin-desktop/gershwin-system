#!/bin/sh

# System preparation script for Gershwin on FreeBSD, Devuan, Debian, Raspberry Pi OS systems.
# This script performs a small set of post-install configuration steps required
# for the desktop to work (users->video group, setuid helpers, kernels, sysctls).
# Run this script as root.

# If extending the script, ensure each function has a single responsibility
# and that the main() function orchestrates high-level steps only.
# Make each step idempotent, so re-running the script is safe.

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

is_ghostbsd() {
    if [ -f /etc/os-release ]; then
        grep -qi 'ID=ghostbsd' /etc/os-release >/dev/null 2>&1 && return 0
    fi
    # Some GhostBSD versions might have it in uname -s
    uname -s | grep -qi 'GhostBSD' >/dev/null 2>&1 && return 0
    return 1
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
    PKG_CONF="/etc/pkg/FreeBSD.conf"
    if [ -f "$PKG_CONF" ]; then
        if ! is_ghostbsd; then
            log "Vanilla FreeBSD detected; skipping repository change to 'latest'"
            return
        fi

        if grep -q 'latest' "$PKG_CONF" 2>/dev/null; then
            log "pkg repository already set to 'latest'"
        else
            log "Configuring pkg repository channel to 'latest' (temporary improvement for xlibre packages)"
            sed -i'' -e 's|quarterly|latest|g' "$PKG_CONF" || log "Warning: failed to update $PKG_CONF"
        fi
    else
        log "Skipping pkg repo configuration; $PKG_CONF not present"
    fi
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
    if pkg=$(pick_package dbus-x11); then add_pkg "$pkg"; fi
    if pkg=$(pick_package x11-utils); then add_pkg "$pkg"; fi
    if pkg=$(pick_package xdotool); then add_pkg "$pkg"; fi
    if pkg=$(pick_package x11-xkb-utils); then add_pkg "$pkg"; fi
    if pkg=$(pick_package autofs); then add_pkg "$pkg"; fi
    if pkg=$(pick_package fuse fuse3); then add_pkg "$pkg"; fi
    if pkg=$(pick_package exfatprogs exfat-fuse); then add_pkg "$pkg"; fi
    if pkg=$(pick_package ntfs-3g); then add_pkg "$pkg"; fi
    if pkg=$(pick_package hfsprogs); then add_pkg "$pkg"; fi
    if pkg=$(pick_package squashfuse); then add_pkg "$pkg"; fi

    # Network, firmware and utilities
    if pkg=$(pick_package sshpass); then add_pkg "$pkg"; fi

    # Wireless and Bluetooth firmware
    for fw in \
        firmware-linux \
        firmware-linux-nonfree \
        firmware-misc-nonfree \
        firmware-iwlwifi \
        firmware-realtek \
        firmware-atheros \
        firmware-brcm80211 \
        firmware-libertas \
        firmware-zd1211 \
        firmware-ti-connectivity \
        bluez-firmware; do
        if pkg=$(pick_package "$fw"); then
            add_pkg "$pkg"
        fi
    done

    # Prefer a generic driver metapackage that works across architectures
    if pkg=$(pick_package xserver-xorg-video-all); then
        add_pkg "$pkg"
    else
        # Fallback: attempt to install a broad set of drivers; pick_package will
        # ensure only packages available for this architecture are selected.
        for driver in \
            xserver-xorg-video-intel \
            xserver-xorg-video-amdgpu \
            xserver-xorg-video-ati \
            xserver-xorg-video-radeon \
            xserver-xorg-video-vesa \
            xserver-xorg-video-fbdev \
            xserver-xorg-video-vmware; do
            if pkg=$(pick_package "$driver"); then
                add_pkg "$pkg"
            fi
        done
    fi

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

change_elogind_conf() {
    # Check if /etc/elogind/logind.conf exists
    if [ -f /etc/elogind/logind.conf ]; then
        # Disable handling of power button presses, let Workspace handle it
        sed -i' ' 's/^HandlePowerKey=.*/HandlePowerKey=ignore # Workspace handles this key/' /etc/elogind/logind.conf
    fi
}

create_devuan_loginwindow_init() {
    if is_devuan && [ -d /etc/init.d ]; then
        if [ -f /etc/init.d/loginwindow ]; then
            log "/etc/init.d/loginwindow already exists; skipping creation"
        else
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
        fi

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


# Detect systemd and Raspberry Pi OS
is_systemd() {
    [ -d /run/systemd/system ] && return 0
    command -v systemctl >/dev/null 2>&1
}

is_raspberry_pi_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "${ID:-}${NAME:-}${PRETTY_NAME:-}${ID_LIKE:-}" in
            *raspbian*|*raspberry*|*raspberrypi*) return 0 ;;
        esac
    fi
    return 1
}

configure_lightdm_for_rpi() {
    LIGHTDM_CONF="/etc/lightdm/lightdm.conf"
    if [ ! -f "$LIGHTDM_CONF" ]; then
        log "No $LIGHTDM_CONF found; skipping LightDM configuration"
        return
    fi

    # Backup once
    if [ ! -f "${LIGHTDM_CONF}.gershwin.bak" ]; then
        cp -a "$LIGHTDM_CONF" "${LIGHTDM_CONF}.gershwin.bak" || log "Warning: failed to backup $LIGHTDM_CONF"
    fi

    # Comment out autologin-user and pi-greeter lines if present
    sed -i.bak -E 's/^\s*(autologin-user\s*=.*)/# \1/' "$LIGHTDM_CONF" || true
    sed -i -E 's/^\s*(greeter-session\s*=\s*pi-greeter)/# \1/' "$LIGHTDM_CONF" || true

    # Ensure greeter-session is set to lightdm-gtk-greeter (if not present)
    if ! grep -q '^[[:space:]]*greeter-session[[:space:]]*=.*lightdm-gtk-greeter' "$LIGHTDM_CONF" 2>/dev/null; then
        # Try to add under [Seat:*] if exists
        if grep -q '^\[Seat:' "$LIGHTDM_CONF" 2>/dev/null; then
            sed -n '/^\[Seat:/q;p' "$LIGHTDM_CONF" >/dev/null 2>&1 || true
            awk '/^\[Seat:/{print; print "greeter-session=lightdm-gtk-greeter"; skip=1; next} {print}' "$LIGHTDM_CONF" > "${LIGHTDM_CONF}.tmp" && mv "${LIGHTDM_CONF}.tmp" "$LIGHTDM_CONF"
        else
            # Append at end
            echo "greeter-session=lightdm-gtk-greeter" >> "$LIGHTDM_CONF"
        fi
        log "Configured lightdm to use lightdm-gtk-greeter"
    else
        log "LightDM already configured to use lightdm-gtk-greeter"
    fi
}

create_gershwin_xsession() {
    XSESSION_DIR="/usr/share/xsessions"
    XSESSION_FILE="$XSESSION_DIR/Gershwin.desktop"
    if [ ! -d "$XSESSION_DIR" ]; then
        log "$XSESSION_DIR does not exist; skipping session creation"
        return
    fi
    if [ -f "$XSESSION_FILE" ]; then
        log "$XSESSION_FILE already exists; skipping"
        return
    fi
    cat >"$XSESSION_FILE" <<'EOF'
[Desktop Entry]
Name=Gershwin
Exec=/System/Library/Scripts/Gershwin.sh
Type=Application
EOF
    log "Created $XSESSION_FILE"
}

create_systemd_loginwindow() {
    SERVICE_PATH="/usr/lib/systemd/system/LoginWindow.service"
    if ! is_systemd; then
        log "Systemd not present; skipping systemd LoginWindow setup"
        return
    fi

    if [ -f "$SERVICE_PATH" ]; then
        log "$SERVICE_PATH already exists; skipping creation"
    else
        cat >"$SERVICE_PATH" <<'EOF'
[Unit]
Description=LoginWindow
After=systemd-user-sessions.service dev-dri-card0.device dev-dri-renderD128.device
Wants=dev-dri-card0.device dev-dri-renderD128.device

# replaces plymouth-quit since LoginWindow quits plymouth on its own
Conflicts=plymouth-quit.service
After=plymouth-quit.service

# LoginWindow takes responsibility for stopping plymouth, so if it fails
# for any reason, make sure plymouth still stops
OnFailure=plymouth-quit.service

[Service]
ExecStart=/System/Library/Scripts/LoginWindow.sh
Restart=always

[Install]
Alias=display-manager.service
EOF
        log "Created $SERVICE_PATH"
        systemctl daemon-reload || log "Warning: systemctl daemon-reload failed"
    fi

    # Only enable/start if explicitly requested via LOGINWINDOW=1
    if [ "${LOGINWINDOW}" = "1" ]; then
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl is-enabled LoginWindow.service >/dev/null 2>&1; then
                log "LoginWindow.service already enabled"
            else
                systemctl disable lightdm >/dev/null 2>&1 || true
                systemctl mask lightdm >/dev/null 2>&1 || true
                systemctl enable LoginWindow.service || log "Warning: failed to enable LoginWindow.service"
                systemctl start LoginWindow.service || log "Warning: failed to start LoginWindow.service"
                log "LoginWindow.service enabled and started"
            fi
        fi
    else
        log "Created LoginWindow service file. To enable: set LOGINWINDOW=1 and re-run the script or run the commands manually."
    fi
}

configure_systemd_display() {
    if ! is_systemd; then
        log "Systemd not present; skipping systemd display configuration"
        return
    fi

    if is_raspberry_pi_os; then
        log "Raspberry Pi OS detected; applying recommended LightDM and session changes"
        configure_lightdm_for_rpi
        create_gershwin_xsession
        create_systemd_loginwindow
    else
        # For generic systemd Debian-like systems, create session file at least
        create_gershwin_xsession
        create_systemd_loginwindow
    fi
}

install_packages() {
    if is_debian_like; then
        install_debian_packages
        return
    fi

    log "Installing base packages (editor, X11 stack, filesystem helpers)"

    if is_ghostbsd; then
        X11_PKGS="xlibre-server xlibre-drivers"
    else
        # Standard Xorg and drivers for vanilla FreeBSD
        X11_PKGS="xorg-server xf86-video-intel xf86-video-amdgpu xf86-video-ati xf86-video-vmware xf86-video-vesa xf86-input-libinput"
    fi

    # Network, firmware and utilities
    WLAN_FW_PKGS="wifi-firmware-kmod wifi-firmware-ath10k-kmod wifi-firmware-ath11k-kmod wifi-firmware-iwlwifi-kmod wifi-firmware-mt76-kmod wifi-firmware-rtw88-kmod wifi-firmware-rtw89-kmod bwi-firmware-kmod bwn-firmware-kmod iwm-firmware-kmod iwi-firmware-kmod ipw-firmware-kmod"
    BT_FW_PKGS="bluez-firmware"

    pkg install -y nano \
        drm-kmod ${X11_PKGS} setxkbmap \
        xkill xwininfo xdotool \
        automount sshpass ${WLAN_FW_PKGS} ${BT_FW_PKGS} \
        ntp \
        fusefs-exfat fusefs-ext2 fusefs-hfsfuse fusefs-lkl fusefs-ntfs fusefs-squashfuse || \
        log "Warning: one or more pkg installs failed"
}

# Load kernel module for Intel GPUs in late boot; required for proper acceleration
configure_kld_list() {
    log "Ensuring i915kms is in kld_list (for Intel iGPU support)"

    if command -v sysrc >/dev/null 2>&1; then
        current_kld_list=$(sysrc -n kld_list 2>/dev/null || true)
        case "$current_kld_list" in
            *i915kms*)
                log "i915kms already present in kld_list"
                ;;
            *)
                sysrc kld_list+="i915kms" || log "Warning: sysrc failed to update kld_list"
                ;;
        esac
    else
        log "sysrc not available; skipping kld_list update"
    fi

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

# Enable and configure common FreeBSD services
enable_freebsd_services() {
    if command -v sysrc >/dev/null 2>&1; then
        log "Enabling common FreeBSD services (cups, avahi, ntpd, clear_tmp)"
        sysrc cupsd_enable="YES" # Enable CUPS printing daemon
        sysrc avahi_daemon_enable="YES" # Enable Avahi mDNS/DNS-SD daemon for network service discovery
        sysrc avahi_dnsconfd_enable="YES" # Enable Avahi's DNS resolver integration
        sysrc ntpd_enable="YES" # Enable NTP daemon for time synchronization
        sysrc ntpd_sync_on_start="YES" # Force ntpd to sync immediately on start
        sysrc clear_tmp_enable="YES" # Enable clearing of /tmp at boot
    else
        log "sysrc not available; cannot enable FreeBSD services"
    fi
}

# Add interactive desktop users to groups that allow access to video and privileged helpers
# Rationale: GUI users need access to video devices; adding to wheel also convenient for local admin tasks
add_users_to_video_group() {
    log "Adding local users (UID >= 1000) to wheel and video groups"
    # Find all users with UID >= 1000
    for user in $(awk -F: '$3 >= 1000 {print $1}' /etc/passwd); do
        if id -nG "$user" | grep -qw wheel; then
            log "$user already in wheel group"
        else
            pw groupmod wheel -m "$user" 2>/dev/null && log "Added $user to wheel group" || log "Failed to add $user to wheel group"
        fi

        if id -nG "$user" | grep -qw video; then
            log "$user already in video group"
        else
            pw groupmod video -m "$user" 2>/dev/null && log "Added $user to video group" || log "Failed to add $user to video group"
        fi
    done
} 

# Set setuid on a small number of system helpers so GUI tools and non-root users can perform common actions
# Rationale: mount/umount/eject/shutdown/reboot/halt are commonly invoked from GUI tools and expect setuid
set_binary_setuid() {
    log "Setting setuid on helper binaries (mount, umount, eject, shutdown, halt, reboot)"
    binaries="/sbin/mount /sbin/umount /sbin/eject /sbin/shutdown /sbin/halt /sbin/reboot"
    for binary in $binaries; do
        if [ -x "$binary" ]; then
            if [ -u "$binary" ]; then
                log "Setuid already set on $binary"
            else
                chmod u+s "$binary" && log "Set setuid on $binary" || log "Failed to set setuid on $binary"
            fi
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

    # Avoid duplicate blocks if present
    if grep -q '^# END gershwin system tuning' "$SYSCTL_CONF" 2>/dev/null; then
        log "Gershwin sysctl tuning already present in $SYSCTL_CONF"
        return
    fi

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
        change_elogind_conf

        # Configure systemd / Raspberry Pi OS display options when applicable
        configure_systemd_display

        log "Skipping FreeBSD-specific configuration on Debian-like system"
    else
        configure_kld_list

        enable_freebsd_services

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

