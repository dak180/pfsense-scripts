#!/bin/bash
# shellcheck disable=SC2155

# References:
# https://redmine.pfsense.org/issues/15081
# https://redmine.pfsense.org/issues/15083
# https://redmine.pfsense.org/issues/15084
# https://www.yourwarrantyisvoid.com/2023/05/04/pfsense-replacing-a-failed-zfs-disk/
# https://wiki.joeplaa.com/en/zfs

# Vars
pfZfsPartNum="$(gpart show "${pfGoodDisk}" | grep 'zfs' | cut -wf 4)"

# Functions
function pfDrUsage() {
	tee >&2 << EOF
Usage: ${0} [-h] [-t disk] [-r disk] [-n disk]
Replace a disk in a zfs mirror on pfSense.


Options:
-h
	Display this help and exit.

-t
	The "Good" disk to use as a template.

-r
	The "Old" disk being replaced.

-n
	The "New" disk being added.


EOF

}

function pfCheckDiskSize() {
	local pfNewDiskSize="$(smartctl -xj "${pfNewDisk}" | jq -Mre '.user_capacity.bytes | values')"
	local pfOldDiskSize="$(smartctl -xj "${pfGoodDisk}" | jq -Mre '.user_capacity.bytes | values')"

	if [ ! "${pfNewDiskSize}" -ge "${pfOldDiskSize}" ]; then
		echo "${pfNewDisk} is not larger than ${pfBadDisk}."  >&2
		exit 1
	fi
}

function pfInitializeDisk () {
	# Vars
	local pfBootCode="$(grep "gpart bootcode" /var/log/bsdinstall_log)"

	local pfBootPartNum="$(gpart show "${pfGoodDisk}" | grep 'boot' | cut -wf 4)"
	local pfSwapPartNum="$(gpart show "${pfGoodDisk}" | grep 'swap' | cut -wf 4)"
	local pfEfiPartNum="$(gpart show "${pfGoodDisk}" | grep 'efi' | cut -wf 4)"

	local pfOldDiskNum="$(echo "${pfGoodDisk}" | sed -e 's:ada::' -e 's:da::' -e 's:nvd::')"
	local pfNewDiskNum="$(echo "${pfNewDisk}" | sed -e 's:ada::' -e 's:da::' -e 's:nvd::')"

	# Determine the disk number
	if [ "${pfOldDiskNum}" -ge "${pfNewDiskNum}" ]; then
		pfNewDiskNum=$(( pfOldDiskNum + 3 ))
	fi

	# Get the bootcode command
	local pfBootCodeCmd="$(echo "${pfBootCode}" | grep "${pfGoodDisk}" | sed -e 's|DEBUG: zfs_create_diskpart: ||' -e 's:":'\'':g' -e "s:${pfGoodDisk}:${pfNewDisk}:")"

	# Copy the partion layout to the new disk
	gpart backup "${pfGoodDisk}" | gpart restore -F "${pfNewDisk}" || { echo "Failed to initialize the disk." >&2; exit 1;}

	# Fix layout
	if [ ! -z "${pfEfiPartNum}" ]; then
		gpart modify -i "${pfEfiPartNum}" -l "efiboot${pfNewDiskNum}" || { echo "Failed to initialize the disk." >&2; exit 1;}
	fi
	gpart modify -i "${pfBootPartNum}" -l "gptboot${pfNewDiskNum}"
	if [ ! -z "${pfSwapPartNum}" ]; then
		gpart modify -i "${pfSwapPartNum}" -l "swap${pfNewDiskNum}" || { echo "Failed to initialize the disk." >&2; exit 1;}
	fi
	gpart modify -i "${pfZfsPartNum}" -l "zfs${pfNewDiskNum}" || { echo "Failed to initialize the disk." >&2; exit 1;}

	# Setup the boot code
	if [ ! -z "${pfEfiPartNum}" ]; then
		newfs_msdos -F 32 -c 1 -L "EFISYS${pfNewDiskNum}"  "/dev/gpt/efiboot${pfNewDiskNum}" || { echo "Failed to set the boot code." >&2; exit 1;}
		mount -t msdosfs "/dev/gpt/efiboot${pfNewDiskNum}" /mnt/ || { echo "Failed to set the boot code." >&2; exit 1;}
		cp -Rp /boot/efi/ /mnt || { echo "Failed to set the boot code." >&2; exit 1;}
		umount /mnt || { echo "Failed to set the boot code." >&2; exit 1;}
	fi

	${pfBootCodeCmd} || { echo "Failed to set the boot code." >&2; exit 1;}
}

function pfZfsReplace() {
	local pfZpoolName="$(zpool list -H -o name)"

	zpool replace "${pfZpoolName}" "${pfBadDisk}p${pfZfsPartNum}" "${pfNewDisk}p${pfZfsPartNum}" || { echo "Failed to replace the disk." >&2; exit 1;}
}


while getopts ":t:r:n:h" OPTION; do
	case "${OPTION}" in
		t)
			pfGoodDisk="${OPTARG}"
		;;
		r)
			pfBadDisk="${OPTARG}"
		;;
		n)
			pfNewDisk="${OPTARG}"
		;;
		h | ?)
			pfDrUsage
			exit 0
		;;
	esac
done

# Must be run as root for effect
if [ ! "$(whoami)" = "root" ]; then
	echo "Must be run as root." >&2
	exit 1
fi


# Intro Explanation; skip if we are fully defined
if [ -z "${pfNewDisk}" ] || [ -z "${pfGoodDisk}" ] || [ -z "${pfBadDisk}" ]; then
	cat > "/dev/stderr" << EOF
This script will help automate replacing a disk in a zfs mirror on pfSense. It
expects that the disk that you will be introducing into the mirror is is entirly
blank and has not been initialized in any way. Addtionally the new must be at
least as large as the smallest disk in the array. As well as specifing the new
disk, you will also need to specify a "Good" disk that will be used as a
template for the partion layout and an "Old" disk that the new disk will replace
(the "Good" and "Old" disks can be the same disk). If both disks are unhealthy
please reinstall instead.

EOF

	zpool status
fi

if [ -z "${pfNewDisk}" ]; then
	read -rp $'\n\nPick the "New" disk:\n['"$(sysctl -n kern.disks)"'] ' choice
	pfNewDisk="${choice}"
fi

if [ -z "${pfGoodDisk}" ]; then
	read -rp $'\n\nPick the "Good" disk:\n['"$(sysctl -n kern.disks)"'] ' choice
	pfGoodDisk="${choice}"
fi

if [ -z "${pfBadDisk}" ]; then
	read -rp $'\n\nPick the "Old" disk:\n['"$(sysctl -n kern.disks)"'] ' choice
	pfBadDisk="${choice}"
fi

# Die if we do not have enough info
if [ -z "${pfNewDisk}" ] || [ -z "${pfGoodDisk}" ] || [ -z "${pfBadDisk}" ]; then
	exit 1
fi


pfCheckDiskSize

pfInitializeDisk

pfZfsReplace
