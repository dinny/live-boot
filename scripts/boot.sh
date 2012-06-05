#!/bin/sh

# set -e

export PATH="/root/usr/bin:/root/usr/sbin:/root/bin:/root/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

echo "/root/lib" >> /etc/ld.so.conf
echo "/root/usr/lib" >> /etc/ld.so.conf

mountpoint="/live/image"
alt_mountpoint="/media"
LIVE_MEDIA_PATH="live"

HOSTNAME="host"

mkdir -p "${mountpoint}"
tried="/tmp/tried"

# Create /etc/mtab for debug purpose and future syncs
if [ ! -d /etc ]
then
	mkdir /etc/
fi

if [ ! -f /etc/mtab ]
then
	touch /etc/mtab
fi

. /scripts/live-helpers

if [ ! -f /live.vars ]
then
	touch /live.vars
fi

is_live_path ()
{
	DIRECTORY="${1}"

	if [ -d "${DIRECTORY}"/"${LIVE_MEDIA_PATH}" ]
	then
		for FILESYSTEM in squashfs ext2 ext3 ext4 xfs dir jffs2
		do
			if [ "$(echo ${DIRECTORY}/${LIVE_MEDIA_PATH}/*.${FILESYSTEM})" != "${DIRECTORY}/${LIVE_MEDIA_PATH}/*.${FILESYSTEM}" ]
			then
				return 0
			fi
		done
	fi

	return 1
}

matches_uuid ()
{
	if [ "${IGNORE_UUID}" ] || [ ! -e /conf/uuid.conf ]
	then
		return 0
	fi

	path="${1}"
	uuid="$(cat /conf/uuid.conf)"

	for try_uuid_file in "${path}/.disk/live-uuid"*
	do
		[ -e "${try_uuid_file}" ] || continue

		try_uuid="$(cat "${try_uuid_file}")"

		if [ "${uuid}" = "${try_uuid}" ]
		then
			return 0
		fi
	done

	return 1
}

get_backing_device ()
{
	case "${1}" in
		*.squashfs|*.ext2|*.ext3|*.ext4|*.jffs2)
			echo $(setup_loop "${1}" "loop" "/sys/block/loop*" '0' "${LIVE_MEDIA_ENCRYPTION}" "${2}")
			;;

		*.dir)
			echo "directory"
			;;

		*)
			panic "Unrecognized live filesystem: ${1}"
			;;
	esac
}

match_files_in_dir ()
{
	# Does any files match pattern ${1} ?
	local pattern="${1}"

	if [ "$(echo ${pattern})" != "${pattern}" ]
	then
		return 0
	fi

	return 1
}

mount_images_in_directory ()
{
	directory="${1}"
	rootmnt="${2}"
	mac="${3}"


	if match_files_in_dir "${directory}/${LIVE_MEDIA_PATH}/*.squashfs" ||
		match_files_in_dir "${directory}/${LIVE_MEDIA_PATH}/*.ext2" ||
		match_files_in_dir "${directory}/${LIVE_MEDIA_PATH}/*.ext3" ||
		match_files_in_dir "${directory}/${LIVE_MEDIA_PATH}/*.ext4" ||
		match_files_in_dir "${directory}/${LIVE_MEDIA_PATH}/*.jffs2" ||
		match_files_in_dir "${directory}/${LIVE_MEDIA_PATH}/*.dir"
	then
		[ -n "${mac}" ] && adddirectory="${directory}/${LIVE_MEDIA_PATH}/${mac}"
		setup_unionfs "${directory}/${LIVE_MEDIA_PATH}" "${rootmnt}" "${adddirectory}"
	else
		panic "No supported filesystem images found at /${LIVE_MEDIA_PATH}."
	fi
}

is_nice_device ()
{
	sysfs_path="${1#/sys}"

	if [ -e /lib/udev/path_id ]
	then
		# squeeze
		PATH_ID="/lib/udev/path_id"
	else
		# wheezy/sid (udev >= 174)
		PATH_ID="/sbin/udevadm test-builtin path_id"
	fi

	if ${PATH_ID} "${sysfs_path}" | egrep -q "ID_PATH=(usb|pci-[^-]*-(ide|sas|scsi|usb|virtio)|platform-sata_mv|platform-orion-ehci|platform-mmc|platform-mxsdhci)"
	then
		return 0
	elif echo "${sysfs_path}" | grep -q '^/block/vd[a-z]$'
	then
		return 0
	elif echo ${sysfs_path} | grep -q "^/block/dm-"
	then
		return 0
	elif echo ${sysfs_path} | grep -q "^/block/mtdblock"
	then
		return 0
	fi

	return 1
}

