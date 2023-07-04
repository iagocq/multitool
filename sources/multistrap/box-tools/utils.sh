#!/usr/bin/env bash

if [ -z "$BOOT_DEBUG" ]; then
    BOOT_DEBUG=0
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
