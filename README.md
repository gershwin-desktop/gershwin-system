# Gershwin /System

This project contains files that get populated in `/System` that are not part of other Gerswhin repositories.

## Installation

See https://github.com/gershwin-desktop/gershwin-desktop/wiki

## Image based "installation"

There is an _experimental_ way to "install" Gershwin on FreeBSD by using a Gershwin filesystem image which is under 20 MB in size:

```
su
cd /
git clone https://github.com/gershwin-desktop/gershwin-system # FIXME: clone this to /System instead
curl https://github.com/gershwin-desktop/gershwin-components/blob/main/LoginWindow/loginwindow # FIXME: to /usr/local/etc/rc.d
service loginwindow enable
# Now put a Gershwin filesystem image into /System
reboot
```

To "update" Gershwin, just put a newer filesystem image there. The newest one will be picked automatically as per its filename.

