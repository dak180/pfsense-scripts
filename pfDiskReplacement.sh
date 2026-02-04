#!/usr/local/bin/bash
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
pfEFIMountTemplate="/tmp/pfefi.template"
pfEFIMountNew="/tmp/pfefi.new"

# Functions
function pfCleanup() {
	# This code runs when the script exits
	if mount | grep -q "${pfEFIMountTemplate}"; then
		umount "${pfEFIMountTemplate}" >/dev/null 2>&1 || true
	fi
	if mount | grep -q "${pfEFIMountNew}"; then
		umount "${pfEFIMountNew}" >/dev/null 2>&1 || true
	fi
}

trap pfCleanup EXIT

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
	if smartctl -q silent -d test "/dev/${pfNewDisk}"; then
		local pfNewDiskSize="$(smartctl -xj "/dev/${pfNewDisk}" | jq -Mre '.user_capacity.bytes | values')"
	else
		local pfNewDiskSize="$(smartctl -d 'sat,auto' -xj "/dev/${pfNewDisk}" | jq -Mre '.user_capacity.bytes | values')"
	fi
	if smartctl -q silent -d test "/dev/${pfGoodDisk}"; then
		local pfOldDiskSize="$(smartctl -xj "/dev/${pfGoodDisk}" | jq -Mre '.user_capacity.bytes | values')"
	else
		local pfOldDiskSize="$(smartctl -d 'sat,auto' -xj "/dev/${pfGoodDisk}" | jq -Mre '.user_capacity.bytes | values')"
	fi

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

