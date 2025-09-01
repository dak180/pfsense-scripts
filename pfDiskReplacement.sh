#!/bin/bash
# shellcheck disable=SC2155
set -o pipefail

# References:
# https://redmine.pfsense.org/issues/15081
# https://redmine.pfsense.org/issues/15083
# https://redmine.pfsense.org/issues/15084
# https://www.yourwarrantyisvoid.com/2023/05/04/pfsense-replacing-a-failed-zfs-disk/
# https://wiki.joeplaa.com/en/zfs

# Static Vars
declare -A pfMemberName
readarray -t "driveList" <<< "$(sysctl -n kern.disks | sed -e 's: :\n:g' | grep -v 'mmcsd' | grep -v 'sdda' | grep -v 'ccd' | sort -V)"

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
		echo "${pfNewDisk} is not larger than ${pfGoodDisk}."  >&2
		exit 1
	fi
}

function pfDiskLabel() {
	# Use the gptid and fall back to the gpt label
	local pfNewZfsPartNum="$(gpart show "${pfGoodDisk}" | grep 'zfs' | sed -e 's:^[[:space:]]*::' | tr -s ' ' | cut -wf 3)"
	local pfNewGPTID="$(glabel status | grep "${pfNewDisk}p${pfNewZfsPartNum}" | grep 'gptid' | sed -e 's:^[[:space:]]*::' | tr -s ' ' | cut -wf 1)"
	local pfNewGPTlabel="$(glabel status | grep "${pfNewDisk}p${pfNewZfsPartNum}" | grep 'gpt' | grep -v 'gptid' | sed -e 's:^[[:space:]]*::' | tr -s ' ' | cut -wf 1)"

	if [ ! -z "${pfNewGPTID}" ]; then
		pfZfsReadyName="${pfNewGPTID}"
	elif [ ! -z "${pfNewGPTlabel}" ]; then
		pfZfsReadyName="${pfNewGPTlabel}"
	else
		pfZfsReadyName="${pfNewDisk}p${pfNewZfsPartNum}"
	fi
}

function pfInitializeDisk () {
	# Vars
	local pfBootCode="$(grep "gpart bootcode" /var/log/bsdinstall_log)"

	local pfBootPartNum="$(gpart show "${pfGoodDisk}" | grep 'boot' | sed -e 's:^[[:space:]]*::' | tr -s ' ' | cut -wf 3)"
	local pfSwapPartNum="$(gpart show "${pfGoodDisk}" | grep 'swap' | sed -e 's:^[[:space:]]*::' | tr -s ' ' | cut -wf 3)"
	local pfEfiPartNum="$(gpart show "${pfGoodDisk}" | grep 'efi' | sed -e 's:^[[:space:]]*::' | tr -s ' ' | cut -wf 3)"

	local pfOldDiskNum="$(echo "${pfGoodDisk}" | sed -e 's:ada::' -e 's:da::' -e 's:nvd::')"
	local pfNewDiskNum="$(echo "${pfNewDisk}" | sed -e 's:ada::' -e 's:da::' -e 's:nvd::' -e 's:nda::' -e 's:md::' -e 's:ccd::')"

	# Determine the disk number
	if [ "${pfOldDiskNum}" -ge "${pfNewDiskNum}" ]; then
		pfNewDiskNum=$(( pfOldDiskNum + 3 ))
	fi

	# Get the bootcode command
	local pfBootCodeCmd="$(echo "${pfBootCode}" | grep "${pfGoodDisk}" | sed -e 's|DEBUG: zfs_create_diskpart: ||' -e 's:":'\'':g' -e "s:${pfGoodDisk}:${pfNewDisk}:")"
	if [ -z "${pfBootCodeCmd}" ]; then
		echo "Failed to find the boot code." >&2
		exit 1
	fi

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
	local pfRplaceDisk
	if [ ! -z "${pfMemberName["${pfBadDisk}p${pfZfsPartNum}"]}" ]; then
		pfRplaceDisk="${pfMemberName["${pfBadDisk}p${pfZfsPartNum}"]}"
	else
		pfRplaceDisk="${pfBadDisk}p${pfZfsPartNum}"
	fi
	zpool replace "${pfZpoolName}" "${pfRplaceDisk}" "${pfZfsReadyName}" || { echo "Failed to replace the disk." >&2; exit 1;}
}