copy_live_to ()
{
	copyfrom="${1}"
	copytodev="${2}"
	copyto="${copyfrom}_swap"

	if [ -z "${MODULETORAM}" ]
	then
		size=$(fs_size "" ${copyfrom}/${LIVE_MEDIA_PATH} "used")
	else
		MODULETORAMFILE="${copyfrom}/${LIVE_MEDIA_PATH}/${MODULETORAM}"

		if [ -f "${MODULETORAMFILE}" ]
		then
			size=$( expr $(ls -la ${MODULETORAMFILE} | awk '{print $5}') / 1024 + 5000 )
		else
			log_warning_msg "Error: toram-module ${MODULETORAM} (${MODULETORAMFILE}) could not be read."
			return 1
		fi
	fi

	if [ "${copytodev}" = "ram" ]
	then
		# copying to ram:
		freespace=$(awk '/^MemFree:/{f=$2} /^Cached:/{c=$2} END{print f+c}' /proc/meminfo)
		mount_options="-o size=${size}k"
		free_string="memory"
		fstype="tmpfs"
		dev="/dev/shm"
	else
		# it should be a writable block device
		if [ -b "${copytodev}" ]
		then
			dev="${copytodev}"
			free_string="space"
			fstype=$(get_fstype "${dev}")
			freespace=$(fs_size "${dev}")
		else
			log_warning_msg "${copytodev} is not a block device."
			return 1
		fi
	fi

	if [ "${freespace}" -lt "${size}" ]
	then
		log_warning_msg "Not enough free ${free_string} (${freespace}k free, ${size}k needed) to copy live media in ${copytodev}."
		return 1
	fi

	# Custom ramdisk size
	if [ -z "${mount_options}" ] && [ -n "${ramdisk_size}" ]
	then
		# FIXME: should check for wrong values
		mount_options="-o size=${ramdisk_size}"
	fi

	# begin copying (or uncompressing)
	mkdir "${copyto}"
	log_begin_msg "mount -t ${fstype} ${mount_options} ${dev} ${copyto}"
	mount -t "${fstype}" ${mount_options} "${dev}" "${copyto}"

	if [ "${extension}" = "tgz" ]
	then
		cd "${copyto}"
		tar zxf "${copyfrom}/${LIVE_MEDIA_PATH}/$(basename ${FETCH})"
		rm -f "${copyfrom}/${LIVE_MEDIA_PATH}/$(basename ${FETCH})"
		mount -r -o move "${copyto}" "${rootmnt}"
		cd "${OLDPWD}"
	else
		if [ -n "${MODULETORAMFILE}" ]
		then
			if [ -x /bin/rsync ]
			then
				echo " * Copying $MODULETORAMFILE to RAM" 1>/dev/console
				rsync -a --progress ${MODULETORAMFILE} ${copyto} 1>/dev/console # copy only the filesystem module
			else
				cp ${MODULETORAMFILE} ${copyto} # copy only the filesystem module
			fi
		else
			if [ -x /bin/rsync ]
			then
				echo " * Copying whole medium to RAM" 1>/dev/console
				rsync -a --progress ${copyfrom}/* ${copyto} 1>/dev/console  # "cp -a" from busybox also copies hidden files
			else
				mkdir -p ${copyto}/${LIVE_MEDIA_PATH}
				cp -a ${copyfrom}/${LIVE_MEDIA_PATH}/* ${copyto}/${LIVE_MEDIA_PATH}
				if [ -e ${copyfrom}/${LIVE_MEDIA_PATH}/.disk ]
				then
					cp -a ${copyfrom}/${LIVE_MEDIA_PATH}/.disk ${copyto}
				fi
			fi
		fi

		umount ${copyfrom}
		mount -r -o move ${copyto} ${copyfrom}
	fi

	rmdir ${copyto}
	return 0
}

do_netsetup ()
{
	modprobe -q af_packet # For DHCP

	udevadm trigger
	udevadm settle

	[ -n "$ETHDEV_TIMEOUT" ] || ETHDEV_TIMEOUT=15
	echo "Using timeout of $ETHDEV_TIMEOUT seconds for network configuration."

	if [ -z "${NETBOOT}" ] && [ -z "${FETCH}" ] && \
	   [ -z "${HTTPFS}" ] && [ -z "${FTPFS}" ]
	then


	# support for Syslinux IPAPPEND parameter
	# it sets the BOOTIF variable on the kernel parameter

	if [ -n "${BOOTIF}" ]
	then
		# pxelinux sets BOOTIF to a value based on the mac address of the
		# network card used to PXE boot, so use this value for DEVICE rather
		# than a hard-coded device name from initramfs.conf. this facilitates
		# network booting when machines may have multiple network cards.
		# pxelinux sets BOOTIF to 01-$mac_address

		# strip off the leading "01-", which isn't part of the mac
		# address
		temp_mac=${BOOTIF#*-}

		# convert to typical mac address format by replacing "-" with ":"
		bootif_mac=""
		IFS='-'
		for x in $temp_mac
		do
			if [ -z "$bootif_mac" ]
			then
				bootif_mac="$x"
			else
				bootif_mac="$bootif_mac:$x"
			fi
		done
		unset IFS

		# look for devices with matching mac address, and set DEVICE to
		# appropriate value if match is found.

		for device in /sys/class/net/*
		do
			if [ -f "$device/address" ]
			then
				current_mac=$(cat "$device/address")

				if [ "$bootif_mac" = "$current_mac" ]
				then
					DEVICE=${device##*/}
					break
				fi
			fi
		done
	fi

	# if ethdevice was not specified on the kernel command line
	# make sure we try to get a working network configuration
	# for *every* present network device (except for loopback of course)
	if [ -z "$ETHDEVICE" ] ; then
		echo "If you want to boot from a specific device use bootoption ethdevice=..."
		for device in /sys/class/net/*; do
			dev=${device##*/} ;
			if [ "$dev" != "lo" ] ; then
				ETHDEVICE="$ETHDEVICE $dev"
			fi
		done
	fi

	# split args of ethdevice=eth0,eth1 into "eth0 eth1"
	for device in $(echo $ETHDEVICE | sed 's/,/ /g') ; do
		devlist="$devlist $device"
	done

	# this is tricky (and ugly) because ipconfig sometimes just hangs/runs into
	# an endless loop; if execution fails give it two further tries, that's
	# why we use '$devlist $devlist $devlist' for the other for loop
	for dev in $devlist $devlist $devlist ; do
		echo "Executing ipconfig -t $ETHDEV_TIMEOUT $dev"
		ipconfig -t "$ETHDEV_TIMEOUT" $dev | tee -a /netboot.config &
		jobid=$!
		sleep "$ETHDEV_TIMEOUT" ; sleep 1
		if [ -r /proc/"$jobid"/status ] ; then
			echo "Killing job $jobid for device $dev as ipconfig ran into recursion..."
			kill -9 $jobid
		fi

		# if configuration of device worked we should have an assigned
		# IP address, if so let's use the device as $DEVICE for later usage.
		# simple and primitive approach which seems to work fine
		if ifconfig $dev | grep -q 'inet.*addr:' ; then
			export DEVICE="$dev"
			break
		fi
	done

	else
		for interface in ${DEVICE}; do
			ipconfig -t "$ETHDEV_TIMEOUT" ${interface} | tee /netboot-${interface}.config
			[ -e /tmp/net-${interface}.conf ] && . /tmp/net-${interface}.conf
			if [ "$IPV4ADDR" != "0.0.0.0" ]
			then
				break
			fi
		done
	fi

	for interface in ${DEVICE}; do
		# source relevant ipconfig output
		OLDHOSTNAME=${HOSTNAME}
		[ -e /tmp/net-${interface}.conf ] && . /tmp/net-${interface}.conf
		[ -z ${HOSTNAME} ] && HOSTNAME=${OLDHOSTNAME}
		export HOSTNAME

		if [ -n "${interface}" ]
		then
			HWADDR="$(cat /sys/class/net/${interface}/address)"
		fi

		if [ ! -e "/etc/resolv.conf" ]
		then
			echo "Creating /etc/resolv.conf"

			if [ -n "${DNSDOMAIN}" ]
			then
				echo "domain ${DNSDOMAIN}" > /etc/resolv.conf
				echo "search ${DNSDOMAIN}" >> /etc/resolv.conf
			fi

			for i in ${IPV4DNS0} ${IPV4DNS1} ${IPV4DNS1}
			do
				if [ -n "$i" ] && [ "$i" != 0.0.0.0 ]
				then
					echo "nameserver $i" >> /etc/resolv.conf
				fi
			done
		fi

		# Check if we have a network device at all
		if ! ls /sys/class/net/"$interface" > /dev/null 2>&1 && \
		   ! ls /sys/class/net/eth0 > /dev/null 2>&1 && \
		   ! ls /sys/class/net/wlan0 > /dev/null 2>&1 && \
		   ! ls /sys/class/net/ath0 > /dev/null 2>&1 && \
		   ! ls /sys/class/net/ra0 > /dev/null 2>&1
		then
			panic "No supported network device found, maybe a non-mainline driver is required."
		fi
	done
}