function pfInitializeDisk() {
	# Vars
	local pfBootCode="$(grep "gpart bootcode" /var/log/bsdinstall_log)"

	local pfBootPartNum="$(gpart show "${pfGoodDisk}" | grep 'boot' | sed -e 's:^[[:space:]]*::' | tr -s ' ' | cut -wf 3)"
	local pfSwapPartNum="$(gpart show "${pfGoodDisk}" | grep 'swap' | sed -e 's:^[[:space:]]*::' | tr -s ' ' | cut -wf 3)"
	local pfEfiPartNum="$(gpart show "${pfGoodDisk}" | grep 'efi' | sed -e 's:^[[:space:]]*::' | tr -s ' ' | cut -wf 3)"

	local pfOldDiskNum="$(echo "${pfGoodDisk}" | sed -e 's:ada::' -e 's:da::' -e 's:nvd::' -e 's:nda::' -e 's:md::' -e 's:ccd::')"
	local pfNewDiskNum="$(echo "${pfNewDisk}" | sed -e 's:ada::' -e 's:da::' -e 's:nvd::' -e 's:nda::' -e 's:md::' -e 's:ccd::')"

	# Determine the disk number
	if [ "${pfOldDiskNum}" -ge "${pfNewDiskNum}" ]; then
		pfNewDiskNum=$(( pfOldDiskNum + 3 ))
	fi

	# Get the bootcode command
	if [ ! -z "${pfBootCode}" ]; then
		if ! grep -q "/boot/pmbr" <<< "${pfBootCode}" || [ ! -f "/boot/pmbr" ]; then
			echo "Failed to find the boot code." >&2
			exit 1
		fi
		if ! grep -q "/boot/gptzfsboot" <<< "${pfBootCode}" || [ ! -f "/boot/gptzfsboot" ]; then
			echo "Failed to find the boot code." >&2
			exit 1
		fi
	else
		echo "Failed to find the boot code." >&2
		exit 1
	fi
	if [ -z "${pfBootPartNum}" ]; then
		echo "Template disk does not have a boot partition." >&2
		exit 1
	fi
	local pfBootCodeCmd="gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i ${pfBootPartNum} ${pfNewDisk}"

	# Copy the partition layout to the new disk
	gpart backup "${pfGoodDisk}" | gpart restore -F "${pfNewDisk}" || { echo "Failed to initialize the disk." >&2; exit 1;}

	# Fix layout
	if [ ! -z "${pfEfiPartNum}" ]; then
		gpart modify -i "${pfEfiPartNum}" -l "efiboot${pfNewDiskNum}" "${pfNewDisk}" || { echo "Failed to rename the efi partition." >&2; exit 1;}
	fi
	gpart modify -i "${pfBootPartNum}" -l "gptboot${pfNewDiskNum}" "${pfNewDisk}" || { echo "Failed to rename the boot partition." >&2; exit 1;}
	if [ ! -z "${pfSwapPartNum}" ]; then
		if [ "${pfNoSwap}" = "1" ]; then
			swapoff -a
			gpart delete -i "${pfSwapPartNum}" "${pfNewDisk}" || { echo "Failed to remove the swap partition." >&2; exit 1;}
		else
			gpart modify -i "${pfSwapPartNum}" -l "swap${pfNewDiskNum}" "${pfNewDisk}" || { echo "Failed to rename the swap partition." >&2; exit 1;}
		fi
	fi
	gpart modify -i "${pfZfsPartNum}" -l "zfs${pfNewDiskNum}" "${pfNewDisk}" || { echo "Failed to rename the zfs partition." >&2; exit 1;}

	# Setup the boot code
	if [ ! -z "${pfEfiPartNum}" ]; then
		# Initialize the new EFI partition
		newfs_msdos -F 32 -c 1 -L "EFISYS${pfNewDiskNum}"  "/dev/gpt/efiboot${pfNewDiskNum}" || { echo "Failed to initialize the ms_dos partition." >&2; exit 1;}
		mkdir -p "${pfEFIMountNew}"
		mount -t msdosfs "/dev/gpt/efiboot${pfNewDiskNum}" "${pfEFIMountNew}" || { echo "Failed to mount the ms_dos partition." >&2; exit 1;}


		# Try mounting the efi partition from the template disk
		mkdir -p "${pfEFIMountTemplate}"
		mount -t msdosfs "/dev/${pfGoodDisk}p${pfEfiPartNum}" "${pfEFIMountTemplate}" || { echo "Failed to mount the efi partition." >&2; exit 1;}

		if [ -f "${pfEFIMountTemplate}/efi/boot/BOOTX64.EFI" ] || [ -f "${pfEFIMountTemplate}/efi/freebsd/loader.efi" ]; then
			cp -R "${pfEFIMountTemplate}/" "${pfEFIMountNew}" || { echo "Failed to set the efi boot code." >&2; exit 1;}
		elif [ -f "/boot/loader.efi" ]; then
			# If the template is empty try to build it manuallly
			mkdir -p "${pfEFIMountNew}/efi/freebsd/" "${pfEFIMountNew}/efi/boot/" || { echo "Failed to set the efi boot code." >&2; exit 1;}
			cp -R "/boot/loader.efi" "${pfEFIMountNew}/efi/boot/BOOTX64.EFI" || { echo "Failed to set the efi boot code." >&2; exit 1;}
			cp -R "/boot/loader.efi" "${pfEFIMountNew}/efi/freebsd/loader.efi" || { echo "Failed to set the efi boot code." >&2; exit 1;}
		else
			echo "Failed to find the efi boot code." >&2
			exit 1
		fi

		umount "${pfEFIMountTemplate}" || { echo "Failed to unmount the efi partition." >&2; exit 1;}

		umount "${pfEFIMountNew}" || { echo "Failed to unmount the ms_dos partition." >&2; exit 1;}
	fi

	${pfBootCodeCmd} || { echo "Failed to set the boot code." >&2; exit 1;}
	camcontrol rescan all
	sleep 3
}

function pfZfsReplace() {
	local pfZpoolName="$(zpool list -H -o name)"
	local pfRplaceDisk

	# Get the replacement disk name
	if [ ! -z "${pfMemberName["${pfBadDisk}p${pfZfsPartNum}"]}" ]; then
		pfRplaceDisk="${pfMemberName["${pfBadDisk}p${pfZfsPartNum}"]}"
	else
		pfRplaceDisk="${pfBadDisk}p${pfZfsPartNum}"
	fi

	# Replace the disk
	zpool replace "${pfZpoolName}" "/dev/${pfRplaceDisk}" "/dev/${pfZfsReadyName}" || { echo "Failed to replace the disk." >&2; exit 1;}
	camcontrol rescan all
	sleep 3
}