function pfMapLabels() {
	local glabelList="$(glabel status | tail -n +2 | sed -e 's:^[[:space:]]*::' | tr -s ' ' | cut -wf 1,3)"
	local -A labelTranslationList
	local key
	local value
	pfZpoolStatus="$(zpool status -L)"

	while IFS=$' \t' read -r key value; do
		[[ -z "${key}" ]] && continue
		labelTranslationList["${key}"]="${value}"
	done <<< "${glabelList}"
	unset IFS


	if echo "${pfZpoolStatus}" | grep -q 'gptid/'; then
		local -a pfgptidList

		readarray -t "pfgptidList" <<< "$(zpool status -L | grep 'gptid/' | sed -e 's:^[[:space:]]*::' | cut -wf 1)"

		local diskID
		for diskID in "${pfgptidList[@]}"; do
			# shellcheck disable=SC2116
			pfZpoolStatus="$(echo "${pfZpoolStatus//${diskID}/${labelTranslationList["${diskID}"]}}")"
			pfMemberName["${labelTranslationList["${diskID}"]}"]="${diskID}"
		done
	fi

	if zpool status -L | grep -q 'gpt/'; then
		local -a pfgptList

		readarray -t "pfgptList" <<< "$(zpool status -L | grep 'gpt/' | sed -e 's:^[[:space:]]*::' | cut -wf 1)"

		local diskID
		for diskID in "${pfgptList[@]}"; do
			# shellcheck disable=SC2116
			pfZpoolStatus="$(echo "${pfZpoolStatus//${diskID}/${labelTranslationList["${diskID}"]}}")"
			pfMemberName["${labelTranslationList["${diskID}"]}"]="${diskID}"
		done
	fi
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

pfMapLabels

# Intro Explanation; skip if we are fully defined
if [ -z "${pfNewDisk}" ] || [ -z "${pfGoodDisk}" ] || [ -z "${pfBadDisk}" ]; then
	cat > "/dev/stderr" << EOF
This script will help automate replacing a disk in a zfs mirror on pfSense. It
expects that the disk that you will be introducing into the mirror is is
entirely blank and has not been initialized in any way. Additionally the new
must be at least as large as the smallest disk in the array. As well as
specifing the new disk, you will also need to specify a "Good" disk that will be
used as a template for the partion layout and an "Old" disk that the new disk
will replace (the "Good" and "Old" disks can be the same disk). If both disks
are unhealthy please reinstall instead.

EOF

	echo "${pfZpoolStatus}"
fi

if [ -z "${pfNewDisk}" ]; then
	read -rp $'\n\nPick the "New" disk:\n['"${driveList[*]}"'] ' choice
	pfNewDisk="${choice}"
	pfInteract="1"
fi

if [ -z "${pfGoodDisk}" ]; then
	read -rp $'\n\nPick the "Good" disk:\n['"${driveList[*]}"'] ' choice
	pfGoodDisk="${choice}"
	pfInteract="1"
fi

if [ -z "${pfBadDisk}" ]; then
	read -rp $'\n\nPick the "Old" disk:\n['"${driveList[*]}"'] ' choice
	pfBadDisk="${choice}"
	pfInteract="1"
fi

if [ "1" = "${pfInteract}" ]; then
	cat > "/dev/stderr" << EOF
You have selected:
	"New" disk: ${pfNewDisk} (will be completely erased)
	"Good" disk: ${pfGoodDisk} (will be used as a template)
	"Old" disk: ${pfBadDisk} (will be replaced in the pool)

EOF
	read -rp $'\n\nContinue?\n[y|N] ' choice

fi


# Die if we do not have enough info
IFS="|"
if [ -z "${pfNewDisk}" ] || [ -z "${pfGoodDisk}" ] || [ -z "${pfBadDisk}" ]; then
	echo "Not all disks defined." >&2
	exit 1
elif [[ ! "${IFS}${driveList[*]}${IFS}" =~ ${IFS}${pfNewDisk}${IFS} ]]; then
	echo "${pfNewDisk} is not a valid option." >&2
	exit 1
elif [[ ! "${IFS}${driveList[*]}${IFS}" =~ ${IFS}${pfGoodDisk}${IFS} ]]; then
	echo "${pfGoodDisk} is not a valid option." >&2
	exit 1
elif [[ ! "${IFS}${driveList[*]}${IFS}" =~ ${IFS}${pfBadDisk}${IFS} ]]; then
	echo "${pfBadDisk} is not a valid option." >&2
	exit 1
elif [ "${pfNewDisk}" = "${pfGoodDisk}" ] || [ "${pfNewDisk}" = "${pfBadDisk}" ]; then
	echo "${pfNewDisk} cannot be the same as the other disks." >&2
	exit 1
fi
unset IFS


# Use Dependent Vars
pfZfsPartNum="$(gpart show "${pfGoodDisk}" | grep 'zfs' | sed -e 's:^[[:space:]]*::' | tr -s ' ' | cut -wf 3)"


pfCheckDiskSize

pfInitializeDisk

pfDiskLabel

pfZfsReplace

clear

zpool status
