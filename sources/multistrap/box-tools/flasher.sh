#!/usr/bin/env bash

CONF_FILE=${1:-/mnt/flash.conf}
PATHS_RELATIVE_TO=${2:-/mnt}
IP_WAIT_MAX=30
INTERFACE=eth0
MNT_OUTPUT_DIR=/tmp/flash
LOG_LEVEL=${LOG_LEVEL:-1}

declare -A FLASH_CONF
declare -A COLORS

COLORS=(
    [GREY]='\033[0;37m'
    [WHITE]='\033[1;37m'
    [YELLOW]='\033[1;33m'
    [RED]='\033[1;31m'
    [CYAN]='\033[1;36m'
    [RESET]='\033[0m'
)

[ -t 1 ] && SUPPORTS_COLORS_TEST=1
SUPPORTS_COLORS=${SUPPORTS_COLORS:-$SUPPORTS_COLORS_TEST}

valid_ip_port() {
    ip="$1"
    port="$2"
    if [ -z "$ip" ] || [ -z "$port" ]; then
        log W "Invalid IP and port ($ip:$port)"
        return 61
    fi
}

start_logger() {
    exec 11>&1 12>&2

    {
        coproc STDOUT_COPROC {
            while read -r; do
                if [ "$LOG_LEVEL" -le 1 ]; then
                    _sub_log "STDOUT" "$REPLY" 11 'CYAN'
                fi
            done
        }

        coproc STDERR_COPROC {
            while read -r; do
                if [ "$LOG_LEVEL" -le 3 ]; then
                    _sub_log "STDERR" "$REPLY" 12 'CYAN'
                fi
            done
        }
    } 2> /dev/null

    exec 1>&"${STDOUT_COPROC[1]}" 2>&"${STDERR_COPROC[1]}"
}

stop_logger() {
    exec 1>&11 2>&12
    { exec 11>&- 12>&- "${STDOUT_COPROC[1]}">&- "${STDERR_COPROC[1]}">&-; } 2> /dev/null
}

_sub_log() {
    svtxt="$1"
    message="$2"
    fd="$3"
    color="${COLORS[$4]}"
    reset_color="${COLORS[RESET]}"
    date="$(date +%H:%M:%S)"
    [ "$SUPPORTS_COLORS" ] && printf "$color" >&"$fd"
    printf '[%s] [%-6s] %s\n' "$date" "$svtxt" "$message" >&"$fd"
    [ "$SUPPORTS_COLORS" ] && printf "$reset_color" >&"$fd"
}

log() {
    severity="$1"
    message="$2"
    svtxt="UNKN"
    fd=11
    lvl=0
    [ "$severity" = D ] && color=GREY && lvl=0 && svtxt="DEBUG"
    [ "$severity" = I ] && color=WHITE && lvl=1 && svtxt="INFO"
    [ "$severity" = W ] && color=YELLOW && lvl=2 && svtxt="WARN"
    [ "$severity" = E ] && color=RED && lvl=3 && svtxt="ERROR"
    [ "$lvl" -ge 2 ] && fd=12
    if [ "$lvl" -ge "$LOG_LEVEL" ]; then
        _sub_log "$svtxt" "$message" "$fd" "$color"
    fi
}

# shellcheck disable=2317
debug() {
    # shellcheck disable=2116
    log D "$(echo "executing command:" "$@")"
    "$@"
    code="$?"
    if [ "$code" != 0 ]; then
        log D "return code $code"
    fi
}

start_progress_reporter() {
    ip="$1"
    port="$2"
    dummy="$3"
    log I "Starting progress reporter to $ip:$port"
    coproc PROGRESS_COPROC {
        log D "starting nc"
        coproc NC_COPROC {
            if [ "$dummy" ]; then
                while read -r; do true; done
            else
                nc "$ip" "$port"
            fi
        }
        progress="error"
        while read -d $'\0' -r progress; do
            if  [ "$progress" = "done" ] || \
                [[ "$progress" =~ error ]]; then
                break
            fi
            log I "progress: $progress"
            echo "progress $progress" >&"${NC_COPROC[1]}"
        done
        if [ "$progress" = "done" ]; then
            echo "done" >&"${NC_COPROC[1]}"
            log I "progress: done!"
        elif [[ "$progress" =~ error ]]; then
            echo "$progress" >&"${NC_COPROC[1]}"
            log E "reported error: $progress"
        fi
        log D "killing nc"
        kill -SIGKILL "$NC_COPROC_PID"
        wait "$NC_COPROC_PID"
    }

    exec 14>&"${PROGRESS_COPROC[1]}"
}

# shellcheck disable=2317
progress() {
    printf '%s %s\0' "$1" "$2" >&14
}

finish_progress() {
    printf '%s\0' "done" >&14
}

end_coprocs() {
    log D "Waiting for coprocs to stop"
    declare -a pids
    pids=("$STDOUT_COPROC_PID" "$STDERR_COPROC_PID" "$PROGRESS_COPROC_PID" "$INSTALLER_COPROC_PID")
    stop_logger

    for pid in "${pids[@]}"; do
        [ "$pid" ] && wait "$pid"
    done

    for pid in "${pids[@]}"; do
        [ "$pid" ] && kill -SIGKILL "$pid"
    done
}

