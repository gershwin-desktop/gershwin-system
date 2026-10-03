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
# The subshell is a foreground command, so this shell waits for it and reaps
# it, while devmon itself is reparented to init when that subshell exits. A
# trailing "&" here would make the subshell a child of the long-lived process
# this script becomes (see the note on gershwin-apply-settings below), and a
# child nobody waits for stays a zombie for the whole login.
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
  # Make GTK 2/3 and Qt 5/6 applications show their menus in Menu, through the
  # modules that are installed together with Menu (Menu/ToolkitModules).
  export GTK_PATH=/System/Library/Libraries/appmenu-do${GTK_PATH:+:$GTK_PATH}
  export GTK_MODULES=gtk-appmenu-do
  export QT_PLUGIN_PATH=/System/Library/Libraries/appmenu-do${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}
  export QT_QPA_PLATFORMTHEME=gad
fi

if [ -e /System/Library/Tools/SudoAskPass ] ; then
  export SUDO_ASKPASS=/System/Library/Tools/SudoAskPass
fi

# The preference panes apply a change live and save it to the user's
# defaults, but keyboard layout, pointer settings, screen blanking, backlight,
# CPU governor and display profiles are reset by a restart of the machine or
# the X server. Put the saved ones back now that the X server and the
# defaults are available; none of them needs the WindowManager, so the
# desktop is not held up while it runs. Its report goes to the session log.
#
# It runs inside a subshell that starts it in the background and returns at
# once: this script then execs into gershwin-session, which inherits every
# child it had left, and a supervisor that never waits for a child leaves its
# corpse behind as a zombie for the rest of the login. The subshell is waited
# for here (it is a foreground command), and the applier itself is reparented
# to init when that subshell exits, so init reaps it instead. A plain
# "gershwin-apply-settings &" is what produced the permanent zombie.
if which gershwin-apply-settings >/dev/null 2>&1; then
  ( gershwin-apply-settings & )
fi

# Supervise the desktop apps: gershwin-session (the session supervisor)
# restarts any of them that exits and shuts them all down when this session
# ends. The app names are passed as arguments so the desktop composition
# stays configurable per flavor.
#
# Disabling the auto restart (for example while debugging a crash, so the
# supervisor does not immediately relaunch the crashed app and wipe the
# crash site):
#   kill -USR1 "$(pgrep -x gershwin-session)"      # disable auto restart
#   kill -USR2 "$(pgrep -x gershwin-session)"      # re-enable auto restart
# gershwin-session also exports its own pid in $GERSHWIN_SESSION_PID, so from
# inside a supervised app the equivalent is: kill -USR1 "$GERSHWIN_SESSION_PID".
# While auto restart is disabled, an app that exits is simply left down, so a
# developer can keep a broken instance stopped for inspection instead of it
# being respawned every quarter second.
#
# gs-crashd is the CrashReporter daemon: it watches for application crashes
# (cores in its inbox and in-process markers) and records analyzed reports.
# Running it under gershwin-session keeps it alive for the whole user session
# and auto-restarts it if it ever exits unexpectedly.
#
# Only names that resolve to something on the $PATH are handed to the
# supervisor. gershwin-session relaunches an app as soon as it exits, so
# supervising a name that is not installed means /usr/bin/env is forked
# several times a second for the whole session: it fails instantly, so every
# attempt leaves a zombie child behind and the supervisor burns CPU forever
# trying to start a program that is not there. A flavor that does not ship
# gs-crashd is the usual reason for such a name to be missing.
GERSHWIN_SESSION_APPS=
for app in Workspace Menu WindowManager gs-crashd; do
  if which "$app" >/dev/null 2>&1; then
    GERSHWIN_SESSION_APPS="$GERSHWIN_SESSION_APPS $app"
  else
    echo "Gershwin.sh: $app is not installed; not supervising it." >&2
  fi
done

# shellcheck disable=SC2086 # deliberate word splitting into a list of names
exec gershwin-session $GERSHWIN_SESSION_APPS
