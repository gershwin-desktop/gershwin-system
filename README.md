# Gershwin /System

This project contains files that get populated in `/System` that are not part of other Gerswhin repositories.

## Installation

See https://github.com/gershwin-desktop/gershwin-desktop/wiki

## SystemPrepare

After installing Gershwin on FreeBSD, GhostBSD, Debian, Devuan or Raspberry Pi OS, run as root:

```sh
sh /System/Library/Scripts/SystemPrepare.sh
```

It is safe to re-run. It installs the supporting packages and enables the services the desktop needs, so that they start at the next boot (set `REBOOT=1` to reboot at the end):

| Service | FreeBSD / GhostBSD (rc.conf) | Linux with systemd | Linux with sysvinit (Devuan) |
| --- | --- | --- | --- |
| LoginWindow (graphical login) | `loginwindow` | `loginwindow` | `loginwindow` (init script, runlevel 5) |
| Directory Services (dshelper, starts gdomap) | `dshelper` | `dshelper`, `gdomap` | `dshelper` (starts gdomap) |
| D-Bus system bus | `dbus` | `dbus` | `dbus` |
| elogind (login sessions) | - | part of systemd | `elogind` |
| mDNS (avahi) | `avahi_daemon`, `avahi_dnsconfd` | `avahi-daemon` | `avahi-daemon` |
| Printing (CUPS) | `cupsd` | `cups` | `cups` |
| Time synchronization | `ntpd` | - | - |

`rpcbind` is not needed and is not enabled. OpenBSD and Arch Linux are not supported by this script yet.

## Image based "installation"

There is an _experimental_ way to "install" Gershwin on FreeBSD by using a Gershwin filesystem image which is under 20 MB in size:

```sh
#!/bin/sh
set -e
[ "$(id -u)" = 0 ] || exec su root -c "$0"
mkdir -p /System /usr/local/etc/rc.d
[ -d /System/.git ] || git clone https://github.com/gershwin-desktop/gershwin-system /System
curl -sSf https://raw.githubusercontent.com/gershwin-desktop/gershwin-components/main/LoginWindow/loginwindow > /usr/local/etc/rc.d/loginwindow
chmod 755 /usr/local/etc/rc.d/loginwindow
# Make binaries from FreeBSD 14 usable on FreeBSD 15
[ -e /lib/libutil.so.9 ] || [ ! -e /lib/libutil.so.10 ] || ln -s /lib/libutil.so.10 /lib/libutil.so.9
u="https://api.cirrus-ci.com/v1/artifact/github/gershwin-desktop/gershwin-build/data/system/artifacts/FreeBSD/14/amd64/Gershwin-OS-FreeBSD-260116163642.squashfs" # Adjust number
curl -sSf "$u" -o "/$(basename "$u")"
ls /Gershwin*.squashfs
service loginwindow onestart
```

Once everything works, `service loginwindow enable` and reboot.

To "update" Gershwin, just put a newer filesystem image there. The newest one will be picked automatically as per its filename.

