#!/usr/bin/env bash

path_input() {
    given=$1
    prompt=$2
    check_command=$3

    while [ -z "$given" -o ! -e "$given" ]; do
        if [ "$_inp" = droptoshell ]; then
            bash
        else
            echo "$_inp does not exist! Type droptoshell to get access to the shell"
        fi

        eval $check_command

        echo -n $2
        read _inp
    done
}
