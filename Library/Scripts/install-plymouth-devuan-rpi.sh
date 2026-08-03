#!/bin/sh
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause
#
# install-plymouth-devuan-rpi.sh
#
# Enables the plymouth "spinner" boot splash on a Linux system that boots
# through plymouth + initramfs-tools with an RPi-style firmware cmdline.txt.
#
# This script is deliberately conservative: before it changes anything it
# verifies that the system can actually do what is asked, installing the
# missing packages via apt when needed, and aborts with a clear reason if it
# cannot.  Run on the target system as root, or use -n to only validate.
#
# Usage:
#   sudo ./install-plymouth-devuan-rpi.sh [-n]
#   -n, --dry-run   only check suitability; change nothing

set -eu

DRY_RUN=0
case "${1:-}" in
	-n|--dry-run) DRY_RUN=1 ;;
	-h|--help)
		sed -n '2,18p' "$0"
		exit 0
		;;
esac

note() { printf '  %s\n' "$1"; }
warn() { printf 'warning: %s\n' "$1" >&2; }
die()  { printf 'error: %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# phase 1: hard environment prerequisites
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must be run as root (use sudo)"

case "$(uname -s)" in
	Linux) ;;
	*) die "unsupported operating system '$(uname -s)'; this needs Linux" ;;
esac

# ---------------------------------------------------------------------------
# phase 2: ensure the required tooling is present (apt install if needed)
# ---------------------------------------------------------------------------
need=""
command_exists() { command -v "$1" >/dev/null 2>&1; }

for tool in plymouth plymouthd plymouth-set-default-theme; do
	command_exists "$tool" || need="$need plymouth"
done
command_exists update-initramfs || need="$need initramfs-tools"

if [ -z "$need" ]; then
	# tooling present; now make sure the spinner theme (card: plymouth-themes)
	if [ ! -f /usr/share/plymouth/themes/spinner/spinner.plymouth ]; then
		need="plymouth-themes"
	fi
fi

if [ -n "$need" ]; then
	if [ "$DRY_RUN" = 1 ]; then
		die "packages would need to be installed (dry run):$need"
	fi
	command_exists apt-get || die "aborting: missing packages($need) but apt-get is not available"

	echo "installing required packages:$need"
	apt-get update >/dev/null 2>&1 || true
	# SC2086: $need is an intentional space-separated list of package names
	# shellcheck disable=SC2086
	apt-get install -y $need 2>&1 || die "aborting: apt-get install failed for:$need"
	echo "installed:$need"

	# verify the install actually satisfied our needs
	for tool in plymouth plymouthd plymouth-set-default-theme; do
		if ! command_exists "$tool"; then
			die "aborting: $tool still missing after install"
		fi
	done
	command_exists update-initramfs || die "aborting: update-initramfs still missing after install"
fi

# ---------------------------------------------------------------------------
# phase 3: plymouth plugin and renderer paths
# ---------------------------------------------------------------------------
plugin_dir="$(plymouth --get-splash-plugin-path 2>/dev/null || true)"
[ -n "$plugin_dir" ] || die "aborting: could not determine the plymouth plugin path"
plugin_dir="${plugin_dir%/}"

theme_file="/usr/share/plymouth/themes/spinner/spinner.plymouth"
[ -f "$theme_file" ] || die "aborting: spinner theme not at $theme_file (install plymouth-themes)"

spinner_module="$(sed -n 's/^ModuleName[[:space:]]*=[[:space:]]*//p' "$theme_file" \
	2>/dev/null | head -n1 | tr -d '\r')"
[ -n "$spinner_module" ] || die "aborting: spinner theme declares no ModuleName"
[ -f "${plugin_dir}/${spinner_module}.so" ] || \
	die "aborting: spinner module '${plugin_dir}/${spinner_module}.so' is missing"

have_renderer=no
for rdir in "${plugin_dir}/../renderers" \
            "${plugin_dir}/renderers" \
            /usr/lib/plymouth/renderers \
            /lib/plymouth/renderers; do
	if [ -f "${rdir}/drm.so" ]; then
		have_renderer=yes
		break
	fi
done
[ "$have_renderer" = yes ] || \
	warn "no drm.so renderer found; the spinner may only work over a text console"