function pfMapLabels() {
	local glabelList="$(glabel status | tail -n +2 | sed -e 's:^[[:space:]]*::' | tr -s ' ' | cut -wf 1,3)"
	local -A labelTranslationList
	local key
	local value
	pfZpoolStatus="$(zpool status -L)"


	# Build the translation list
	while IFS=$' \t' read -r key value; do
		[[ -z "${key}" ]] && continue
		labelTranslationList["${key}"]="${value}"
	done <<< "${glabelList}"
	unset IFS


	# Translate the disk identifiers in zpool status
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

function pfDiskInList() {
	# Returns 0 if the disk name exists in driveList[], 1 otherwise
	local needle="$1"
	local disk

	for disk in "${driveList[@]}"; do
		if [ "${disk}" = "${needle}" ]; then
			return 0
		fi
	done

	return 1
}


while getopts ":t:r:n:hs" OPTION; do
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
		s)
			pfNoSwap=1
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
expects that the disk that you will be introducing into the mirror is entirely
blank and has not been initialized in any way. Additionally the new disk must be
at least as large as the smallest disk in the array. As well as specifying the
new disk, you will also need to specify a "Good" disk that will be used as a
template for the partition layout and an "Old" disk that the new disk will
replace (the "Good" and "Old" disks can be the same disk). If both disks are
unhealthy please reinstall instead.

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
	echo "Continue?"
	select choice in "Yes" "No"; do
		case ${choice} in
			Yes ) true; break;;
			No ) exit;;
		esac
	done
fi


# Die if we do not have enough info
if [ -z "${pfNewDisk}" ] || [ -z "${pfGoodDisk}" ] || [ -z "${pfBadDisk}" ]; then
	echo "Not all disks defined." >&2
	exit 1
elif ! pfDiskInList "${pfNewDisk}"; then
	echo "${pfNewDisk} is not a valid option." >&2
	exit 1
elif ! pfDiskInList "${pfGoodDisk}"; then
	echo "${pfGoodDisk} is not a valid option." >&2
	exit 1
elif ! pfDiskInList "${pfBadDisk}"; then
	echo "${pfBadDisk} is not a valid option." >&2
	exit 1
elif [ "${pfNewDisk}" = "${pfGoodDisk}" ] || [ "${pfNewDisk}" = "${pfBadDisk}" ]; then
	echo "${pfNewDisk} cannot be the same as the other disks." >&2
	exit 1
fi


# Use Dependent Vars
pfZfsPartNum="$(gpart show "${pfGoodDisk}" | grep 'zfs' | sed -e 's:^[[:space:]]*::' | tr -s ' ' | cut -wf 3)"
if [ -z "${pfZfsPartNum}" ]; then
	echo "Does not appear to be a zfs file system." >&2
	exit 1
fi


pfCheckDiskSize

pfInitializeDisk

pfDiskLabel

pfZfsReplace

clear

if smartctl -q silent -d test "/dev/${pfBadDisk}"; then
	pfOldSerial="$(smartctl -xj "/dev/${pfBadDisk}" | jq -Mre '.serial_number | values')"
else
	pfOldSerial="$(smartctl -d 'sat,auto' -xj "/dev/${pfBadDisk}" | jq -Mre '.serial_number | values')"
fi
if smartctl -q silent -d test "/dev/${pfNewDisk}"; then
	pfNewSerial="$(smartctl -xj "/dev/${pfNewDisk}" | jq -Mre '.serial_number | values')"
else
	pfNewSerial="$(smartctl -d 'sat,auto' -xj "/dev/${pfNewDisk}" | jq -Mre '.serial_number | values')"
fi

echo "Old Disk Serial Number (${pfBadDisk}): ${pfOldSerial}"
echo "New Disk Serial Number (${pfNewDisk}): ${pfNewSerial}"
glabel status
zpool status
cat /etc/fstab
echo "Check the fstab file to be sure the efi and swap devices are not a required mount"