do_netmount()
{
	do_netsetup

	if [ "${NFSROOT}" = "auto" ]
	then
		NFSROOT=${ROOTSERVER}:${ROOTPATH}
	fi

	rc=1

	if ( [ -n "${FETCH}" ] || [ -n "${HTTPFS}" ] || [ -n "${FTPFS}" ] )
	then
		do_httpmount
		return $?
	fi

	if [ "${NFSROOT#*:}" = "${NFSROOT}" ] && [ "$NETBOOT" != "cifs" ]
	then
		NFSROOT=${ROOTSERVER}:${NFSROOT}
	fi

	log_begin_msg "Trying netboot from ${NFSROOT}"

	if [ "${NETBOOT}" != "nfs" ] && do_cifsmount
	then
		rc=0
	elif do_nfsmount
	then
		NETBOOT="nfs"
		export NETBOOT
		rc=0
	fi

	log_end_msg
	return ${rc}
}

do_iscsi()
{
	do_netsetup
	#modprobe ib_iser
	modprobe iscsi_tcp
	local debugopt=""
	[ "${DEBUG}" = "Yes" ] && debugopt="-d 8"
	#FIXME this name is supposed to be unique - some date + ifconfig hash?
	ISCSI_INITIATORNAME="iqn.1993-08.org.debian.live:01:$(echo "${HWADDR}" | sed -e s/://g)"
	export ISCSI_INITIATORNAME
	if [ -n "${ISCSI_SERVER}" ] ; then
		iscsistart $debugopt -i "${ISCSI_INITIATORNAME}" -t "${ISCSI_TARGET}" -g 1 -a "${ISCSI_SERVER}" -p "${ISCSI_PORT}"
	else
		iscsistart $debugopt -i "${ISCSI_INITIATORNAME}" -t "${ISCSI_TARGET}" -g 1 -a "${ISCSI_PORTAL}" -p 3260
	fi
	if [ $? != 0 ]
	then
		panic "Failed to log into iscsi target"
	fi
	local host="$(ls -d /sys/class/scsi_host/host*/device/iscsi_host:host* \
			    /sys/class/scsi_host/host*/device/iscsi_host/host* | sed -e 's:/device.*::' -e 's:.*host::')"
	if [ -n "${host}" ]
	then
		local devices=""
		local i=0
		while [ -z "${devices}" -a $i -lt 60 ]
		do
			sleep 1
			devices="$(ls -d /sys/class/scsi_device/${host}*/device/block:* \
					 /sys/class/scsi_device/${host}*/device/block/* | sed -e 's!.*[:/]!!')"
			i=$(expr $i + 1)
			echo -ne $i\\r
		done
		for dev in $devices
		do
			if check_dev "null" "/dev/$dev"
			then
				NETBOOT="iscsi"
				export NETBOOT
				return 0;
			fi
		done
		panic "Failed to locate a live device on iSCSI devices (tried: $devices)."
	else
		panic "Failed to locate iSCSI host in /sys"
	fi
}

do_httpmount ()
{
	rc=1

	for webfile in HTTPFS FTPFS FETCH
	do
		local url="$(eval echo \"\$\{${webfile}\}\")"
		local extension="$(echo "${url}" | sed 's/\(.*\)\.\(.*\)/\2/')"

		if [ -n "$url" ]
		then
			case "${extension}" in
				iso|squashfs|tgz|tar)
					if [ "${extension}" = "iso" ]
					then
						mkdir -p "${alt_mountpoint}"
						dest="${alt_mountpoint}"
					else
						local dest="${mountpoint}/${LIVE_MEDIA_PATH}"
						mount -t ramfs ram "${mountpoint}"
						mkdir -p "${dest}"
					fi
					if [ "${webfile}" = "FETCH" ]
					then
						case "$url" in
							tftp*)
								ip="$(dirname $url | sed -e 's|tftp://||g' -e 's|/.*$||g')"
								rfile="$(echo $url | sed -e "s|tftp://$ip||g")"
								lfile="$(basename $url)"
								log_begin_msg "Trying tftp -g -b 10240 -r $rfile -l ${dest}/$lfile $ip"
								tftp -g -b 10240 -r $rfile -l ${dest}/$lfile $ip
							;;

							*)
								log_begin_msg "Trying wget ${url} -O ${dest}/$(basename ${url})"
								wget "${url}" -O "${dest}/$(basename ${url})"
								;;
						esac
					else
						log_begin_msg "Trying to mount ${url} on ${dest}/$(basename ${url})"
						if [ "${webfile}" = "FTPFS" ]
						then
							FUSE_MOUNT="curlftpfs"
							url="$(dirname ${url})"
						else
							FUSE_MOUNT="httpfs"
						fi
						modprobe fuse
						$FUSE_MOUNT "${url}" "${dest}"
						ROOT_PID="$(minips h -C "$FUSE_MOUNT" | { read x y ; echo "$x" ; } )"
					fi
					[ ${?} -eq 0 ] && rc=0
					[ "${extension}" = "tgz" ] && live_dest="ram"
					if [ "${extension}" = "iso" ]
					then
						isoloop=$(setup_loop "${dest}/$(basename "${url}")" "loop" "/sys/block/loop*" "" '')
						mount -t iso9660 "${isoloop}" "${mountpoint}"
						rc=${?}
					fi
					break
					;;

				*)
					log_begin_msg "Unrecognized archive extension for ${url}"
					;;
			esac
		fi
	done

	if [ ${rc} != 0 ]
	then
		if [ -d "${alt_mountpoint}" ]
		then
		        umount "${alt_mountpoint}"
			rmdir "${alt_mountpoint}"
		fi
		umount "${mountpoint}"
	elif [ "${webfile}"  != "FETCH" ] ; then
		NETBOOT="${webfile}"
		export NETBOOT
	fi

	return ${rc}
}

do_nfsmount ()
{
	rc=1

	modprobe -q nfs

	if [ -n "${NFSOPTS}" ]
	then
		NFSOPTS="-o ${NFSOPTS}"
	fi

	log_begin_msg "Trying nfsmount -o nolock -o ro ${NFSOPTS} ${NFSROOT} ${mountpoint}"

	# FIXME: This while loop is an ugly HACK round an nfs bug
	i=0
	while [ "$i" -lt 60 ]
	do
		nfsmount -o nolock -o ro ${NFSOPTS} "${NFSROOT}" "${mountpoint}" && rc=0 && break
		sleep 1
		i="$(($i + 1))"
	done

	return ${rc}
}

do_cifsmount ()
{
	rc=1

	if [ -x "/sbin/mount.cifs" ]
	then
		if [ -z "${NFSOPTS}" ]
		then
			CIFSOPTS="-ouser=root,password="
		else
			CIFSOPTS="-o ${NFSOPTS}"
		fi

		log_begin_msg "Trying mount.cifs ${NFSROOT} ${mountpoint} ${CIFSOPTS}"
		modprobe -q cifs

		if mount.cifs "${NFSROOT}" "${mountpoint}" "${CIFSOPTS}"
		then
			rc=0
		fi
	fi

	return ${rc}
}

