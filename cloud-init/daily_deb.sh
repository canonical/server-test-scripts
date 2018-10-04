#!/bin/bash
set -e

VERBOSITY=0

error() { echo "$@" 1>&2; }
fail() { [ $# -eq 0 ] || error "$@"; exit 1; }

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

download() {
    add-apt-repository --yes ppa:cloud-init-dev/daily ||
        fail "Failed to add repo ppa:cloud-init-dev/daily"
    apt-get update --quiet ||
        fail "Failed apt-get update"
    mkdir download || fail "failed mkdir download in $PWD"
    cd download
    apt-get download cloud-init ||
        fail "Failed apt-get download cloud-init"
}

get_ctool() {
    local url="https://raw.githubusercontent.com/CanonicalLtd/uss-tableflip/master/scripts/ctool"
    wget "$url" -O "$1.$$" && chmod 755 "$1.$$" && mv "$1.$$" "$1"
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

    # program starts here
    local uuid="" name=""
    uuid=$(uuidgen -t) || { error "no uuidgen"; return 1; }
    name="cloud-init-ubuntu-daily-ppa-${uuid%%-*}"

    get_ctool "./ctool"

    rm -Rf download || { error "failed removing download/"; return 1; }
    set -- \
        ./ctool run-container --verbose --destroy "--name=$name" \
        --as-root --artifacts=. "--copy-out=download/" \
        --boot-wait=120 \
        -- "ubuntu-daily:$release" bash -s download
    error "executing: $* <'$0'"
    "$@" < "$0" || fail "failed executing $* < '$0'"
    error "created in download: $(cd download && echo *)"
    mv download/*.deb . || fail "failed moving output to . no debs?"
    rmdir download || fail "unexpected artifacts in download: $(ls download)"
    return 0
}

if [ "$1" = "download" ]; then
    download "$@"
    exit
fi
main "$@"
# vi: ts=4 expandtab
