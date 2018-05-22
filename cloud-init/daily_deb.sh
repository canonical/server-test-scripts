#!/bin/bash
set -e

VERBOSITY=0
TEMP_D=""
KEEP=false
CONTAINER=""

error() { echo "$@" 1>&2; }
fail() { [ $# -eq 0 ] || error "$@"; exit 1; }
errorrc() { local r=$?; error "$@" "ret=$r"; return $r; }

Usage() {
    cat <<EOF
Usage: ${0##*/} Ubuntu version

    Grab latest daily build of cloud-init.

    options:
      -h | --help     this usage information
      -v | --verbose  increased debug output
EOF
}

bad_Usage() { Usage 1>&2; [ $# -eq 0 ] || error "$@"; return 1; }
cleanup() {
    if [ -n "$CONTAINER" ]; then
        delete_container "$CONTAINER"
    fi
    [ -z "${TEMP_D}" -o ! -d "${TEMP_D}" ] || rm -Rf "${TEMP_D}"
}

debug() {
    local level=${1}; shift;
    [ "${level}" -gt "${VERBOSITY}" ] && return
    error "::" "${@}"
}

inside() {
    local name="$1"
    shift
    debug 2 "executing in $name as root: $*"
    lxc exec "$name" -- env LC_ALL=C LANG=C "$@"
}

start_container() {
    local src="$1" name="$2"
    debug 1 "starting container $name from '$src'"
    lxc launch "$src" "$name" || {
        errorrc "Failed to start container '$name' from '$src'";
        return
    }
    CONTAINER=$name

    local out="" ret=""
    debug 1 "waiting for networking"
    out=$(inside "$name" sh -c '
        i=0
        while [ $i -lt 60 ]; do
            getent hosts archive.ubuntu.com && exit 0
            sleep 2
        done 2>&1')
    ret=$?
    if [ $ret -ne 0 ]; then
        error "Waiting for network in container '$name' failed. [$ret]"
        error "$out"
        return $ret
    fi

    if [ ! -z "${http_proxy-}" ]; then
        debug 1 "configuring proxy ${http_proxy}"
        inside "$name" sh -c "echo 'Acquire::http::Proxy \"${http_proxy}\";' > /etc/apt/apt.conf.d/99_proxy"
    fi
}

delete_container() {
    debug 1 "removing container $1"
    lxc delete --force "$1"
}

main() {
    local short_opts="hv"
    local long_opts="help,verbose"
    local getopt_out=""
    getopt_out=$(getopt --name "${0##*/}" \
        --options "${short_opts}" --long "${long_opts}" -- "$@") &&
        eval set -- "${getopt_out}" ||
        { bad_Usage; return; }

    local cur=""

    while [ $# -ne 0 ]; do
        cur="${1:-}";
        next="$2"
        case "$cur" in
            -h|--help) Usage; exit 0;;
            -v|--verbose) VERBOSITY=$((${VERBOSITY}+1));;
            --) shift; break;;
        esac
        shift;
    done

    [ $# -eq 1 ] || { bad_Usage "ERROR: Must provide a release!"; return; }
    release="$1"

    TEMP_D=$(mktemp -d "${TMPDIR:-/tmp}/${0##*/}.XXXXXX") ||
        fail "failed to make tempdir"
    trap cleanup EXIT

    # program starts here
    local uuid="" name=""
    uuid=$(uuidgen -t) || { error "no uuidgen"; return 1; }
    name="cloud-init-ubuntu-daily-ppa-${uuid%%-*}"

    start_container "ubuntu-daily:$release" "$name"

    debug 1 "adding cloud-init daily PPA"
    inside "$name" add-apt-repository --yes ppa:cloud-init-dev/daily ||
        fail "failed: adding cloud-init daily PPA"

    inside "$name" apt-get update ||
        fail "failed: apt-get update"

    debug 1 "downloading from PPA"
    inside "$name" apt-get download cloud-init ||
        fail "failed: apt-get download cloud-init"

    file=$(inside "$name" ls /root/) ||
        fail "failed: ls"

    debug 1 "pulling cloud-init deb"
    lxc file pull "$name"/root/"$file" . ||
        fail "failed: pull file"

    echo "Download successful!"

    return 0
}

main "$@"
# vi: ts=4 expandtab