do_snap_copy ()
{
	fromdev="${1}"
	todir="${2}"
	snap_type="${3}"
	size=$(fs_size "${fromdev}" "" "used")

	if [ -b "${fromdev}" ]
	then
		log_success_msg "Copying snapshot ${fromdev} to ${todir}..."

		# look for free mem
		if [ -n "${HOMEMOUNTED}" -a "${snap_type}" = "HOME" ]
		then
			todev=$(awk -v pat="$(base_path ${todir})" '$2 == pat { print $1 }' /proc/mounts)
			freespace=$(df -k | awk '/'${todev}'/{print $4}')
		else
			freespace=$(awk '/^MemFree:/{f=$2} /^Cached:/{c=$2} END{print f+c}' /proc/meminfo)
		fi

		tomount="/mnt/tmpsnap"

		if [ ! -d "${tomount}" ]
		then
			mkdir -p "${tomount}"
		fi

		fstype=$(get_fstype "${fromdev}")

		if [ -n "${fstype}" ]
		then
			# Copying stuff...
			mount -o ro -t "${fstype}" "${fromdev}" "${tomount}" || log_warning_msg "Error in mount -t ${fstype} -o ro ${fromdev} ${tomount}"
			cp -a "${tomount}"/* ${todir}
			umount "${tomount}"
		else
			log_warning_msg "Unrecognized fstype: ${fstype} on ${fromdev}:${snap_type}"
		fi

		rmdir "${tomount}"

		if echo ${fromdev} | grep -qs loop
		then
			losetup -d "${fromdev}"
		fi

		return 0
	else
		log_warning_msg "Unable to find the snapshot ${snap_type} medium"
		return 1
	fi
}

try_snap ()
{
	# copy the contents of previously found snapshot to ${snap_mount}
	# and remember the device and filename for resync on exit in live-boot.init

	snapdata="${1}"
	snap_mount="${2}"
	snap_type="${3}"
	snap_relpath="${4}"

	if [ -z "${snap_relpath}" ]
	then
		# root snapshot, default usage
		snap_relpath="/"
	else
		# relative snapshot (actually used just for "/home" snapshots)
		snap_mount="${2}${snap_relpath}"
	fi

	if [ -n "${snapdata}" ] && [ ! -b "${snapdata}" ]
	then
		log_success_msg "found snapshot: ${snapdata}"
		snapdev="$(echo ${snapdata} | cut -f1 -d ' ')"
		snapback="$(echo ${snapdata} | cut -f2 -d ' ')"
		snapfile="$(echo ${snapdata} | cut -f3 -d ' ')"

		if ! try_mount "${snapdev}" "${snapback}" "ro"
		then
			break
		fi

		RES="0"

		if echo "${snapfile}" | grep -qs '\(squashfs\|ext2\|ext3\|ext4\|jffs2\)'
		then
			# squashfs, jffs2 or ext2/ext3/ext4 snapshot
			dev=$(get_backing_device "${snapback}/${snapfile}")

			do_snap_copy "${dev}" "${snap_mount}" "${snap_type}"
			RES="$?"
		else
			# cpio.gz snapshot

			# Unfortunately klibc's cpio is incompatible with the
			# rest of the world; everything else requires -u -d,
			# while klibc doesn't implement them. Try to detect
			# whether it's in use.
			cpiopath="$(which cpio)" || true
			if [ "$cpiopath" ] && grep -aq /lib/klibc "$cpiopath"
			then
				cpioargs=
			else
				cpioargs='--unconditional --make-directories'
			fi

			if [ -s "${snapback}/${snapfile}" ]
			then
				BEFOREDIR="$(pwd)"
				cd "${snap_mount}" && zcat "${snapback}/${snapfile}" | $cpiopath $cpioargs --extract --preserve-modification-time --no-absolute-filenames --sparse 2>/dev/null
				RES="$?"
				cd "${BEFOREDIR}"
			else
				log_warning_msg "${snapback}/${snapfile} is empty, adding it for sync on reboot."
				RES="0"
			fi

			if [ "${RES}" != "0" ]
			then
				log_warning_msg "failure to \"zcat ${snapback}/${snapfile} | $cpiopath $cpioargs --extract --preserve-modification-time --no-absolute-filenames --sparse\""
			fi
		fi

		umount "${snapback}" ||  log_warning_msg "failure to \"umount ${snapback}\""

		if [ "${RES}" != "0" ]
		then
			log_warning_msg "Impossible to include the ${snapfile} Snapshot file"
		fi

	elif [ -b "${snapdata}" ]
	then
		# Try to find if it could be a snapshot partition
		dev="${snapdata}"
		log_success_msg "found snapshot ${snap_type} device on ${dev}"
		if echo "${dev}" | grep -qs loop
		then
			# strange things happens, user confused?
			snaploop=$( losetup ${dev} | awk '{print $3}' | tr -d '()' )
			snapfile=$(basename ${snaploop})
			snapdev=$(awk -v pat="$( dirname ${snaploop})" '$2 == pat { print $1 }' /proc/mounts)
		else
			snapdev="${dev}"
		fi

		if ! do_snap_copy "${dev}" "${snap_mount}" "${snap_type}"
		then
			log_warning_msg "Impossible to include the ${snap_type} Snapshot (i)"
			return 1
		else
			if [ -n "${snapfile}" ]
			then
				# it was a loop device, user confused
				umount ${snapdev}
			fi
		fi
	else
		log_warning_msg "Impossible to include the ${snap_type} Snapshot (o)"
		return 1
	fi

	if [ -z ${PERSISTENCE_READONLY} ]
	then
		echo "export ${snap_type}SNAP=${snap_relpath}:${snapdev}:${snapfile}" >> snapshot.conf # for resync on reboot/halt
	fi
	return 0
}

setup_unionfs ()
{
	image_directory="${1}"
	rootmnt="${2}"
	addimage_directory="${3}"

	case ${UNIONTYPE} in
		aufs|unionfs|overlayfs)
			modprobe -q -b ${UNIONTYPE}

			if ! cut -f2 /proc/filesystems | grep -q "^${UNIONTYPE}\$" && [ -x /bin/unionfs-fuse ]
			then
				echo "${UNIONTYPE} not available, falling back to unionfs-fuse."
				echo "This might be really slow."

				UNIONTYPE="unionfs-fuse"
			fi
			;;
	esac

	if [ "${UNIONTYPE}" = unionfs-fuse ]
	then
		modprobe fuse
	fi

	# run-init can't deal with images in a subdir, but we're going to
	# move all of these away before it runs anyway.  No, we're not,
	# put them in / since move-mounting them into / breaks mono and
	# some other apps.

	croot="/"

	# Let's just mount the read-only file systems first
	rofslist=""

	if [ -z "${PLAIN_ROOT}" ]
	then
		# Read image names from ${MODULE}.module if it exists
		if [ -e "${image_directory}/filesystem.${MODULE}.module" ]
		then
			for IMAGE in $(cat ${image_directory}/filesystem.${MODULE}.module)
			do
				image_string="${image_string} ${image_directory}/${IMAGE}"
			done
		elif [ -e "${image_directory}/${MODULE}.module" ]
		then
			for IMAGE in $(cat ${image_directory}/${MODULE}.module)
			do
				image_string="${image_string} ${image_directory}/${IMAGE}"
			done
		else
			# ${MODULE}.module does not exist, create a list of images
			for FILESYSTEM in squashfs ext2 ext3 ext4 xfs jffs2 dir
			do
				for IMAGE in "${image_directory}"/*."${FILESYSTEM}"
				do
					if [ -e "${IMAGE}" ]
					then
						image_string="${image_string} ${IMAGE}"
					fi
				done
			done

			if [ -n "${addimage_directory}" ] && [ -d "${addimage_directory}" ]
			then
				for FILESYSTEM in squashfs ext2 ext3 ext4 xfs jffs2 dir
				do
					for IMAGE in "${addimage_directory}"/*."${FILESYSTEM}"
					do
						if [ -e "${IMAGE}" ]
						then
							image_string="${image_string} ${IMAGE}"
						fi
					done
				done
			fi

			# Now sort the list
			image_string="$(echo ${image_string} | sed -e 's/ /\n/g' | sort )"
		fi

		[ -n "${MODULETORAMFILE}" ] && image_string="${image_directory}/$(basename ${MODULETORAMFILE})"

		mkdir -p "${croot}"

		for image in ${image_string}
		do
			imagename=$(basename "${image}")

			export image devname
			maybe_break live-realpremount
			log_begin_msg "Running /scripts/live-realpremount"
			run_scripts /scripts/live-realpremount
			log_end_msg

			if [ -d "${image}" ]
			then
				# it is a plain directory: do nothing
				rofslist="${image} ${rofslist}"
			elif [ -f "${image}" ]
			then
				if losetup --help 2>&1 | grep -q -- "-r\b"
				then
					backdev=$(get_backing_device "${image}" "-r")
				else
					backdev=$(get_backing_device "${image}")
				fi
				fstype=$(get_fstype "${backdev}")

				if [ "${fstype}" = "unknown" ]
				then
					panic "Unknown file system type on ${backdev} (${image})"
				fi

				if [ -z "${fstype}" ]
				then
					fstype="${imagename##*.}"
					log_warning_msg "Unknown file system type on ${backdev} (${image}), assuming ${fstype}."
				fi

				if [ "${UNIONTYPE}" != "unionmount" ]
				then
					mpoint="${croot}/${imagename}"
					rofslist="${mpoint} ${rofslist}"
				else
					mpoint="${rootmnt}"
					rofslist="${rootmnt} ${rofslist}"
				fi
				mkdir -p "${mpoint}"
				log_begin_msg "Mounting \"${image}\" on \"${mpoint}\" via \"${backdev}\""
				mount -t "${fstype}" -o ro,noatime "${backdev}" "${mpoint}" || panic "Can not mount ${backdev} (${image}) on ${mpoint}"
				log_end_msg
			fi
		done
	else
		# we have a plain root system
		mkdir -p "${croot}/filesystem"
		log_begin_msg "Mounting \"${image_directory}\" on \"${croot}/filesystem\""
		mount -t $(get_fstype "${image_directory}") -o ro,noatime "${image_directory}" "${croot}/filesystem" || \
			panic "Can not mount ${image_directory} on ${croot}/filesystem" && \
			rofslist="${croot}/filesystem ${rofslist}"
		# probably broken:
		mount -o bind ${croot}/filesystem $mountpoint
		log_end_msg
	fi

	# tmpfs file systems
	touch /etc/fstab
	mkdir -p /live
	mount -t tmpfs tmpfs /live
	mkdir -p /live/overlay

	# Looking for persistence devices or files
	if [ -n "${PERSISTENCE}" ] && [ -z "${NOPERSISTENCE}" ]
	then

		if [ -z "${QUICKUSBMODULES}" ]
		then
			# Load USB modules
			num_block=$(ls -l /sys/block | wc -l)
			for module in sd_mod uhci-hcd ehci-hcd ohci-hcd usb-storage
			do
				modprobe -q -b ${module}
			done

			udevadm trigger
			udevadm settle

			# For some reason, udevsettle does not block in this scenario,
			# so we sleep for a little while.
			#
			# See https://bugs.launchpad.net/ubuntu/+source/casper/+bug/84591
			for timeout in 5 4 3 2 1
			do
				sleep 1

				if [ $(ls -l /sys/block | wc -l) -gt ${num_block} ]
				then
					break
				fi
			done
		fi

		case "${PERSISTENCE_MEDIA}" in
			removable)
				whitelistdev="$(removable_dev)"
				;;
			removable-usb)
				whitelistdev="$(removable_usb_dev)"
				;;
			*)
				whitelistdev=""
				;;
		esac

		if is_in_comma_sep_list overlay ${PERSISTENCE_METHOD}
		then
			overlays="${old_root_overlay_label} ${old_home_overlay_label} ${custom_overlay_label}"
		fi

		if is_in_comma_sep_list snapshot ${PERSISTENCE_METHOD}
		then
			snapshots="${root_snapshot_label} ${home_snapshot_label}"
		fi

		local root_snapdata=""
		local home_snapdata=""
		local overlay_devices=""
		for media in $(find_persistence_media "${overlays}" "${snapshots}" "${whitelistdev}")
		do
			media="$(echo ${media} | tr ":" " ")"
			case ${media} in
				${root_snapshot_label}=*|${old_root_snapshot_label}=*)
					if [ -z "${root_snapdata}" ]
					then
						root_snapdata="${media#*=}"
					fi
					;;
				${home_snapshot_label}=*)
					# This second type should be removed when snapshot will get smarter,
					# hence when "/etc/live-snapshot*list" will be supported also by
					# ext2|ext3|ext4|jffs2 snapshot types.
					if [ -z "${home_snapdata}" ]
					then
						home_snapdata="${media#*=}"
					fi
					;;
				${old_root_overlay_label}=*)
					device="${media#*=}"
					fix_backwards_compatibility ${device} / union
					overlay_devices="${overlay_devices} ${device}"
					;;
				${old_home_overlay_label}=*)
					device="${media#*=}"
					fix_backwards_compatibility ${device} /home bind
					overlay_devices="${overlay_devices} ${device}"
					;;
				${custom_overlay_label}=*)
					device="${media#*=}"
					overlay_devices="${overlay_devices} ${device}"
					;;
			 esac
		done
	elif [ -n "${NFS_COW}" ] && [ -z "${NOPERSISTENCE}" ]
	then
		# check if there are any nfs options
		if echo ${NFS_COW}|grep -q ','
		then
			nfs_cow_opts="-o nolock,$(echo ${NFS_COW}|cut -d, -f2-)"
			nfs_cow=$(echo ${NFS_COW}|cut -d, -f1)
		else
			nfs_cow_opts="-o nolock"
			nfs_cow=${NFS_COW}
		fi

		if [ -n "${PERSISTENCE_READONLY}" ]
		then
			nfs_cow_opts="${nfs_cow_opts},nocto,ro"
		fi

		mac="$(get_mac)"
		if [ -n "${mac}" ]
		then
			cowdevice=$(echo ${nfs_cow}|sed "s/client_mac_address/${mac}/")
			cow_fstype="nfs"
		else
			panic "unable to determine mac address"
		fi
	fi

	if [ -z "${cowdevice}" ]
	then
		cowdevice="tmpfs"
		cow_fstype="tmpfs"
		cow_mountopt="rw,noatime,mode=755"
	fi

	if [ "${UNIONTYPE}" != "unionmount" ]
	then
		if [ -n "${PERSISTENCE_READONLY}" ] && [ "${cowdevice}" != "tmpfs" ]
		then
			mount -t tmpfs -o rw,noatime,mode=755 tmpfs "/live/overlay"
			root_backing="/live/persistence/$(basename ${cowdevice})-root"
			mkdir -p ${root_backing}
		else
			root_backing="/live/overlay"
		fi

		if [ "${cow_fstype}" = "nfs" ]
		then
			log_begin_msg \
				"Trying nfsmount ${nfs_cow_opts} ${cowdevice} ${root_backing}"
			nfsmount ${nfs_cow_opts} ${cowdevice} ${root_backing} || \
				panic "Can not mount ${cowdevice} (n: ${cow_fstype}) on ${root_backing}"
		else
			mount -t ${cow_fstype} -o ${cow_mountopt} ${cowdevice} ${root_backing} || \
				panic "Can not mount ${cowdevice} (o: ${cow_fstype}) on ${root_backing}"
		fi
	fi

	rofscount=$(echo ${rofslist} |wc -w)

	rofs=${rofslist%% }

	if [ -n "${EXPOSED_ROOT}" ]
	then
		if [ ${rofscount} -ne 1 ]
		then
			panic "only one RO file system supported with exposedroot: ${rofslist}"
		fi

		mount --bind ${rofs} ${rootmnt} || \
			panic "bind mount of ${rofs} failed"

		if [ -z "${SKIP_UNION_MOUNTS}" ]
		then
			cow_dirs='/var/tmp /var/lock /var/run /var/log /var/spool /home /var/lib/live'
		else
			cow_dirs=''
		fi
	else
		cow_dirs="/"
	fi

	if [ "${cow_fstype}" != "tmpfs" ] && [ "${cow_dirs}" != "/" ] && [ "${UNIONTYPE}" = "unionmount" ]
	then
		true # FIXME: Maybe it does, I don't really know.
		#panic "unionmount does not support subunions (${cow_dirs})."
	fi

	for dir in ${cow_dirs}; do
		unionmountpoint="${rootmnt}${dir}"
		mkdir -p ${unionmountpoint}
		if [ "${UNIONTYPE}" = "unionmount" ]
		then
			# FIXME: handle PERSISTENCE_READONLY
			unionmountopts="-t ${cow_fstype} -o noatime,union,${cow_mountopt} ${cowdevice}"
			mount_full $unionmountopts "${unionmountpoint}"
		else
			cow_dir="/live/overlay${dir}"
			rofs_dir="${rofs}${dir}"
			mkdir -p ${cow_dir}
			if [ -n "${PERSISTENCE_READONLY}" ] && [ "${cowdevice}" != "tmpfs" ]
			then
				do_union ${unionmountpoint} ${cow_dir} ${root_backing} ${rofs_dir}
			else
				do_union ${unionmountpoint} ${cow_dir} ${rofs_dir}
			fi
		fi || panic "mount ${UNIONTYPE} on ${unionmountpoint} failed with option ${unionmountopts}"
	done

	# Correct the permissions of /:
	chmod 0755 "${rootmnt}"

	live_rofs_list=""
	# SHOWMOUNTS is necessary for custom mounts with the union option
	# Since we may want to do custom mounts in user-space it's best to always enable SHOWMOUNTS
	if true #[ -n "${SHOWMOUNTS}" ] || ( [ -n "${PERSISTENCE}" ] && [ -z "${NOPERSISTENCE}" ] 1)
	then
		# XXX: is the for loop really necessary? rofslist can only contain one item (see above XXX about EXPOSEDROOT) and this is also assumed elsewhere above (see use of $rofs above).
		for d in ${rofslist}
		do
			live_rofs="/live/rofs/${d##*/}"
			live_rofs_list="${live_rofs_list} ${live_rofs}"
			mkdir -p "${live_rofs}"
			case d in
				*.dir)
					# do nothing # mount -o bind "${d}" "${live_rofs}"
					;;
				*)
					case "${UNIONTYPE}" in
						unionfs-fuse)
							mount -o bind "${d}" "${live_rofs}"
							;;
						*)
							mount -o move "${d}" "${live_rofs}"
							;;
					esac
					;;
			esac
		done
	fi

	# Adding custom persistence
	if [ -n "${PERSISTENCE}" ] && [ -z "${NOPERSISTENCE}" ]
	then
		local custom_mounts="/tmp/custom_mounts.list"
		rm -rf ${custom_mounts} 2> /dev/null

		# Gather information about custom mounts from devies detected as overlays
		get_custom_mounts ${custom_mounts} ${overlay_devices}

		[ -n "${DEBUG}" ] && cp ${custom_mounts} "/live/persistence"

		# Now we do the actual mounting (and symlinking)
		local used_overlays=""
		used_overlays=$(activate_custom_mounts ${custom_mounts})
		rm ${custom_mounts}

		# Close unused overlays (e.g. due to missing $persistence_list)
		for overlay in ${overlay_devices}
		do
			if echo ${used_overlays} | grep -qve "^\(.* \)\?${device}\( .*\)\?$"
			then
				close_persistence_media ${overlay}
			fi
		done

		# Look for other snapshots to copy in
		[ -n "${root_snapdata}" ] && try_snap "${root_snapdata}" "${rootmnt}" "ROOT"
		# This second type should be removed when snapshot grow smarter
		[ -n "${home_snapdata}" ] && try_snap "${home_snapdata}" "${rootmnt}" "HOME" "/home"
	fi

	mkdir -p "${rootmnt}/live"
	mount -o move /live "${rootmnt}/live" >/dev/null 2>&1 || mount -o bind /live "${rootmnt}/live" || log_warning_msg "Unable to move or bind /live to ${rootmnt}/live"

	# shows cow fs on /overlay for use by live-snapshot
	mkdir -p "${rootmnt}/live/overlay"
	mount -o move /live/overlay "${rootmnt}/live/overlay" >/dev/null 2>&1 || mount -o bind /overlay "${rootmnt}/live/overlay" || log_warning_msg "Unable to move or bind /overlay to ${rootmnt}/live/overlay"

}

