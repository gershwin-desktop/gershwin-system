#!/bin/sh

# System preparation script for Gershwin on FreeBSD systems.
# This script adds users to the video group and sets setuid on necessary binaries.
# Run this script as root.
# TODO: Extend functionality as needed and handle other operating systems.

# Verify we're on FreeBSD or a FreeBSD variant
if ! uname -s | grep -qE "FreeBSD|GhostBSD"; then
    echo "Error: This script is only for FreeBSD or FreeBSD variants" >&2
    exit 1
fi

# Function to add users to video group
# TODO: cups, dialer, webcam - if they exist
add_users_to_video_group() {
    # Find all users with UID >= 1000
    for user in $(awk -F: '$3 >= 1000 {print $1}' /etc/passwd); do
        # Add user to video group
        pw groupmod video -m "$user" 2>/dev/null && \
            echo "Added $user to video group"
    done
}

# Function to set setuid on specified binaries
set_binary_setuid() {
    binaries="/sbin/mount /sbin/umount /sbin/eject /sbin/shutdown /sbin/halt /sbin/reboot"
    for binary in $binaries; do
        if [ -x "$binary" ]; then
            chmod u+s "$binary" && \
                echo "Set setuid on $binary" || \
                echo "Failed to set setuid on $binary" >&2
        else
            echo "Binary $binary does not exist or is not executable" >&2
        fi
    done
}

# Main execution
main() {
    # Ensure script is run as root
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root" >&2
        exit 1
    fi

    # Add users to video group
    add_users_to_video_group

    # Set setuid on specified binaries
    set_binary_setuid
}

# Run the main function
main

