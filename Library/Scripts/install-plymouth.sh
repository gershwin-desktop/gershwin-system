#!/bin/sh
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause
#
# install-plymouth.sh
#
# Enables the plymouth "spinner" boot splash on the running local Linux
# system.  Supports the Debian-family (apt, initramfs-tools, update-grub)
# and the Arch family (pacman, mkinitcpio, grub-mkconfig).  On any other
# distribution it prints a notice and exits successfully without doing
# anything, so it is safe to call unconditionally from system provisioning.
# It does not assume a particular boot mechanism: it detects whatever the
# running system actually uses and edits the right place.
#
# Supported boot command line sources:
#   - GRUB     (/etc/default/grub + update-grub / grub-mkconfig)
#   - RPi/firmware cmdline.txt (/boot/firmware, /boot/broadcom, /boot)
#   - extlinux (/boot/extlinux/extlinux.conf)
#
# This script is deliberately conservative: before it changes anything it
# verifies that the system can actually do what is asked, installing the
# missing packages via the detected package manager when needed, and aborts
# with a clear reason if it cannot.  Run on the target system as root, or
# use -n to only validate.
#
# Usage:
#   sudo ./install-plymouth.sh [-n]
#   -n, --dry-run   only check suitability; change nothing

set -eu

DRY_RUN=0
case "${1:-}" in
	-n|--dry-run) DRY_RUN=1 ;;
	-h|--help)
		sed -n '2,28p' "$0"
		exit 0
		;;
esac

note() { printf '  %s\n' "$1"; }
warn() { printf 'warning: %s\n' "$1" >&2; }
die()  { printf 'error: %s\n' "$1" >&2; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# install a space-separated package list via the detected family
install_pkgs()
{
	if [ "$DRY_RUN" = 1 ]; then
		die "packages would need to be installed (dry run):$1"
	fi
	echo "installing required packages:$1"
	case "$FAMILY" in
		debian)
			# SC2086: $1 is an intentional space-separated list of package names
			# shellcheck disable=SC2086
			apt-get update >/dev/null 2>&1 || true
			# shellcheck disable=SC2086
			apt-get install -y $1 2>&1 || die "aborting: apt-get install failed for:$1"
			;;
		arch)
			# SC2086: $1 is an intentional space-separated list of package names
			# shellcheck disable=SC2086
			pacman -Sy --noconfirm $1 2>&1 || die "aborting: pacman install failed for:$1"
			;;
	esac
	echo "installed:$1"
}

# ---------------------------------------------------------------------------
# phase 1: supported distribution check (exit 0 silently on others)
# ---------------------------------------------------------------------------
case "$(uname -s)" in
	Linux) ;;
	*)
		echo "unsupported operating system '$(uname -s)'; this needs Linux - nothing done"
		exit 0
		;;
esac

if command_exists apt-get; then
	FAMILY=debian
elif command_exists pacman; then
	FAMILY=arch
else
	echo "unsupported distribution: no apt-get or pacman found - nothing done"
	exit 0
fi
note "package manager family: $FAMILY"

# ---------------------------------------------------------------------------
# phase 2: root requirement (after family check so we exit 0 on others)
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must be run as root (use sudo)"

# ---------------------------------------------------------------------------
# phase 3: ensure required tooling is present
# ---------------------------------------------------------------------------
need=""
for tool in plymouth plymouthd plymouth-set-default-theme; do
	if ! command_exists "$tool"; then
		case " $need " in
			*" plymouth "*) ;;
			*) need="$need plymouth" ;;
		esac
	fi
done

case "$FAMILY" in
	debian)
		command_exists update-initramfs || need="$need initramfs-tools"
		theme_pkg="plymouth-themes"
		;;
	arch)
		command_exists mkinitcpio || need="$need mkinitcpio"
		# Arch's plymouth package ships the spinner theme itself
		theme_pkg="plymouth"
		;;
esac

if [ -z "$need" ]; then
	if [ ! -f /usr/share/plymouth/themes/spinner/spinner.plymouth ]; then
		need="$theme_pkg"
	fi
fi

if [ -n "$need" ]; then
	install_pkgs "$need"

	for tool in plymouth plymouthd plymouth-set-default-theme; do
		command_exists "$tool" || die "aborting: $tool still missing after install"
	done
	case "$FAMILY" in
		debian)
			command_exists update-initramfs || die "aborting: update-initramfs still missing after install"
			;;
		arch)
			command_exists mkinitcpio || die "aborting: mkinitcpio still missing after install"
			;;
	esac
