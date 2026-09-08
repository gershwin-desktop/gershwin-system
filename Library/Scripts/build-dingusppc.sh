#!/bin/sh
# Build dingusppc with SDL2 video and whichever audio backend is available
# (ALSA on Linux, sndio/OSS on the BSDs), fetch a Power Mac G3 Beige ROM and a
# bootable Mac OS 9.2.2 CD image from archive.org, then boot the emulator.
# POSIX sh only; needs curl, wget, git, cmake, make, unzip and a C++20
# toolchain (g++ / clang++).
#
# Override with environment variables:
#   WORKDIR     where ROM/ISO/disk live            (default: $PWD/dingusppc-media)
#   SRC         dingusppc source checkout          (default: dir of this script)
#   BUILD       build dir                          (default: $SRC/build)
#   REPO        clone URL for the emulator source  (default: dingusdev upstream)
#   RAM         emulated RAM in MB (Beige G3 max 768) (default: 256)
#   HDD_SIZE    create a blank hard disk of this many MB (0 = none) (default: 0)
#   ROM_SOURCE  download from archive.org zip or im (infinite-mac raw) (default: archive)
#   MACHINE     machine ID override (default: autodetect from ROM = pmg3dt)

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

WORKDIR="${WORKDIR:-$(pwd)/dingusppc-media}"
SRC="${SRC:-$SCRIPT_DIR}"
BUILD="${BUILD:-$SRC/build}"
REPO="${REPO:-https://github.com/dingusdev/dingusppc.git}"
RAM="${RAM:-256}"
HDD_SIZE="${HDD_SIZE:-0}"
ROM_SOURCE="${ROM_SOURCE:-archive}"
MACHINE="${MACHINE:-}"

# Power Mac G3 (v3) ROM, checksum 0x78F57389. Same bytes (md5 below) are
# served by infinite-mac from git and by the mac_rom_archive zip on archive.org.
ROM_ZIP_URL="https://archive.org/download/mac_rom_archive_-_as_of_8-19-2011/mac_rom_archive_-_as_of_8-19-2011.zip"
ROM_IN_ZIP="78F57389 - Power Mac G3 (v3).ROM"
ROM_IM_URL="https://raw.githubusercontent.com/mihaip/infinite-mac/main/src/Data/Power-Macintosh-G3.rom"
ROM_MD5="616d792ee6e2877c5c8faf30b6c56fe8"

# Mac OS 9.2.2 install CD (bootable, works on the Beige G3 under dingusppc).
ISO_URL="https://archive.org/download/apple-mac-os-9.2.2/Apple%20MacOS%209.2.2.iso"
ISO_SHA1="52dcec74c8e967b72cd4e491e0a7019f2bf1ca9f"

# --- helpers -------------------------------------------------------------------
say() { printf '%s\n' "$*"; }
die() { say "error: $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

need() { # need <cmd> ...
    for c in "$@"; do
        have "$c" || die "required tool not found: $c"
    done
}

# number of parallel build jobs (1 if unknown)
njobs() {
    if [ -n "${JOBS:-}" ]; then
        printf '%s\n' "$JOBS"
    elif have sysctl; then
        sysctl -n hw.ncpu 2>/dev/null || printf '2\n'
    elif have getconf; then
        getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2\n'
    else
        printf '2\n'
    fi
}

dl() { # dl <dest> <url>
    dest=$1
    url=$2
    if have curl; then
        curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
    elif have wget; then
        wget -q --retry-connrefused -O "$dest" "$url"
    else
        return 1
    fi
}

# run a command as root (stay root, else sudo; doas is used on OpenBSD)
asroot() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif have sudo; then
        sudo "$@"
    elif have doas; then
        doas "$@"
    else
        die "need root to install packages (no sudo or doas found)"
    fi
}

# portable md5/sha1: print the hex digest of a file, or empty if unavailable
md5_of() {
    if have md5sum; then
        md5sum "$1" 2>/dev/null | cut -d' ' -f1
    elif have md5; then
        md5 -q "$1" 2>/dev/null
    else
        printf '\n'
    fi
}
sha1_of() {
    if have sha1sum; then
        sha1sum "$1" 2>/dev/null | cut -d' ' -f1
    elif have sha1; then
        sha1 -q "$1" 2>/dev/null
    else
        printf '\n'
    fi
}

# --- install build dependencies ---------------------------------------------------
install_deps() {
    case "$(uname -s)" in
        Linux)
            if have apt-get; then
                asroot apt-get update -q || true
                asroot apt-get install -y \
                    build-essential cmake make git pkg-config ca-certificates \
                    unzip curl wget libsdl2-dev libasound2-dev
            elif have dnf; then
                asroot dnf install -y cmake make gcc-c++ git pkgconf unzip \
                    curl wget SDL2-devel alsa-lib-devel
            elif have pacman; then
                asroot pacman -Sy --noconfirm --needed cmake make gcc pkg-config \
                    git unzip curl wget sdl2 alsa-lib
            else
                say "note: no supported package manager found, assuming deps are installed"
            fi
            ;;
        FreeBSD|DragonFly)
            if have pkg; then
                asroot pkg update -f || true
                asroot pkg install -y cmake pkgconf git unzip curl wget sdl2
            else
                say "note: no pkg(8) found, assuming deps are installed"
            fi
            ;;
        OpenBSD)
            if have pkg_add; then
                asroot pkg_add cmake pkgconf git unzip curl wget sdl2
            else
                say "note: no pkg_add(1) found, assuming deps are installed"
            fi
            ;;
        NetBSD)
            if have pkgin; then
                asroot pkgin update || true
                asroot pkgin -y install cmake pkgconf git unzip curl wget SDL2
            else
                say "note: no pkgin found, assuming deps are installed"
            fi
            ;;
        *) die "unsupported OS: $(uname -s)" ;;
    esac
}

