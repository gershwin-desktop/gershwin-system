#!/bin/sh

# Visual Studio Code installation script for Gershwin on FreeBSD systems.
# This script installs the Linux version of Visual Studio Code, which is officially supported by the vendor.
# Run this script as root.
# TODO: Extend functionality as needed and handle other operating systems.

# Ensure script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Verify we're on FreeBSD or a FreeBSD variant
if ! uname -s | grep -qE "FreeBSD|GhostBSD"; then
    echo "Error: This script is only for FreeBSD or FreeBSD variants" >&2
    exit 1
fi

kldload /boot/kernel/linux* 2>/dev/null
pkg install -y chromium linux-rl9-gtk3  linux-rl9-alsa-lib  # TODO: Bundle the needed subset as an AppImage

service linux enable
service linux start

wget "https://code.visualstudio.com/sha/download?build=stable&os=linux-x64" --trust-server-names

 tar xf code-stable-*.tar.gz

./VSCode-linux-x64/code --no-sandbox