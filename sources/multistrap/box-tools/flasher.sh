#!/usr/bin/env bash

BOOT_DEBUG=5
. /usr/local/box-tools/utils.sh
set -x

sleep 30

if [ -e "/mnt/flash.conf" ]; then
    source /mnt/flash.conf
    [[ -n "$file" && "$file" != http* ]] && file="/mnt/$file"
else
    echo "/mnt/flash.conf is missing"
fi

debugshell "after flash.conf"

while [ -z "$output" -o ! -e "$output" ]; do
    if [ "$output" = droptoshell ]; then
        bash
    else
        echo "$output does not exist! Type droptoshell to get access to the shell"
    fi
    lsblk
    echo -n "path: "
    read output
done

file_size=0
file_command=""

rm -f /tmp/comm /tmp/comm2
mkfifo /tmp/comm /tmp/comm2

if [ $? = 2 ]; then
    echo "no ip"
elif [ "$server_ip" -a "$server_port" ]; then
    nc "$server_ip" "$server_port" < /tmp/comm &
    nc_proc=$!
fi

get_file_info() {
    if [[ "$file" == http* ]]; then
        file_size=$(curl -LsI "$file" | grep -i Content-Length | awk '{print $2}' | tr -d '\r')
        file_command="curl -Ls '$file'"
    elif [[ "$file" == *.tar.gz ]]; then
        tar_process=1
        tar_cmd="cat '$file' | gunzip | tar xvf - -C /tmp/flash --warning=no-timestamp"
    elif [[ "$file" == *.tar ]]; then
        tar_process=1
        tar_cmd="tar xvf '$file' -C /tmp/flash --warning=no-timestamp"
    elif [[ "$file" == *.gz ]]; then
        file_size=$(gunzip -l "$file" | tail -1 | awk '{print $2}')
        file_command="cat '$file' | gunzip"
    else
        file_size=$(wc -c "$file" | awk '{print $1}')
        file_command="cat '$file'"
    fi
}

get_file_info
while [ "$file_size" = "" ]; do
    echo "failed to get file info $file"
    echo -n "path or URL: "
    read file
    [ "$file" = droptoshell ] && bash
    get_file_info
done

if [ "$tar_process" ]; then
    parted "$output" -- mklabel msdos mkpart 8192 100%
    device="$(losetup -o $((8192*512)) --find --show "$output")"
    mkfs.ext4 -F $device
    mkdir /tmp/flash
    mount "$device" /tmp/flash
    unset file_size
    eval $tar_cmd | grep -Eo '^./[a-z0-9\-_]+/[a-z0-9\-_]+' | stdbuf --output=L uniq > /tmp/comm2 &
else
    eval $file_command | pv -b -n > >(dd of=$output conv=fsync 2> /dev/null) 2> /tmp/comm2 &
fi

sts=0
while [ $sts = 0 ]; do
    read
    [ -z "$REPLY" ] && echo done && break
    echo progress $REPLY $file_size
done < /tmp/comm2 >> /tmp/comm

if [ "$tar_process" ]; then
    umount /tmp/flash
fi

echo done
sleep 1
[ "$nc_proc" ] && kill $nc_proc