fi

# ---------------------------------------------------------------------------
# phase 4: plymouth plugin and renderer paths
# ---------------------------------------------------------------------------
plugin_dir="$(plymouth --get-splash-plugin-path 2>/dev/null || true)"
[ -n "$plugin_dir" ] || die "aborting: could not determine the plymouth plugin path"
plugin_dir="${plugin_dir%/}"

theme_file="/usr/share/plymouth/themes/spinner/spinner.plymouth"
if [ ! -f "$theme_file" ]; then
	# Theme was not installed (or was removed); (re)install the package that
	# provides it so the spinner theme is guaranteed to exist.
	install_pkgs "$theme_pkg"
fi
[ -f "$theme_file" ] || \
	die "aborting: spinner theme still missing at $theme_file after installing $theme_pkg"

spinner_module="$(sed -n 's/^ModuleName[[:space:]]*=[[:space:]]*//p' "$theme_file" \
	2>/dev/null | head -n1 | tr -d '\r')"
[ -n "$spinner_module" ] || die "aborting: spinner theme declares no ModuleName"
if [ ! -f "${plugin_dir}/${spinner_module}.so" ]; then
	# Plugin module is part of the plymouth package itself; reinstall it.
	install_pkgs "plymouth"
fi
[ -f "${plugin_dir}/${spinner_module}.so" ] || \
	die "aborting: spinner module '${plugin_dir}/${spinner_module}.so' is missing after installing plymouth"

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
# phase 6: detect the boot command line source of THIS system
# ---------------------------------------------------------------------------
BOOT_TYPE=""
BOOT_FILE=""

grub_default=/etc/default/grub
GRUB_REGEN=""
if command_exists update-grub; then
	GRUB_REGEN=update-grub
elif command_exists grub-mkconfig; then
	GRUB_REGEN=grub-mkconfig
fi

if [ -n "$GRUB_REGEN" ] && { [ -f "$grub_default" ] || [ -f /boot/grub/grub.cfg ]; }; then
	BOOT_TYPE="grub"
	BOOT_FILE="$grub_default"
elif [ -f /boot/extlinux/extlinux.conf ]; then
	BOOT_TYPE="extlinux"
	BOOT_FILE=/boot/extlinux/extlinux.conf
else
	for cand in /boot/firmware/cmdline.txt \
	            /boot/broadcom/cmdline.txt \
	            /boot/cmdline.txt; do
		if [ -f "$cand" ]; then
			BOOT_TYPE="cmdline"
			BOOT_FILE="$cand"
			break
		fi
	done
fi

[ -n "$BOOT_TYPE" ] || \
	die "aborting: no supported boot command line source found (GRUB, extlinux or cmdline.txt)"

note "boot config: $BOOT_TYPE ($BOOT_FILE)"

# ---------------------------------------------------------------------------
# phase 7: writability of the boot configuration file
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = 0 ]; then
	if [ "$BOOT_TYPE" = grub ] && [ ! -e "$BOOT_FILE" ]; then
		# Fresh image without /etc/default/grub: seed Debian defaults so the
		# rewrite/append logic below has a real file to work on.  Seeding the
		# final "splash quiet" value makes the later sed idempotent.
		printf '%s\n' \
			'GRUB_DEFAULT=0' \
			'GRUB_TIMEOUT=5' \
			'GRUB_CMDLINE_LINUX_DEFAULT="splash quiet"' \
			'GRUB_CMDLINE_LINUX=""' > "$grub_default"
		echo "created $grub_default with Debian defaults"
	elif ! touch "$BOOT_FILE" 2>/dev/null; then
		die "aborting: '$BOOT_FILE' is not writable"
	fi
else
	[ -w "$BOOT_FILE" ] || warn "boot config '$BOOT_FILE' not writable (not tested in dry run)"
fi

[ "$DRY_RUN" = 1 ] && { echo "check ok: system is ready; nothing changed (dry run)."; exit 0; }

# ---------------------------------------------------------------------------
# action 1: default theme
# ---------------------------------------------------------------------------
plymouth-set-default-theme spinner
echo "set default plymouth theme to spinner"