load_config() {
    file="$CONF_FILE"
    if ! exec 7<"$file"; then
        log E "Failed to load config file"
        return 1
    fi

    while read -ru 7 line; do
        IFS='=' read -ra conf <<< "$line"
        FLASH_CONF["${conf[0]}"]="${conf[1]}"
    done

    FLASH_CONF[file]="$PATHS_RELATIVE_TO/${FLASH_CONF[file]}"

    exec 7<&-
}

# shellcheck disable=2317
progress_transformer() {
    while read -r; do
        progress "$REPLY" "$1"
    done
}

# shellcheck disable=2317
setup_tar() {
    output_device="$1"

    log I "formatting $output_device"
    debug parted -s "$output_device" -- mklabel msdos
    debug parted -s "$output_device" -- mkpart primary ext4 8192s 100%
    loop_device="$(losetup -o $((8192*512)) --find --show "$output_device")"
    debug mkfs.ext4 -F "$loop_device" > /dev/null

    log I "mounting $output_device"
    debug mkdir -p "$MNT_OUTPUT_DIR"
    debug mount "$loop_device" "$MNT_OUTPUT_DIR"
}

# shellcheck disable=2317
finish_tar() {
    output_device="$1"

    if [ -e "$MNT_OUTPUT_DIR/boot.img" ]; then
        debug cp "$MNT_OUTPUT_DIR/boot.img" /tmp/boot.img
        debug rm "$MNT_OUTPUT_DIR/boot.img"
    else
        log W "missing boot.img, device may not boot"
    fi

    if [ -e "$MNT_OUTPUT_DIR/boot/armbianEnv.txt" ]; then
        UUID="$(grep rootdev "$MNT_OUTPUT_DIR/boot/armbianEnv.txt" | sed -e 's|rootdev=UUID=||')"
    else
        log W "could not determine expected rootfs UUID, device may not boot"
        UUID=""
    fi

    debug umount "$MNT_OUTPUT_DIR"

    log I "running fsck"
    debug e2fsck -y -f "$loop_device"
    if [ "$UUID" ]; then
        debug tune2fs -U "$UUID" "$loop_device"
    fi

    if [ -e /tmp/boot.img ]; then
        debug dd if=/tmp/boot.img of="$output_device" skip=1 seek=1 conv=fsync,notrunc
    else
        log W "skipping writing boot.img, device may not boot"
    fi

    log I "closing device"
    debug losetup -d "$loop_device"
    debug sync "$output_device"
}

build_pipeline() {
    input_file="$1"
    output_device="$2"
    file_size=0

    install_command=""
    setup_command=""
    finish_command=""

    if [[ "$input_file" == http* ]]; then
        file_size="$(curl -LsI "$input_file" \
                   | grep -i Content-Length \
                   | awk '{print $2}' \
                   | tr -d '\r')"
        install_command="curl -Ls '$file'"
    else
        install_command="cat '$input_file'"
        file_size="$(wc -c "$input_file" | awk '{print $1}')"
    fi

    if [ -z "$file_size" ] || [ "$file_size" -lt $((1024*1024)) ]; then
        log E "file size is too small ($file_size)"
        return 1
    fi

    install_command+=" | pv -b -n -s '$file_size' 2> >(progress_transformer '$file_size')"
    [[ "$input_file" == *.gz ]] && install_command+=" | gunzip -d"
    if [[ "$input_file" == *.tar || "$input_file" == *.tar.* ]]; then
        install_command+=" | tar xf - -C '$MNT_OUTPUT_DIR' --warning=no-timestamp"
        setup_command="setup_tar '$output_device'"
        finish_command="finish_tar '$output_device'"
    else
        install_command+=" | dd of='$output_device' conv=fsync,notrunc 2> /dev/null"
        finish_command="sync '$output_device'"
    fi
}

do_install() {
    if [ "$setup_command" ]; then
        log I "Setting up"
        debug eval "$setup_command"
    fi
    if [ "$install_command" ]; then
        log I "Installing"
        debug eval "$install_command"
    fi
    if [ "$finish_command" ]; then
        log I "Finishing"
        debug eval "$finish_command"
    fi

    finish_progress
}

wait_for_ip() {
    interface="$1"
    wait_max="$2"
    for _ in $(seq 1 "$wait_max"); do
        if ip -4 -oneline addr show dev "$interface" | grep -v ' 169\.254' > /dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

main() {
    if [ "$UID" != 0 ]; then
        log E "Script is not being run as root, refusing to continue"
        return 1
    fi

    if ! load_config; then
        log E "Failed to load config, refusing to continue"
        return 1
    fi

    if valid_ip_port "${FLASH_CONF[progress_ip]}" "${FLASH_CONF[progress_port]}"; then
        if ! wait_for_ip "$INTERFACE" "$IP_WAIT_MAX"; then
            log E "Failed to get an IP address, refusing to continue"
            return 1
        fi
        start_progress_reporter "${FLASH_CONF[progress_ip]}" "${FLASH_CONF[progress_port]}" 2> /dev/null
    else
        start_progress_reporter "" "" dummy 2> /dev/null
    fi

    if ! build_pipeline "${FLASH_CONF[file]}" "${FLASH_CONF[output]}"; then
        log E "Failed to build pipeline, refusing to continue"
        return 1
    fi

    do_install
}

start_logger
main
code="$?"
end_coprocs
exit $code