# ---------------------------------------------------------------------------
# phase 4: graphics device present?
# ---------------------------------------------------------------------------
if [ -d /dev/dri ]; then
	note "graphics: DRM nodes present under /dev/dri"
else
	warn "cannot find /dev/dri - the graphical spinner may not render here"
fi

# ---------------------------------------------------------------------------
# phase 5: kernel / initramfs prerequisites
# ---------------------------------------------------------------------------
kernel_version="$(uname -r 2>/dev/null || true)"
if [ -n "$kernel_version" ] && [ -d "/usr/lib/modules/${kernel_version}" ]; then
	note "kernel: modules present for $kernel_version"
else
	warn "running kernel '${kernel_version}' has no modules directory; initramfs build may fail"
fi

have_moddir=no
for k in /usr/lib/modules/*/; do
	if [ -d "$k" ]; then
		have_moddir=yes
		break
	fi
done
[ "$have_moddir" = yes ] || warn "no kernel modules under /usr/lib/modules - cannot build an initramfs"

# ---------------------------------------------------------------------------
# phase 6: boot command line file + writability
# ---------------------------------------------------------------------------
cmdline=
for cand in /boot/firmware/cmdline.txt \
            /boot/broadcom/cmdline.txt \
            /boot/cmdline.txt; do
	if [ -f "$cand" ]; then
		cmdline="$cand"
		break
	fi
done
[ -n "$cmdline" ] || die "aborting: no boot 'cmdline.txt' found - this is not an RPi-style boot"

boot_dir="$(dirname "$cmdline")"
if [ "$DRY_RUN" = 0 ]; then
	tmp="$boot_dir/.install-plymouth-writetest"
	if ! : >"$tmp" 2>/dev/null; then
		rm -f "$tmp"
		die "aborting: boot filesystem '$boot_dir' is not writable"
	fi
	rm -f "$tmp"
else
	[ -w "$boot_dir" ] || warn "boot dir '$boot_dir' not writable (not tested in dry run)"
fi

line="$(sed -n '1p' "$cmdline" 2>/dev/null | tr -d '\r')"
case "$line" in
	*root=*) ;;
	*) warn "existing cmdline has no root= argument (unexpected); proceeding with care" ;;
esac

[ "$DRY_RUN" = 1 ] && { echo "check ok: system is ready; nothing changed (dry run)."; exit 0; }

# ---------------------------------------------------------------------------
# action 1: default theme
# ---------------------------------------------------------------------------
plymouth-set-default-theme spinner
echo "set default plymouth theme to spinner"

# ---------------------------------------------------------------------------
# action 2: rework the kernel command line (with backup)
# ---------------------------------------------------------------------------
backup="${cmdline}.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$cmdline" "$backup"
echo "backed up cmdline to: $backup"

new=""
has_console=no
has_quiet=no
has_splash=no

for arg in $line; do
	case "$arg" in
		# serial consoles force plymouth to use a text splash
		'console=ttyAMA'*|'console=serial'*|'console=ttyS'*)
			continue
			;;
		'console=tty1'|'console=tty0')
			has_console=yes
			new="$new $arg"
			;;
		'splash')
			has_splash=yes
			new="$new $arg"
			;;
		'quiet')
			has_quiet=yes
			new="$new $arg"
			;;
		'')
			;;
		*)
			new="$new $arg"
			;;
	esac
done

[ "$has_console" = yes ] || new="$new console=tty1"
[ "$has_splash" = yes ] || new="$new splash"
[ "$has_quiet" = yes ] || new="$new quiet"

new="$(printf '%s\n' "$new" | sed -e 's/^[[:space:]]*//;s/  */ /g')"
printf '%s\n' "$new" > "${cmdline}.new"
mv "${cmdline}.new" "$cmdline"
sync
echo "updated kernel command line:"
echo "  $new"

# ---------------------------------------------------------------------------
# action 3: rebuild initramfs
# ---------------------------------------------------------------------------
if update-initramfs -u -k all 2>&1; then
	:
else
	warn "update-initramfs (-k all) failed; retrying with the running kernel only"
	update-initramfs -u 2>/dev/null || \
		die "aborting: initramfs could not be rebuilt; restore '$backup' and review modules"
fi

echo
echo "done. reboot to see the spinner; to revert, restore '$backup'."
