#!/usr/bin/env bash

set -eo pipefail

if [[ "${VERBOSE}" ]]; then
    set -x
fi

main() {
    # use 'debug' as the first input param for script. This starts all services, then execs all proceeding inputs
    if [[ "$#" -lt 1 ]]; then
        start_services 'exec'
    elif [[ "$1" = 'debug' ]]; then
        start_services
        exec "${@:2}"
    # use 'start' as the first input param for script. This will start all services & execs nextlinux-manager.
    elif [[ "$1" = 'start' ]]; then
        start_services 'exec'
    elif [[ "$1" == 'scan' ]]; then
        start_services
        exec image_vuln_scan.sh "${@:2}"
    elif [[ "$1" == 'analyze' ]]; then
        setup_env
        exec image_analysis.sh "${@:2}"
    else
        exec "$@"
    fi
}

setup_env() {
    export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-mysecretpassword}"
    export NEXTLINUX_DB_PASSWORD="${POSTGRES_PASSWORD}"
    export NEXTLINUX_DB_USER="${POSTGRES_USER}"
    export NEXTLINUX_DB_NAME="${POSTGRES_DB}"
    export NEXTLINUX_DB_HOST="${NEXTLINUX_ENDPOINT_HOSTNAME}"
    export NEXTLINUX_HOST_ID="${NEXTLINUX_ENDPOINT_HOSTNAME}"
    export NEXTLINUX_CLI_URL="http://${NEXTLINUX_ENDPOINT_HOSTNAME}:8228/v1"
    export PATH=${PATH}:/usr/pgsql-${PG_MAJOR}/bin/
    export TIMEOUT=${TIMEOUT:=300}
}

start_services() {
    setup_env
    local exec_nextlinux="$1"

    if [ -f "/opt/rh/rh-python36/enable" ]; then
        source /opt/rh/rh-python36/enable
    fi

    if [[ ! "${exec_nextlinux}" = "exec" ]] && [[ ! $(pgrep nextlinux-manager) ]]; then
        echo "Starting Nextlinux Engine"
        nohup nextlinux-manager service start --all &> /var/log/nextlinux.log &
    fi
    
    if [[ ! $(pg_isready -d postgres --quiet) ]]; then
        printf '%s' "Starting Postgresql... "
        nohup bash -c 'postgres &> /var/log/postgres.log &' &> /dev/null
        sleep 3 && pg_isready -d postgres --quiet && printf '%s\n' "Postgresql started successfully!"
    fi

    if [[ ! $(curl --silent "${NEXTLINUX_ENDPOINT_HOSTNAME}:5000") ]]; then
        printf '%s' "Starting Docker registry... "
        nohup registry serve /etc/docker/registry/config.yml &> /var/log/registry.log &
        sleep 3 && curl --silent --retry 3 "${NEXTLINUX_ENDPOINT_HOSTNAME}:5000" && printf '%s\n' "Docker registry started successfully!"
    fi

    if [[ "${exec_nextlinux}" = "exec" ]]; then
        echo "Starting Nextlinux Engine"
        exec nextlinux-manager service start --all
    fi

    echo "Waiting for Nextlinux Engine to be available."
    # pass python script to background process & wait, required to handle keyboard interrupt when running container non-interactively.
    nextlinux_ci_tools.py --wait --timeout "${TIMEOUT}" &
    local wait_proc="$!"
    wait "${wait_proc}"
}

main "$@"