check_dev ()
{
	sysdev="${1}"
	devname="${2}"
	skip_uuid_check="${3}"

	# support for fromiso=.../isofrom=....
	if [ -n "$FROMISO" ]
	then
		ISO_DEVICE=$(dirname $FROMISO)
		if ! [ -b $ISO_DEVICE ]
		then
			# to support unusual device names like /dev/cciss/c0d0p1
			# as well we have to identify the block device name, let's
			# do that for up to 15 levels
			i=15
			while [ -n "$ISO_DEVICE" ] && [ "$i" -gt 0 ]
			do
				ISO_DEVICE=$(dirname ${ISO_DEVICE})
				[ -b "$ISO_DEVICE" ] && break
				i=$(($i -1))
		        done
		fi

		if [ "$ISO_DEVICE" = "/" ]
		then
			echo "Warning: device for bootoption fromiso= ($FROMISO) not found.">>/boot.log
		else
			fs_type=$(get_fstype "${ISO_DEVICE}")
			if is_supported_fs ${fs_type}
			then
				mkdir /live/fromiso
				mount -t $fs_type "$ISO_DEVICE" /live/fromiso
				ISO_NAME="$(echo $FROMISO | sed "s|$ISO_DEVICE||")"
				loopdevname=$(setup_loop "/live/fromiso/${ISO_NAME}" "loop" "/sys/block/loop*" "" '')
				devname="${loopdevname}"
			else
				echo "Warning: unable to mount $ISO_DEVICE." >>/boot.log
			fi
		fi
	fi

	if [ -z "${devname}" ]
	then
		devname=$(sys2dev "${sysdev}")
	fi

	if [ -d "${devname}" ]
	then
		mount -o bind "${devname}" $mountpoint || continue

		if is_live_path $mountpoint
		then
			echo $mountpoint
			return 0
		else
			umount $mountpoint
		fi
	fi

	IFS=","
	for device in ${devname}
	do
		case "$device" in
			*mapper*)
				# Adding lvm support
				if [ -x /scripts/local-top/lvm2 ]
				then
					ROOT="$device" resume="" /scripts/local-top/lvm2
				fi
				;;

			/dev/md*)
				# Adding raid support
				if [ -x /scripts/local-top/mdadm ]
				then
					cp /conf/conf.d/md /conf/conf.d/md.orig
					echo "MD_DEVS=$device " >> /conf/conf.d/md
					/scripts/local-top/mdadm
					mv /conf/conf.d/md.orig /conf/conf.d/md
				fi
				;;
		esac
	done
	unset IFS

	[ -n "$device" ] && devname="$device"

	[ -e "$devname" ] || continue

	if [ -n "${LIVE_MEDIA_OFFSET}" ]
	then
		loopdevname=$(setup_loop "${devname}" "loop" "/sys/block/loop*" "${LIVE_MEDIA_OFFSET}" '')
		devname="${loopdevname}"
	fi

	fstype=$(get_fstype "${devname}")

	if is_supported_fs ${fstype}
	then
		devuid=$(blkid -o value -s UUID "$devname")
		[ -n "$devuid" ] && grep -qs "\<$devuid\>" $tried && continue
		mount -t ${fstype} -o ro,noatime "${devname}" ${mountpoint} || continue
		[ -n "$devuid" ] && echo "$devuid" >> $tried

		if [ -n "${FINDISO}" ]
		then
			if [ -f ${mountpoint}/${FINDISO} ]
			then
				umount ${mountpoint}
				mkdir -p /live/findiso
				mount -t ${fstype} -o ro,noatime "${devname}" /live/findiso
				loopdevname=$(setup_loop "/live/findiso/${FINDISO}" "loop" "/sys/block/loop*" 0 "")
				devname="${loopdevname}"
				mount -t iso9660 -o ro,noatime "${devname}" ${mountpoint}
			else
				umount ${mountpoint}
			fi
		fi

		if is_live_path ${mountpoint} && \
			([ "${skip_uuid_check}" ] || matches_uuid ${mountpoint})
		then
			echo ${mountpoint}
			return 0
		else
			umount ${mountpoint} 2>/dev/null
		fi
	fi

	if [ -n "${LIVE_MEDIA_OFFSET}" ]
	then
		losetup -d "${loopdevname}"
	fi

	return 1
}

