#!/bin/sh

/System/Library/Scripts/MountSystemImage.sh

. /System/Library/Makefiles/GNUstep.sh

# Allow non-root users to power off, halt, and reboot the system
for bin in /sbin/poweroff /sbin/halt /sbin/reboot; do [ -e "$bin" ] && chmod 5755 "$bin"; done

# Add our fonts path to fontconfig
export FONTCONFIG_PATH=/System/Library/Preferences
export FONTCONFIG_FILE=$FONTCONFIG_PATH/fonts.conf

exec LoginWindow