# ---------------------------------------------------------------------------
# action 2: make sure the kernel command line carries "quiet splash"
#           (and drop serial consoles, which force plymouth into text mode)
# ---------------------------------------------------------------------------
rewrite_tokens()
{
	# $1 = space separated token list, $2 = "force_vt" (yes/no)
	# returns the normalized list on stdout
	out=""
	has_console=no
	has_quiet=no
	has_splash=no

	for arg in $1; do
		case "$arg" in
			'console=ttyAMA'*|'console=serial'*|'console=ttyS'*)
				continue
				;;
			'console=tty1'|'console=tty0')
				has_console=yes
				out="$out $arg"
				;;
			'splash')
				has_splash=yes
				out="$out $arg"
				;;
			'quiet')
				has_quiet=yes
				out="$out $arg"
				;;
			'')
				;;
			*)
				out="$out $arg"
				;;
		esac
	done

	if [ "$2" = yes ] && [ "$has_console" = no ]; then
		out="$out console=tty1"
	fi
	[ "$has_splash" = yes ] || out="$out splash"
	[ "$has_quiet" = yes ] || out="$out quiet"

	printf '%s\n' "$out" | sed -e 's/^[[:space:]]*//;s/  */ /g'
}

backup="${BOOT_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$BOOT_FILE" "$backup"
echo "backed up $BOOT_FILE to: $backup"

case "$BOOT_TYPE" in
	grub)
		# Only ensure "quiet splash" in the default cmdline; do not force
		# console=tty1 here (GRUB systems handle consoles via their own config).
		cur="$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$grub_default" | tail -n1)"
		new="$(rewrite_tokens "$cur" no)"
		if [ -n "$cur" ]; then
			sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"$new\"/" "$grub_default"
		else
			printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="splash quiet"' >> "$grub_default"
		fi
		echo "updated GRUB_CMDLINE_LINUX_DEFAULT: $new"
		case "$GRUB_REGEN" in
			update-grub)
				update-grub || warn "update-grub failed; reboot may not pick up the new command line"
				;;
			grub-mkconfig)
				grub-mkconfig -o /boot/grub/grub.cfg || \
					warn "grub-mkconfig failed; reboot may not pick up the new command line"
				;;
		esac
		;;

	extlinux)
		if grep -q 'APPEND' "$BOOT_FILE"; then
			sed -i 's/^\([[:space:]]*APPEND[[:space:]].*\)$/\1 quiet splash/' "$BOOT_FILE"
		else
			warn "no APPEND line in $BOOT_FILE; add 'quiet splash' manually"
		fi
		echo "updated $BOOT_FILE (APPEND += quiet splash)"
		;;

	cmdline)
		line="$(sed -n '1p' "$BOOT_FILE" 2>/dev/null | tr -d '\r')"
		new="$(rewrite_tokens "$line" yes)"
		printf '%s\n' "$new" > "${BOOT_FILE}.new"
		mv "${BOOT_FILE}.new" "$BOOT_FILE"
		sync
		echo "updated kernel command line:"
		echo "  $new"
		;;
esac

# ---------------------------------------------------------------------------
# action 3: rebuild initramfs
# ---------------------------------------------------------------------------
case "$FAMILY" in
	debian)
		if update-initramfs -u -k all 2>&1; then
			:
		else
			warn "update-initramfs (-k all) failed; retrying with the running kernel only"
			update-initramfs -u 2>/dev/null || \
				die "aborting: initramfs could not be rebuilt; restore '$backup' and review modules"
		fi
		;;
	arch)
		# Arch's mkinitcpio does not auto-add plymouth; it needs a hook entry.
		if [ -f /etc/mkinitcpio.conf ]; then
			if grep -q '^HOOKS=' /etc/mkinitcpio.conf && ! grep -q '\bplymouth\b' /etc/mkinitcpio.conf; then
				cp -p /etc/mkinitcpio.conf "/etc/mkinitcpio.conf.bak-$(date +%Y%m%d-%H%M%S)"
				sed -i 's/^HOOKS=(\(.*\))/HOOKS=(plymouth \1)/' /etc/mkinitcpio.conf
				echo "added 'plymouth' to HOOKS in /etc/mkinitcpio.conf"
			fi
		else
			warn "/etc/mkinitcpio.conf not found; add the 'plymouth' hook manually"
		fi
		if mkinitcpio -P 2>&1; then
			:
		else
			warn "mkinitcpio -P failed; retrying with the default 'linux' preset only"
			mkinitcpio -p linux 2>/dev/null || \
				die "aborting: initramfs could not be rebuilt; restore '$backup' and review modules"
		fi
		;;
esac

echo
echo "done. reboot to see the spinner; to revert, restore '$backup'."