find_livefs ()
{
	timeout="${1}"

	# don't start autodetection before timeout has expired
	if [ -n "${LIVE_MEDIA_TIMEOUT}" ]
	then
		if [ "${timeout}" -lt "${LIVE_MEDIA_TIMEOUT}" ]
		then
			return 1
		fi
	fi

	# first look at the one specified in the command line
	case "${LIVE_MEDIA}" in
		removable-usb)
			for sysblock in $(removable_usb_dev "sys")
			do
				for dev in $(subdevices "${sysblock}")
				do
					if check_dev "${dev}"
					then
						return 0
					fi
				done
			done
			return 1
			;;

		removable)
			for sysblock in $(removable_dev "sys")
			do
				for dev in $(subdevices "${sysblock}")
				do
					if check_dev "${dev}"
					then
						return 0
					fi
				done
			done
			return 1
			;;

		*)
			if [ ! -z "${LIVE_MEDIA}" ]
			then
				if check_dev "null" "${LIVE_MEDIA}" "skip_uuid_check"
				then
					return 0
				fi
			fi
			;;
	esac

	# or do the scan of block devices
	# prefer removable devices over non-removable devices, so scan them first
	devices_to_scan="$(removable_dev 'sys') $(non_removable_dev 'sys')"

	for sysblock in $devices_to_scan
	do
		devname=$(sys2dev "${sysblock}")
		[ -e "$devname" ] || continue
		fstype=$(get_fstype "${devname}")

		if /lib/udev/cdrom_id ${devname} > /dev/null
		then
			if check_dev "null" "${devname}"
			then
				return 0
			fi
		elif is_nice_device "${sysblock}"
		then
			for dev in $(subdevices "${sysblock}")
			do
				if check_dev "${dev}"
				then
					return 0
				fi
			done
		elif [ "${fstype}" = "squashfs" -o \
			"${fstype}" = "btrfs" -o \
			"${fstype}" = "ext2" -o \
			"${fstype}" = "ext3" -o \
			"${fstype}" = "ext4" -o \
			"${fstype}" = "jffs2" ]
		then
			# This is an ugly hack situation, the block device has
			# an image directly on it.  It's hopefully
			# live-boot, so take it and run with it.
			ln -s "${devname}" "${devname}.${fstype}"
			echo "${devname}.${fstype}"
			return 0
		fi
	done

	return 1
}

