#!/bin/bash

# References:
# https://redmine.pfsense.org/issues/15081
# https://redmine.pfsense.org/issues/15083
# https://redmine.pfsense.org/issues/15084
# https://www.yourwarrantyisvoid.com/2023/05/04/pfsense-replacing-a-failed-zfs-disk/
# https://wiki.joeplaa.com/en/zfs

pfNewDisk="ada0"
pfGoodDisk="ada1"
pfBadDisk="ada3"

pfBootCode="$(grep "gpart bootcode" /var/log/bsdinstall_log)"

pfZfsPartNum="$(gpart show ${pfGoodDisk} | grep 'zfs' | cut -wf 4)"
pfBootPartNum="$(gpart show ${pfGoodDisk} | grep 'boot' | cut -wf 4)"
pfSwapPartNum="$(gpart show ${pfGoodDisk} | grep 'swap' | cut -wf 4)"
pfEfiPartNum="$(gpart show ${pfGoodDisk} | grep 'efi' | cut -wf 4)"

# pfOldDiskNum="$(echo "${pfGoodDisk}" | sed -e 's:ada::' -e 's:da::' -e 's:nvd::')"
pfNewDiskNum="$(echo "${pfNewDisk}" | sed -e 's:ada::' -e 's:da::' -e 's:nvd::')"
pfZpoolName="$(zpool list -H -o name)"

# show vital stats
zpool status
gpart show -l ${pfGoodDisk}
echo "${pfBootCode}"

# Get the bootcode command
pfBootCodeCmd="$(echo "${pfBootCode}" | grep "${pfGoodDisk}" | sed -e 's|DEBUG: zfs_create_diskpart: ||' -e 's:":'\'':g' -e "s:${pfGoodDisk}:${pfNewDisk}:")"

# Copy the partion layout to the new disk
gpart backup ${pfGoodDisk} | gpart restore -F ${pfNewDisk}

# Fix layout
if [ ! -z "${pfEfiPartNum}" ]; then
	gpart modify -i "${pfEfiPartNum}" -l "efiboot${pfNewDiskNum}"
fi
gpart modify -i "${pfBootPartNum}" -l "gptboot${pfNewDiskNum}"
if [ ! -z "${pfSwapPartNum}" ]; then
	gpart modify -i "${pfSwapPartNum}" -l "swap${pfNewDiskNum}"
fi
gpart modify -i "${pfZfsPartNum}" -l "zfs${pfNewDiskNum}"

# setup boot code
if [ ! -z "${pfEfiPartNum}" ]; then
	newfs_msdos -F 32 -c 1 -L "EFISYS${pfNewDiskNum}"  "/dev/gpt/efiboot${pfNewDiskNum}"
	mount -t msdosfs "/dev/gpt/efiboot${pfNewDiskNum}" /mnt/
	cp -Rp /boot/efi/ /mnt
	umount /mnt
fi
${pfBootCodeCmd}

# resliver zfs
zpool replace "${pfZpoolName}" "${pfBadDisk}p${pfZfsPartNum}" "${pfNewDisk}p${pfZfsPartNum}"
