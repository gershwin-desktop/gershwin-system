#!/bin/sh

# If $SHELL is /bin/sh or unset, then set bash if possible
[ "${SHELL:-/bin/sh}" != /bin/sh ] || {
  for b in /usr/local/bin/bash /usr/bin/bash /bin/bash /bin/sh; do
    [ -x "$b" ] && { export SHELL="$b"; break; }
  done
}

GERSHWIN_LOG_FILE=/tmp/Gershwin.log
GERSHWIN_LOGGING=0

if : >>"$GERSHWIN_LOG_FILE" 2>/dev/null; then
  chmod 600 "$GERSHWIN_LOG_FILE" 2>/dev/null || :
  exec >>"$GERSHWIN_LOG_FILE" 2>&1
  GERSHWIN_LOGGING=1
fi

log() {
  if [ "$GERSHWIN_LOGGING" = "1" ]; then
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
  fi
}

wait_for_x_root_property() {
  property=$1
  label=$2
  timeout=$3

  if ! command -v xprop >/dev/null 2>&1; then
    log "xprop not found; cannot wait for $label"
    return 1
  fi

  i=0
  while [ "$i" -lt "$timeout" ]; do
    value=$(xprop -root "$property" 2>/dev/null || :)
    case "$value" in
      ""|*"not found"*)
        ;;
      *)
        log "$label ready: $property is present"
        return 0
        ;;
    esac
    sleep 1
    i=$((i + 1))
  done

  log "Timed out waiting for $label: $property was not present after ${timeout}s"
  return 1
}

log "Starting Gershwin session script"

if [ -r /System/Library/Makefiles/GNUstep.sh ]; then
  log "Loading GNUstep environment"
  . /System/Library/Makefiles/GNUstep.sh
else
  log "GNUstep environment not readable at /System/Library/Makefiles/GNUstep.sh; aborting"
  exit 1
fi

export DISPLAY=:0
log "DISPLAY set to $DISPLAY"

export PATH=$HOME/Library/Tools:/Local/Library/Tools:/System/Library/Tools/:$PATH

# Add our fonts path to fontconfig
export FONTCONFIG_PATH=/System/Library/Preferences
export FONTCONFIG_FILE=$FONTCONFIG_PATH/fonts.conf

# Indicate Gershwin Desktop to tools like Fastfetch
export XDG_CURRENT_DESKTOP="Gershwin"

# Allow users to access CUPS at http://localhost:631/admin/; TODO: Move in a suitable place
# Cannot run it like this here because e.g., on stock FreeBSD there is no sudo
# sudo usermod -aG lpadmin $USER

# Launch window manager if it is available.
if command -v WindowManager >/dev/null 2>&1; then
  log "Starting WindowManager"
  (WindowManager &)
else
  log "WindowManager not found; skipping"
fi

# Launch devmon automounter if it is available (udevil package on Devuan).
if command -v devmon >/dev/null 2>&1; then
  log "Starting devmon"
  (devmon &)
else
  log "devmon not found; skipping"
fi

log "Waiting for WindowManager before launching Menu"
if ! wait_for_x_root_property _NET_SUPPORTING_WM_CHECK WindowManager 5; then
  log "Falling back to fixed WindowManager grace period"
  sleep 2
fi

# Launch Menu and a D-Bus session if none is already there.
# Only do this if Menu is on the $PATH; otherwise we don't require D-Bus.
# NOTE: On some systems, a D-Bus session may already have been started by other parts
# of the distribution by the time this script is running.
if command -v Menu >/dev/null 2>&1; then
  if [ -z "$DBUS_SESSION_BUS_ADDRESS" ] ; then
    if command -v dbus-launch >/dev/null 2>&1; then
      log "No D-Bus session found; starting one with dbus-launch"
      DBUS_LAUNCH_OUTPUT=$(dbus-launch --sh-syntax)
      DBUS_LAUNCH_STATUS=$?
      if [ "$DBUS_LAUNCH_STATUS" -eq 0 ] && [ -n "$DBUS_LAUNCH_OUTPUT" ]; then
        if eval "$DBUS_LAUNCH_OUTPUT"; then
          export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
          log "D-Bus session started"
        else
          log "dbus-launch output could not be evaluated"
        fi
      else
        log "dbus-launch failed with status $DBUS_LAUNCH_STATUS"
      fi
      if [ -n "$DBUS_SESSION_BUS_ADDRESS" ]; then
        export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
      fi
    else
      log "dbus-launch not found; Menu may start without D-Bus"
    fi
  else
    log "Using existing D-Bus session"
  fi
  # Make GTK applications use Menu; this requires e.g., on Debian:
  # sudo apt-get -y install appmenu-gtk2-module appmenu-gtk3-module
  export GTK_MODULES=appmenu-gtk-module
  log "GTK_MODULES set to $GTK_MODULES"
  Menu &
  log "Started Menu with PID $!"
else
  log "Menu not found; skipping D-Bus launch and Menu startup"
fi

if [ -e /System/Library/Tools/SudoAskPass ] ; then
  export SUDO_ASKPASS=/System/Library/Tools/SudoAskPass
  log "SUDO_ASKPASS set to $SUDO_ASKPASS"
fi

log "Waiting for Menu before launching Workspace"
if command -v Menu >/dev/null 2>&1; then
  if ! wait_for_x_root_property _KDE_GLOBAL_MENU_AVAILABLE Menu 10; then
    log "Falling back to fixed Menu grace period"
    sleep 3
  fi
else
  sleep 2
fi

log "Starting Workspace"
exec Workspace
WORKSPACE_STATUS=$?
log "Workspace exec failed with status $WORKSPACE_STATUS"
exit "$WORKSPACE_STATUS"