integrity_check ()
{
	media_mountpoint="${1}"

	log_begin_msg "Checking media integrity"

	cd ${media_mountpoint}
	/bin/md5sum -c md5sum.txt < /dev/tty8 > /dev/tty8
	RC="${?}"

	log_end_msg

	if [ "${RC}" -eq 0 ]
	then
		log_success_msg "Everything ok, will reboot in 10 seconds."
		sleep 10
		cd /
		umount ${media_mountpoint}
		sync
		echo u > /proc/sysrq-trigger
		echo b > /proc/sysrq-trigger
	else
		panic "Not ok, a media defect is likely, switch to VT8 for details."
	fi
}

mountroot ()
{
	if [ -x /scripts/local-top/cryptroot ]; then
	    /scripts/local-top/cryptroot
	fi

	exec 6>&1
	exec 7>&2
	exec > boot.log
	exec 2>&1
	tail -f boot.log >&7 &
	tailpid="${!}"

	# Ensure 'panic' function is overridden
	. /scripts/live-functions

	Arguments

	maybe_break live-premount
	log_begin_msg "Running /scripts/live-premount"
	run_scripts /scripts/live-premount
	log_end_msg

	# Needed here too because some things (*cough* udev *cough*)
	# changes the timeout

	if [ ! -z "${NETBOOT}" ] || [ ! -z "${FETCH}" ] || [ ! -z "${HTTPFS}" ] || [ ! -z "${FTPFS}" ]
	then
		if do_netmount
		then
			livefs_root="${mountpoint}"
		else
			panic "Unable to find a live file system on the network"
		fi
	else
		if [ -n "${ISCSI_PORTAL}" ]
		then
			do_iscsi && livefs_root="${mountpoint}"
		elif [ -n "${PLAIN_ROOT}" ] && [ -n "${ROOT}" ]
		then
			# Do a local boot from hd
			livefs_root=${ROOT}
		else
			if [ -x /usr/bin/memdiskfind ]
			then
				MEMDISK=$(/usr/bin/memdiskfind)

				if [ $? -eq 0 ]
				then
					# We found a memdisk, set up phram
					modprobe phram phram=memdisk,${MEMDISK}

					# Load mtdblock, the memdisk will be /dev/mtdblock0
					modprobe mtdblock
				fi
			fi

			# Scan local devices for the image
			i=0
			while [ "$i" -lt 60 ]
			do
				livefs_root=$(find_livefs ${i})

				if [ -n "${livefs_root}" ]
				then
					break
				fi

				sleep 1
				i="$(($i + 1))"
			done
		fi
	fi

	if [ -z "${livefs_root}" ]
	then
		panic "Unable to find a medium containing a live file system"
	fi

	if [ "${INTEGRITY_CHECK}" ]
	then
		integrity_check "${livefs_root}"
	fi

	if [ "${TORAM}" ]
	then
		live_dest="ram"
	elif [ "${TODISK}" ]
	then
		live_dest="${TODISK}"
	fi

	if [ "${live_dest}" ]
	then
		log_begin_msg "Copying live media to ${live_dest}"
		copy_live_to "${livefs_root}" "${live_dest}"
		log_end_msg
	fi

	# if we do not unmount the ISO we can't run "fsck /dev/ice" later on
	# because the mountpoint is left behind in /proc/mounts, so let's get
	# rid of it when running from RAM
	if [ -n "$FROMISO" ] && [ "${TORAM}" ]
	then
		losetup -d /dev/loop0

		if is_mountpoint /live/fromiso
		then
			umount /live/fromiso
			rmdir --ignore-fail-on-non-empty /live/fromiso \
				>/dev/null 2>&1 || true
		fi
	fi

	if [ -n "${MODULETORAMFILE}" ] || [ -n "${PLAIN_ROOT}" ]
	then
		setup_unionfs "${livefs_root}" "${rootmnt}"
	else
		mac="$(get_mac)"
		mac="$(echo ${mac} | sed 's/-//g')"
		mount_images_in_directory "${livefs_root}" "${rootmnt}" "${mac}"
	fi


	if [ -n "${ROOT_PID}" ] ; then
		echo "${ROOT_PID}" > "${rootmnt}"/live/root.pid
	fi

	log_end_msg

	# unionfs-fuse needs /dev to be bind-mounted for the duration of
	# live-bottom; udev's init script will take care of things after that
	if [ "${UNIONTYPE}" = unionfs-fuse ]
	then
		mount -n -o bind /dev "${rootmnt}/dev"
	fi

	# Move to the new root filesystem so that programs there can get at it.
	if [ ! -d /root/live/image ]
	then
		mkdir -p /root/live/image
		mount --move /live/image /root/live/image
	fi

	# aufs2 in kernel versions around 2.6.33 has a regression:
	# directories can't be accessed when read for the first the time,
	# causing a failure for example when accessing /var/lib/fai
	# when booting FAI, this simple workaround solves it
	ls /root/* >/dev/null 2>&1

	# Move findiso directory to the new root filesystem so that programs there can get at it.
	if [ -d /live/findiso ] && [ ! -d /root/live/findiso ]
	then
		mkdir -p /root/live/findiso
		mount -n --move /live/findiso /root/live/findiso
	fi

	# if we do not unmount the ISO we can't run "fsck /dev/ice" later on
	# because the mountpoint is left behind in /proc/mounts, so let's get
	# rid of it when running from RAM
	if [ -n "$FINDISO" ] && [ "${TORAM}" ]
	then
		losetup -d /dev/loop0

		if is_mountpoint /root/live/findiso
		then
			umount /root/live/findiso
			rmdir --ignore-fail-on-non-empty /root/live/findiso \
				>/dev/null 2>&1 || true
		fi
	fi

	# copy snapshot configuration if exists
	if [ -f snapshot.conf ]
	then
		log_begin_msg "Copying snapshot.conf to ${rootmnt}/etc/live/boot.d"
		if [ ! -d "${rootmnt}/etc/live/boot.d" ]
		then
			mkdir -p "${rootmnt}/etc/live/boot.d"
		fi
		cp snapshot.conf "${rootmnt}/etc/live/boot.d/"
		log_end_msg
	fi

	if [ -f /etc/resolv.conf ] && [ ! -s ${rootmnt}/etc/resolv.conf ]
	then
		log_begin_msg "Copying /etc/resolv.conf to ${rootmnt}/etc/resolv.conf"
		cp -v /etc/resolv.conf ${rootmnt}/etc/resolv.conf
		log_end_msg
	fi

	maybe_break live-bottom
	log_begin_msg "Running /scripts/live-bottom\n"

	run_scripts /scripts/live-bottom
	log_end_msg

	if [ "${UNIONFS}" = unionfs-fuse ]
	then
		umount "${rootmnt}/dev"
	fi

	exec 1>&6 6>&-
	exec 2>&7 7>&-
	kill ${tailpid}
	[ -w "${rootmnt}/var/log/" ] && mkdir -p /var/log/live && cp boot.log "${rootmnt}/var/log/live" 2>/dev/null
}