# --- fetch the boot ROM ----------------------------------------------------------
get_rom() {
    if [ -f "$WORKDIR/bootrom.bin" ]; then
        say "using existing $WORKDIR/bootrom.bin"
        return 0
    fi
    case "$ROM_SOURCE" in
        im)
            say "downloading ROM from infinite-mac..."
            dl "$WORKDIR/bootrom.bin" "$ROM_IM_URL" || die "ROM download failed"
            ;;
        archive)
            need unzip
            say "downloading ROM archive from archive.org..."
            dl "$WORKDIR/roms.zip" "$ROM_ZIP_URL" || die "ROM zip download failed"
            unzip -o -p "$WORKDIR/roms.zip" "$ROM_IN_ZIP" > "$WORKDIR/bootrom.bin" \
                || die "cannot extract '$ROM_IN_ZIP' from ROM archive"
            rm -f "$WORKDIR/roms.zip"
            ;;
        *) die "bad ROM_SOURCE: $ROM_SOURCE (use archive or im)" ;;
    esac
    chk=$(md5_of "$WORKDIR/bootrom.bin")
    if [ -n "$chk" ]; then
        if [ "$chk" != "$ROM_MD5" ]; then
            say "warning: bootrom md5 is $chk (expected $ROM_MD5)"
        else
            say "bootrom checksum OK"
        fi
    fi
}

# --- fetch the Mac OS 9.2.2 CD -----------------------------------------------------
get_iso() {
    if [ -f "$WORKDIR/macos922.iso" ]; then
        say "using existing $WORKDIR/macos922.iso"
        return 0
    fi
    say "downloading Mac OS 9.2.2 ISO (~725 MiB), this takes a while..."
    dl "$WORKDIR/macos922.iso" "$ISO_URL" || die "ISO download failed"
    got=$(sha1_of "$WORKDIR/macos922.iso")
    if [ -n "$got" ]; then
        if [ "$got" != "$ISO_SHA1" ]; then
            say "warning: ISO sha1 is $got (expected $ISO_SHA1)"
        else
            say "ISO checksum OK"
        fi
    fi
}

# --- blank hard disk (optional) -------------------------------------------------------
make_hdd() {
    if [ "$HDD_SIZE" -eq 0 ]; then return 0; fi
    if [ -f "$WORKDIR/macos9.dimg" ]; then return 0; fi
    say "creating blank $HDD_SIZE MB hard disk..."
    dd if=/dev/zero of="$WORKDIR/macos9.dimg" bs=1048576 count="$HDD_SIZE" 2>/dev/null \
        || die "failed to create hard disk"
}

# --- build dingusppc with SDL2 (+ best available audio backend) ---------------------
do_build() {
    if [ -x "$BUILD/bin/dingusppc" ]; then
        say "already built: $BUILD/bin/dingusppc"
        return 0
    fi
    need git cmake make
    if [ ! -d "$SRC/.git" ]; then
        git clone --recursive "$REPO" "$SRC" || die "git clone failed"
    else
        say "using existing source tree at $SRC"
    fi
    git -C "$SRC" submodule update --init --recursive || die "submodule update failed"
    # LAZY_LOAD_LIBS=OFF makes cubeb link against the audio libraries directly
    # (no dlopen), so the available backend (ALSA on Linux, sndio/OSS on the
    # BSDs) is guaranteed to be compiled in. SDL2 is found by CMake.
    cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DLAZY_LOAD_LIBS=OFF \
        || die "cmake configure failed"
    cmake --build "$BUILD" -j "$(njobs)" || die "build failed"
}

# --- main ---------------------------------------------------------------------------
mkdir -p "$WORKDIR"
install_deps
do_build
get_rom
get_iso
make_hdd

BIN="$BUILD/bin/dingusppc"
[ -x "$BIN" ] || die "emulator binary not found: $BIN"

set -- "$BIN" -b "$WORKDIR/bootrom.bin" -r --rambank1_size "$RAM"
[ -n "$MACHINE" ] && set -- "$@" -m "$MACHINE"
[ "$HDD_SIZE" -gt 0 ] && set -- "$@" --hdd_img "$WORKDIR/macos9.dimg"
set -- "$@" --cdr_img "$WORKDIR/macos922.iso"

say ""
say "Booting DingusPPC: $*"
cd "$WORKDIR"
exec "$@"
