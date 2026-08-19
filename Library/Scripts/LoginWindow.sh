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

if [ "$(uname -s)" = "NextBSD" ]; then
    # Any GPU we ship a DRM kext for gets a KMS device node, which IOKit brings
    # up asynchronously — so wait for it before starting X, else X races the
    # attach, falls back to scfb on the EFI framebuffer, and the DRM aperture
    # takeover blanks the screen for the rest of the session.
    #
    #   8086 Intel      1002 AMD/ATI     10de NVIDIA
    #   1234 Bochs      — qemu's default -vga std / bochs-display
    #   80ee VirtualBox — vboxvideo
    #
    # The virtual-GPU ids matter as much as the real ones now: BochsGraphics.kext
    # and VBoxGraphics.kext both bind and both take the aperture. qemu with
    # -vga std IS 1234:1111, so a plain VM hits this race on every boot — it is
    # what blanked the nextbsd screenshot gate.
    #
    # NOT listed: 15ad (VMware). No vmwgfx kext ships, so that node never
    # appears and waiting on it would stall boot for the full timeout.
    #
    # virtio-gpu (1af4:1050) cannot be a vendor id in the list above, because it
    # is not a vgapci device at all -- on an arm64 guest `sysctl dev.vgapci`
    # returns "unknown oid" and this whole branch never fires. It hangs off
    # virtio_pci, so it needs its own test, and that test cannot key off the
    # driver name either: the device is `vtgpu` (base virtio_gpu(4), which owns
    # the console from early boot) until VirtIOGraphics.kext takes it over, and
    # `virtio_gpu_drm` afterwards. dev.virtio_pci.N.%desc is stable across both
    # -- it describes the transport, not whoever won the child -- and is present
    # long before either driver settles, which is exactly when this gate runs.
    #
    # The race is real here and arrives late: the kext is loaded by kextd, which
    # then hands the device over atomically, so card0 can appear well after
    # LoginWindow starts.
    if sysctl dev.vgapci 2>/dev/null | grep -qE 'vendor=0x(8086|1002|10de|1234|80ee)' ||
       sysctl dev.virtio_pci 2>/dev/null | grep -q 'GPU adapter'; then
        for i in $(seq 1 100); do
            ls /dev/dri/card* >/dev/null 2>&1 && break
            sleep 0.1
        done            # ~10s cap, then start X regardless
    fi

    # NVIDIA only: card0 existing is not the same as "safe to start X". Starting
    # X the instant the node appears either panics the kernel in the nvidia-drm
    # GEM mmap fault path, or brings up a session with no keyboard/mouse — X
    # enumerates input exactly once at startup and XLibre has no hotplug backend
    # on FreeBSD, so anything still enumerating is lost for the session. A short
    # settle delay works around both. See nextbsd#390 / nextbsd#391.
    if sysctl dev.vgapci 2>/dev/null | grep -q 'vendor=0x10de'; then
        sleep 2
    fi
fi

exec LoginWindow
