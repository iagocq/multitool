#!/bin/bash
# Completion hook, does the steps to configure the packages into a chrooted and emulated
# sandbox

ROOTFS_DIR=$1

mount -t proc /proc $ROOTFS_DIR/proc
mount -t sysfs /sys $ROOTFS_DIR/sys
mkdir -p $ROOTFS_DIR/dev/pts
mount --bind /dev/pts $ROOTFS_DIR/dev/pts

cp $(which qemu-arm-static) $ROOTFS_DIR/bin/qemu-arm-static
chmod +x $ROOTFS_DIR/bin/qemu-arm-static

# Write a configure.sh script into rootfs/tmp
# to let dpkg configure the packages.
# We will execute this script inside chroot + qemu sandbox
cat <<'EOF' > $ROOTFS_DIR/tmp/configure.sh
#!/bin/bash

export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true
export LC_ALL=C LANGUAGE=C LANG=C

if [ -d /tmp/preseeds/ ]; then
	for file in ls -1 /tmp/preseeds/*; do
		debconf-set-selections $file
	done
fi

dpkg --configure -a

# Second dpkg configure pass, for those packages which have failed
# due dependencies on first pass
dpkg --configure -a

# Give execution permissions to /sbin/init script
chmod +x /sbin/init

# Give execution permissions to /usr/local/bin/multitoolsh
chmod +x /usr/local/bin/multitool.sh

# Patch /etc/shadow to remove root password
sed -i 's/root:\*:/root::/' /etc/shadow

# Create a symlink for /etc/resolv.conf to /tmp because
# dhclient script wants a writable resolve.conf
ln -sf /tmp/resolv.conf /etc/resolv.conf

EOF

chmod +x $ROOTFS_DIR/tmp/configure.sh

cp -raT overlays "$ROOTFS_DIR"

chmod 600 "$ROOTFS_DIR/etc/dropbear/dropbear_rsa_host_key"
chmod 600 "$ROOTFS_DIR/etc/dropbear/dropbear_dss_host_key"
chmod 600 "$ROOTFS_DIR/etc/dropbear/dropbear_ecdsa_host_key"
chmod 640 "$ROOTFS_DIR/etc/dropbear/dropbear_rsa_host_key.pub"
chmod 640 "$ROOTFS_DIR/etc/dropbear/dropbear_dss_host_key.pub"
chmod 640 "$ROOTFS_DIR/etc/dropbear/dropbear_ecdsa_host_key.pub"

cp init "$ROOTFS_DIR/sbin/init"
cp -r box-tools "$ROOTFS_DIR/usr/local"

chmod +x "$ROOTFS_DIR/sbin/init"
chmod -R +x "$ROOTFS_DIR/usr/local/box-tools"

mkdir -p "$ROOTFS_DIR/mnt"
mkdir -p "$ROOTFS_DIR/newroot"

# Once we're in chroot, root / directory is rootfs
chroot rootfs /bin/qemu-arm-static /bin/bash /tmp/configure.sh

rm $ROOTFS_DIR/bin/qemu-arm-static
rm $ROOTFS_DIR/tmp/configure.sh

umount $ROOTFS_DIR/proc
umount $ROOTFS_DIR/sys
umount $ROOTFS_DIR/dev/pts
