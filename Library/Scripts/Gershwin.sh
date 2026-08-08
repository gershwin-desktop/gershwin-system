#!/bin/sh

# If $SHELL is /bin/sh or unset, then set bash if possible
[ "${SHELL:-/bin/sh}" != /bin/sh ] || {
  for b in /usr/local/bin/bash /usr/bin/bash /bin/bash /bin/sh; do
    [ -x "$b" ] && { export SHELL="$b"; break; }
  done
}

. /System/Library/Makefiles/GNUstep.sh

export DISPLAY=:0

export PATH=$HOME/Library/Tools:/Local/Library/Tools:/System/Library/Tools/:$PATH

# Add our fonts path to fontconfig
export FONTCONFIG_PATH=/System/Library/Preferences
export FONTCONFIG_FILE=$FONTCONFIG_PATH/fonts.conf

# Indicate Gershwin Desktop to tools like Fastfetch
export XDG_CURRENT_DESKTOP="Gershwin"

# Allow users to access CUPS at http://localhost:631/admin/; TODO: Move in a suitable place
# Cannot run it like this here because e.g., on stock FreeBSD there is no sudo
# sudo usermod -aG lpadmin $USER

# Launch devmon automounter if it is available (udevil package on Devuan).
if which devmon >/dev/null 2>&1; then
  (devmon &)
fi

# D-Bus is required by Menu; only set up a session bus if none is there and
# Menu is on the $PATH.  gershwin-session inherits this environment for all
# supervised apps.
if which Menu >/dev/null 2>&1; then
  if [ -z "$DBUS_SESSION_BUS_ADDRESS" ] ; then
    export $(dbus-launch)
  fi
  # Make GTK applications use Menu; this requires e.g., on Debian:
  # sudo apt-get -y install appmenu-gtk2-module appmenu-gtk3-module
  export GTK_MODULES=appmenu-gtk-module
fi

if [ -e /System/Library/Tools/SudoAskPass ] ; then
  export SUDO_ASKPASS=/System/Library/Tools/SudoAskPass
fi

# Supervise the desktop apps: gershwin-session (the session supervisor)
# restarts any of them that exits and shuts them all down when this session
# ends. The app names are passed as arguments so the desktop composition
# stays configurable per flavor. For development, send SIGUSR1/SIGUSR2 to
# the gershwin-session process to disable or re-enable the auto restart.
exec gershwin-session Workspace Menu WindowManager
