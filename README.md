# pfSense Scripts

A small collection of helper scripts for pfSense system administration.

## Included Scripts

### pfDiskReplacement.sh
Assists with replacing disks in a ZFS pool on a pfSense system.

Usage:
```
/path/to/pfDiskReplacement.sh [-h] [-t disk] [-r disk] [-n disk]
```

---

## License

This project is licensed under the BSD 3-Clause License.
See LICENSE for details.

---

## Third Party Scripts (covered by their own licenses)

### pkg_check.php
Utility script that checks for updates to the pfSense base system and
installed packages, then sends notifications through configured channels.

Based on the script originally shared at:
[Netgate Forum - Auto update check](https://forum.netgate.com/topic/137707/auto-update-check-checks-for-updates-to-base-system-packages-and-sends-email-alerts)

Usage (via cron):
```
/usr/bin/nice -n20 /usr/local/bin/php -q /root/pkg_check.php
```

This can also be scheduled via cron for automation.
