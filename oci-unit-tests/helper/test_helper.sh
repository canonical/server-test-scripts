# shellcheck shell=dash

PATH="$(dirname "$0")/..:$PATH"
ROOTDIR="$(dirname "$0")/.."
export PATH ROOTDIR

load_shunit2() {
  if [ -e /usr/share/shunit2/shunit2 ]; then
    # shellcheck disable=SC1091
    . /usr/share/shunit2/shunit2
  else
    # shellcheck disable=SC1091
    . shunit2
  fi
}

debug() {
    if [ -n "${DEBUG_TESTS}" ]; then
        if [ "${1}" = "-n" ]; then
            shift
            echo -n "$@"
        else
            echo "$@"
        fi
    fi
}

# $1: container id
# $2: timeout (optional).  If not specified, defaults to 10 seconds
stop_container_sync() {
    local id=${1}
    local timeout="${2:-10}"
    local max=$timeout

    docker container stop "${id}" > /dev/null 2>&1
    while docker container ls --no-trunc 2>&1 | grep -q "${id}"; do
        sleep 1
        timeout=$((timeout-1))
        if [ "$timeout" -le 0 ]; then
            fail "ERROR, failed to stop container ${id} in ${max} seconds"
            return 1
        fi
    done
}

# $1: container id
# $2: last message to look for in logs
# $3: timeout (optional).  If not specified, defaults to 30 seconds
wait_container_ready() {
    local id="${1}"
    local msg="${2}"
    local timeout="${3:-30}"
    local logs
    local max=${timeout}

    debug -n "Waiting for container to be ready "
    logs=$(docker logs "${id}" --tail 1 2>&1)
    while ! echo "${logs}" | grep -qE "${msg}"; do
        debug -n "."
        sleep 1
		timeout=$((timeout-1))
        if [ "${timeout}" -le 0 ]; then
            fail "ERROR, failed to start container ${id} in ${max} seconds"
            return 1
        fi
        logs=$(docker logs "${id}" --tail 1 2>&1)
    done
    debug
}
