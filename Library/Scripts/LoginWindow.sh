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
    if sysctl dev.vgapci 2>/dev/null | grep -qE 'vendor=0x(8086|1002|10de|1234|80ee)' ||
       sysctl dev.virtio_pci 2>/dev/null | grep -q 'GPU adapter'; then
        for i in $(seq 1 100); do
            ls /dev/dri/card* >/dev/null 2>&1 && break
            sleep 0.1
        done            # ~10s cap, then start X regardless
    fi

    # virtio-gpu (1af4:1050) is not a vgapci device -- on arm64 `sysctl
    # dev.vgapci` is an unknown oid entirely -- so it hangs off virtio_pci and
    # needs the test above. It also cannot key off the driver name: the device
    # is `vtgpu` (base virtio_gpu(4), the console) until VirtIOGraphics.kext
    # takes it over, and `virtio_gpu_drm` after. dev.virtio_pci.N.%desc names
    # the transport, so it is stable across both and present from early boot.
    #
    # But waiting for card0 is NOT sufficient here, it is actively harmful on
    # its own: on virtio-gpu card0 appears BEFORE USB HID attaches. Measured
    # boot order on an arm64 guest:
    #
    #   virtio_gpu_drm0: <VirtIO GPU (DRM/KMS)>   <- card0 exists
    #   VT: Replacing driver ... with new "drmfb"
    #   hms0: <QEMU QEMU USB Tablet>              <- input, later
    #   hms1: <QEMU QEMU USB Mouse>
    #   hkbd0: <QEMU QEMU USB Keyboard>
    #
    # so releasing X the instant card0 appears hands it a machine with no
    # keyboard yet. X enumerates input exactly once at startup and XLibre has
    # no hotplug backend on FreeBSD, so that keyboard is lost for the whole
    # session (nextbsd#390/#391) -- observed as X adding 5 input devices with
    # the USB keyboard absent. Wait for a keyboard AND a pointer to attach,
    # then settle, the same shape as the NVIDIA delay below.
    if sysctl dev.virtio_pci 2>/dev/null | grep -q 'GPU adapter'; then
        for i in $(seq 1 150); do
            if devinfo 2>/dev/null | grep -qE '(hkbd|ukbd|atkbd)[0-9]' &&
               devinfo 2>/dev/null | grep -qE '(hms|ums)[0-9]'; then
                break
            fi
            sleep 0.1
        done            # ~15s cap, then start X regardless
        sleep 2         # let the rest of the HID tree settle, as NVIDIA does
    fi

    # Raspberry Pi 5 / BCM2712. NEITHER branch above fires here, so until now
    # this machine got no wait at all: the display is an FDT device on
    # simplebus, not PCI, so `sysctl dev.vgapci` is an unknown oid entirely,
    # and there is no virtio GPU either.
    #
    # It needs the wait more than any of them, because vc4 does not come from
    # the kernel at boot -- it is a kext that kextd autoloads from USERLAND,
    # which lands very late. Measured on a Pi 500+, by dmesg line:
    #
    #   623  hms0:  <PixArt USB Optical Mouse>
    #   629  hkbd0: <Pi 500+ Keyboard>
    #   759  vc40:  <Broadcom VideoCore VI (KMS)>
    #   793  VT: Replacing driver "fb" with new "drmfb"
    #
    # Note that ordering is the OPPOSITE of virtio-gpu above: input attaches
    # ~130 lines BEFORE the display. So this branch deliberately waits only for
    # the device node -- by the time it exists the HID tree has long since
    # settled, and the keyboard-and-pointer wait virtio needs would be dead
    # code here.
    #
    # Detected by the FDT `model`, not a compatible string, and that is not a
    # style choice: ofwdump prints a MULTI-string property as hex with no ASCII
    # line, and the root `compatible` is multi-string. Grepping the tree for
    # "vc6" matches nothing at all. `model` is a single string and prints
    # readable.
    #
    # Gated on the kext being installed for the same reason VMware is left out
    # above: if nothing will ever create the node, waiting on it only stalls
    # boot for the full timeout.
    if [ -d /System/Library/Extensions/VideoCore6KMS.kext ] &&
       ofwdump -P model / 2>/dev/null | grep -q 'Raspberry Pi'; then
        __lw_t0=$(date +%s)
        for i in $(seq 1 300); do
            # card0 alone is NOT the display. v3d -- the GPU, a separate device
            # on 2712 -- also registers a DRM device, and DRM minors are handed
            # out in attach order, so card0 is whichever of the two won the
            # race. Require the vc4 device itself, so this cannot be satisfied
            # by the render node.
            if [ -e /dev/dri/card0 ] &&
               devinfo 2>/dev/null | grep -qE '(^| )vc40( |$)'; then
                break
            fi
            sleep 0.1
        done            # ~30s cap, then start X regardless
        logger -t LoginWindow "rpi: waited $(($(date +%s) - __lw_t0))s for vc4 card0 (present=$([ -e /dev/dri/card0 ] && echo yes || echo NO))"
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
