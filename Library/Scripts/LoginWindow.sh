#!/bin/sh

# Redirect stdout and stderr to a fifo on Linux,
# making them accessible from a graphical session,
# without depending on nor failing in the presence of systemd
# if [ "$(uname -s)" = "Linux" ]; then
#     BOOTLOG_DIR=/var/log
#     BOOTLOG_FIFO=$BOOTLOG_DIR/LoginWindow.log.fifo
# 
#     [ -d "$BOOTLOG_DIR" ] || mkdir -p "$BOOTLOG_DIR"
#     [ -p "$BOOTLOG_FIFO" ] || { rm -f "$BOOTLOG_FIFO"; mkfifo "$BOOTLOG_FIFO"; }
# 
#     exec >"$BOOTLOG_FIFO" 2>&1
# fi

# /System/Library/Scripts/MountSystemImage.sh

. /System/Library/Makefiles/GNUstep.sh

export DISPLAY=:0

# Allow non-root users to power off, halt, and reboot the system
for bin in /sbin/poweroff /sbin/halt /sbin/reboot; do [ -e "$bin" ] && chmod 5755 "$bin"; done

# Add our fonts path to fontconfig
export FONTCONFIG_PATH=/System/Library/Preferences
export FONTCONFIG_FILE=$FONTCONFIG_PATH/fonts.conf

# TODO: Proper GPU kernel module loading for FreeSBD; this is too simplistic
# https://github.com/nomadbsd/NomadBSD/blob/master/config/etc/rc.d/initgfx
# or better: "kldxref would create that list for devmatch"
sysctl dev.vgapci 2>/dev/null | grep 0x8086 && kldload /boot/modules/i915kms.ko
sysctl dev.vgapci 2>/dev/null | grep 0x1022 && kldload /boot/modules/amdgpu.ko
sysctl dev.vgapci 2>/dev/null | grep 0x10de && kldload /boot/modulesn/nvidia.ko

# GPU / DRM readiness before starting X.
#
# On NextBSD the GPU KMS driver is loaded automatically by IOKit during device
# enumeration, so we must NOT kldload it ourselves. That attach is asynchronous,
# though, so wait for the DRM device node to appear before starting X — otherwise
# X races the attach, falls back to scfb on the EFI framebuffer, and the DRM
# aperture takeover then blanks the screen (black login + input that works but
# draws into a dead framebuffer).
if [ "$(uname -s)" = "NextBSD" ]; then
    for i in $(seq 1 100); do
        ls /dev/dri/card* >/dev/null 2>&1 && break
        sleep 0.1
    done            # ~10s cap, then start X regardless
fi

exec LoginWindow
