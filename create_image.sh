#!/bin/bash

PWD=$(pwd)
DIST_PATH="$PWD/dist"
SOURCES_PATH="$PWD/sources"
TOOLS_PATH="$PWD/tools"

DEST_IMAGE="$DIST_PATH/multitool.img"

# Script to create the multitool image for rk322x boards

USERID=$(id -u)

if [ "$USERID" != "0" ]; then
	echo "This script can only work with root permissions"
	exit 26
fi

mkdir -p "$DIST_PATH"

if [ ! -f "$DIST_PATH/root.img" ]; then

	echo -n "Creating debian base rootfs. This will take a while..."

	cd "${SOURCES_PATH}/multistrap"
	multistrap -f multistrap.conf > /tmp/multistrap.log 2>&1

	if [ $? -ne 0 ]; then
		echo -e "\nfailed:"
		tail /tmp/multistrap.log
		echo -e "\nFull log at /tmp/multistrap.log"
		exit 25
	fi

	echo "done!"

	echo -n "Creating squashfs from rootfs..."
	mksquashfs rootfs "$DIST_PATH/root.img" -noappend -all-root > /dev/null 2>&1

	if [ $? -ne 0 ]; then
		echo -e "\nfailed"
		exit 26
	fi

	echo "done"

fi

ROOTFS_SIZE=$(du "$DIST_PATH/root.img" | cut -f 1)
ROOTFS_SIZE=$(((($ROOTFS_SIZE / 1024) + 1) * 1024))
ROOTFS_SECTORS=$(($ROOTFS_SIZE * 2))

if [ $? -ne 0 ]; then
	echo -e "\ncould not determine size of squashfs root filesystem"
	exit 27
fi

cd "$PWD"

echo "-> rootfs size: ${ROOTFS_SIZE}kb"

echo "Creating empty image in $DEST_IMAGE"
dd if=/dev/zero of="$DEST_IMAGE" bs=1M count=1024 conv=sync,fsync >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Error while creating $DEST_IMAGE empty file"
	exit 1
fi

echo "Mounting as loop device"
LOOP_DEVICE=$(losetup -f --show "$DEST_IMAGE")

if [ $? -ne 0 ]; then
	echo "Could not loop mount $DEST_IMAGE"
	exit 2
fi

echo "Creating partition table and partitions"
parted -s -- "$LOOP_DEVICE" mktable msdos >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not create partitions table"
	exit 3
fi

START=$((0x8000))
END=$(($START + $ROOTFS_SECTORS - 1))
parted -s -- "$LOOP_DEVICE" unit s mkpart primary $START $END >/dev/null 2>&1 
if [ $? -ne 0 ]; then
	echo "Could not create rootfs partition"
	exit 3
fi

parted -s -- "$LOOP_DEVICE" unit s mkpart primary fat32 $(($END + 1)) -1s >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not create fat partition"
	exit 3
fi

parted -s -- "$LOOP_DEVICE" set 1 boot off set 1 hidden on set 2 boot on >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not set partition flags"
	exit 28
fi

sync
sleep 1

echo "Remounting loop device with partitions"
losetup -d "$LOOP_DEVICE" >/dev/null 2>&1
sleep 1

if [ $? -ne 0 ]; then
	echo "Could not umount loop device $LOOP_DEVICE"
	exit 4
fi

LOOP_DEVICE=$(losetup -f --show -P "$DEST_IMAGE")
SQUASHFS_PARTITION="${LOOP_DEVICE}p1"
FAT_PARTITION="${LOOP_DEVICE}p2"

if [ $? -ne 0 ]; then
	echo "Could not remount loop device $LOOP_DEVICE"
	exit 5
fi

if [ ! -b "$SQUASHFS_PARTITION" ]; then
	echo "Could not find expected partition $SQUASHFS_PARTITION"
	exit 26
fi

if [ ! -b "$FAT_PARTITION" ]; then
	echo "Could not find expected partition $FAT_PARTITION"
	exit 6
fi

echo "Copying squashfs rootfilesystem"
dd if="${DIST_PATH}/root.img" of="$SQUASHFS_PARTITION" bs=256k conv=sync,fsync >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not install squashfs filesystem"
	exit 27
fi

echo "Formatting FAT32 partition"
mkfs.vfat "$FAT_PARTITION" >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not format partition"
	exit 7
fi

echo "Mounting FAT32 partition"
TEMP_DIR=$(mktemp -d)

if [ $? -ne 0 ]; then
	echo "Could not create temporary directory"
	exit 8
fi

mount "$FAT_PARTITION" "$TEMP_DIR" >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not mount $FAT_PARTITION to $TEMP_DIR"
	exit 9
fi

echo "Populating partition"
cp "${SOURCES_PATH}/kernel.img" "${TEMP_DIR}/kernel.img" > /dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not copy kernel"
	exit 10
fi

cp "${SOURCES_PATH}/rk322x-box.dtb" "${TEMP_DIR}/rk322x-box.dtb" >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not copy device tree"
	exit 12
fi

mkdir -p "${TEMP_DIR}/extlinux"
if [ $? -ne 0 ]; then
	echo "Could not create extlinux directory"
	exit 13
fi

cp "${SOURCES_PATH}/extlinux.conf" "${TEMP_DIR}/extlinux/extlinux.conf" >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not copy extlinux.conf"
	exit 14
fi

PARTITION_UUID=$(lsblk -n -o UUID $FAT_PARTITION)
if [ $? -ne 0 ]; then
	echo "Could not get partition UUID"
	exit 15
fi

sed -i "s/#PARTUUID#/$PARTITION_UUID/g" "${TEMP_DIR}/extlinux/extlinux.conf"
if [ $? -ne 0 ]; then
	echo "Could not substitute partition UUID in extlinux.conf"
	exit 16
fi

echo "Unmount FAT32 partition"
umount "$FAT_PARTITION" >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not umount $FAT_PARTITION"
	exit 17
fi

rmdir "$TEMP_DIR"

if [ $? -ne 0 ]; then
	echo "Could not remove temporary directory $TEMP_DIR"
	exit 24
fi

echo "Creating and installing u-boot.img for rockchip platform"
"$TOOLS_PATH/loaderimage" --pack --uboot "${SOURCES_PATH}/u-boot-dtb.bin" "${DIST_PATH}/uboot.img" 0x61000000 >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not create uboot.img"
	exit 18
fi

dd if="${DIST_PATH}/uboot.img" of="$LOOP_DEVICE" seek=$((0x4000)) conv=sync,fsync >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not install uboot.img"
	exit 19
fi

echo "Creating and installing trustos.img for rockchip platform"
"$TOOLS_PATH/loaderimage" --pack --trustos "${SOURCES_PATH}/rk322x_tee_ta_1.1.0-297-ga4fd2d1.bin" "${DIST_PATH}/trustos.img" 0x68400000 >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not create trustos.img"
	exit 20
fi

dd if="${DIST_PATH}/trustos.img" of="$LOOP_DEVICE" seek=$((0x6000)) conv=sync,fsync >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not install trustos.img"
	exit 21
fi

echo "Installing idbloader.img"

dd if="${SOURCES_PATH}/idbloader.img" of="$LOOP_DEVICE" seek=$((0x40)) conv=sync,fsync >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not install idbloader.img"
	exit 22
fi

echo "Unmounting loop device"
losetup -d "$LOOP_DEVICE" >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not unmount $LOOP_DEVICE"
	exit 23
fi

echo "Done! Available image in $DEST_IMAGE"