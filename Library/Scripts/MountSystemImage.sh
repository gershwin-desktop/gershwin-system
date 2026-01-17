#!/bin/sh

# Squashfs Mounting Script for FreeBSD
# Mounts the most recent squashfs file to /System

# TODO: Also handle Linux which can mount squashfs natively
# TODO: Use uzip for FreeBSD to remove need for FUSE

# Exit immediately if a command fails
set -e

# Ensure script is run with root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use sudo."
    exit 1
fi

# Package and module names
SQUASHFUSE_PKG="fusefs-squashfuse"
FUSE_MODULE="fusefs"
MOUNT_POINT="/System"

# Search paths for squashfs files
SEARCH_PATHS=". / /System"

# Function to install package if not present
install_package() {
    if ! pkg info "$1" > /dev/null 2>&1; then
        echo "Installing $1..."
        pkg install -y "$1"
    fi
}

# Function to load kernel module
load_kernel_module() {
    if ! kldstat -m "$1" > /dev/null 2>&1; then
        echo "Loading $1 kernel module..."
        kldload "$1"
        
        # Make module loading persistent
        if ! grep -q "${1}_load=\"YES\"" /boot/loader.conf; then
            echo "${1}_load=\"YES\"" >> /boot/loader.conf
        fi
    fi
}

# Function to prepare FUSE device
prepare_fuse_device() {
    # Ensure FUSE device exists with correct permissions
    if [ ! -c /dev/fuse ]; then
        mkdir -p /dev/fuse
        mknod /dev/fuse c 255 0
    fi
    chmod 666 /dev/fuse
}

# Function to get the most recent squashfs file
get_most_recent_squashfs() {
    local path
    for path in $SEARCH_PATHS; do
        # Find squashfs files in the current path, sort by modification time
        find "$path" -maxdepth 1 -type f -name "*.squashfs" -print0 | xargs -0 ls -t 2>/dev/null | head -n1
    done | head -n1
}

# Function to unmount existing mounts in /System
unmount_existing() {
    # Attempt to unmount any existing mounts in /System
    if mount | grep -q " on $MOUNT_POINT "; then
        echo "Unmounting existing mounts in $MOUNT_POINT..."
        umount "$MOUNT_POINT" || true
    fi
}

# Main script execution
main() {
    # Install required package
    install_package "$SQUASHFUSE_PKG"

    # Load FUSE kernel module
    load_kernel_module "$FUSE_MODULE"

    # Prepare FUSE device
    prepare_fuse_device

    # Get the most recent squashfs file
    local squashfs_file
    squashfs_file=$(get_most_recent_squashfs)

    if [ -z "$squashfs_file" ]; then
        echo "No squashfs files found in search paths."
        exit 1
    fi

    # Ensure /System exists
    mkdir -p "$MOUNT_POINT"

    # Unmount any existing mounts
    unmount_existing

    # Mount the squashfs directly to /System
    echo "Mounting $squashfs_file to $MOUNT_POINT..."
    squashfuse -o allow_other "$squashfs_file" "$MOUNT_POINT"

    # Robust mount verification
    if [ $? -eq 0 ]; then
        # Check if mount point is not empty and contains files
        if [ "$(ls -A "$MOUNT_POINT")" ]; then
            echo "Successfully mounted $squashfs_file to $MOUNT_POINT"
            # List contents to verify
            ls -la "$MOUNT_POINT"
            exit 0
        else
            echo "Mount appears to be empty"
            exit 1
        fi
    else
        echo "Mount command failed"
        exit 1
    fi
}

# Call main function
main

