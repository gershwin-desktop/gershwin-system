#!/bin/sh

. /System/Library/Makefiles/GNUstep.sh

# Add our fonts path to fontconfig
export FONTCONFIG_PATH=/System/Library/Preferences
export FONTCONFIG_FILE=$FONTCONFIG_PATH/fonts.conf

exec LoginWindow
