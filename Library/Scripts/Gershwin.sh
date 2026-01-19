#!/bin/sh

# Redirect stdout and stderr to a fifo on Linux,
# making them accessible from a graphical session,
# without depending on nor failing in the presence of systemd
if [ "$(uname -s)" = "Linux" ]; then
    BOOTLOG_DIR=/tmp
    BOOTLOG_FIFO=/tmp/Gershwin.log.fifo

    [ -d "$BOOTLOG_DIR" ] || mkdir -p "$BOOTLOG_DIR"
    [ -p "$BOOTLOG_FIFO" ] || { rm -f "$BOOTLOG_FIFO"; mkfifo "$BOOTLOG_FIFO"; }

    exec >"$BOOTLOG_FIFO" 2>&1
fi

. /System/Library/Makefiles/GNUstep.sh

export PATH=$HOME/Library/Tools:/Local/Library/Tools:/System/Library/Tools/:$PATH

# Add our fonts path to fontconfig
export FONTCONFIG_PATH=/System/Library/Preferences
export FONTCONFIG_FILE=$FONTCONFIG_PATH/fonts.conf

# Allow users to access CUPS at http://localhost:631/admin/; TODO: Move in a suitable place
# Cannot run it like this here because e.g., on stock FreeBSD there is no sudo
# sudo usermod -aG lpadmin $USER

# Launch window manager if it is available.
if which WindowManager >/dev/null 2>&1; then
  (WindowManager &)
fi

# Launch devmon automounter if it is available (udevil package on Devuan).
if which devmon >/dev/null 2>&1; then
  (devmon &)
fi

sleep 2 && # FIXME: Wait for WindowManager to start properly before launching Menu

# Launch Menu and a D-Bus session if none is already there.
# Only do this if Menu is on the $PATH; otherwise we don't require D-Bus.
# NOTE: On some systems, a D-Bus session may already have been started by other parts
# of the distribution by the time this script is running.
if which Menu >/dev/null 2>&1; then
  if [ -z "$DBUS_SESSION_BUS_ADDRESS" ] ; then
    export $(dbus-launch)
  fi
  # Make GTK applications use Menu; this requires e.g., on Debian:
  # sudo apt-get -y install appmenu-gtk2-module appmenu-gtk3-module
  export GTK_MODULES=appmenu-gtk-module
  Menu &
fi

if [ -e /System/Library/Tools/SudoAskPass ] ; then
  export SUDO_ASKPASS=/System/Library/Tools/SudoAskPass
fi

sleep 2 # FIXME: Wait for Menu to start properly before launching Workspace

exec Workspace
