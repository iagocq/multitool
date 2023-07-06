#!/usr/bin/env bash

# This script:
# - mounts a relevant partition (mount_part)
# - loads a kernel (load_kernel)
# - kexec's to it (kexec_kernel)
# - mounts the relevant partition again (mount_part)
# - mounts an overlayfs on top of the partition (mount_overlay)
# - and exec's the new root (exec_new_root)
#
# The relevant partition can be given directly as a path to a block device,
# a raw image file or a compressed image

# given a path to a file (or a raw image) ($1)
# find a relevant partition and mount it (at $2)
mount_part() {
    path="$1"
    mount_at="$2"

    loop_device="$(losetup -P --find --show "$path")"
    mount "$loop_device"p1 "$2"
}

# given a path ($1)
# try to kexec -l the first kernel found
load_kernel() {
    kexec -l
}

kexec_kernel() {
    cmdline="$(cat /proc/cmdline) program=liveboot liveboot_stage2"
    kexec -l "$kernel_path" --dtb "$dtb_path" --command-line "$cmdline"
}

exec_new_root() {
    
}
