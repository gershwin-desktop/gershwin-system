#!/bin/sh

. /System/Library/Makefiles/GNUstep.sh

# Launch window manager if it is available.
if which uroswm >/dev/null 2>&1; then
  (uroswm &)
fi

sleep 2 &&

# Launch Menu and a D-Bus session if none is already there.
# Only do this if Menu is on the $PATH; otherwise we don't require D-Bus.
# NOTE: On some systems, a D-Bus session may already have been started by other parts
# of the distribution by the time this script is running.
if which Menu >/dev/null 2>&1; then
  if [ -n "$DBUS_SESSION_BUS_ADDRESS" ] ; then
    export $(dbus-launch)
  fi
  Menu &
fi

sleep 2 &&

exec GWorkspace
