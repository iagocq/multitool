#!/usr/bin/env bash

BOOT_DEBUG=5
if [ -z "$BOOT_DEBUG" ]; then
    BOOT_DEBUG=5
fi

# debug code inspired by debian's initramfs init
debugshell() {
    if [ "$BOOT_DEBUG" -gt 2 ]; then
        echo "debugshell: $1"
        setsid bash
    fi
}

if [ "$BOOT_DEBUG" -gt 0 ]; then
    set -x
fi
