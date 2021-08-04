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
# $3: timeout (optional).  If not specified, defaults to 60 seconds
wait_container_ready() {
    local id="${1}"
    local msg="${2}"
    local timeout="${3:-60}"
    local max=$timeout

    debug -n "Waiting for container to be ready "
    while ! docker logs "${id}" 2>&1 | grep -qE "${msg}"; do
	sleep 1
	timeout=$((timeout - 1))
	if [ $timeout -le 0 ]; then
	    fail "ERROR, failed to start container ${id} in ${max} seconds"
	    echo "Current container list (docker ps):"
	    docker ps
	    return 1
	fi
	debug -n "."
    done
    debug "done"
}

# $1: container id
check_manifest_exists()
{
    local id="${1}"
    local manifest_dir="/usr/share/rocks"
    local found=0

    # The expected files for each image type.
    local possible_manifest_files="dpkg.query manifest.yaml snapcraft.yaml upstream"

    debug -n "Listing the manifest file(s) inside ${id}"
    local files
    if ! files=$(docker exec "${id}" ls "${manifest_dir}" 2> /dev/null); then
	debug "not found"
	return 1
    fi
    debug "done"

    debug "Verifying whether the manifest file(s) exist"
    for want_file in ${possible_manifest_files}; do
	for got_file in ${files}; do
	    if [ "${got_file}" = "${want_file}" ]; then
		debug "found ${got_file}"
		found=1
	    fi
	done
    done

    if [ "${found}" -eq 0 ]; then
        echo "E: No manifest file found in the image" > /dev/stderr
        debug "not found"
        return 1
    fi

    debug "Verifying that the manifest file(s) is(are) not empty"
    for file in ${files}; do
        fsize=$(docker exec "${id}" stat -c '%s' "${manifest_dir}/${file}" 2> /dev/null)
        if [ "${fsize}" -eq 0 ]; then
            echo "E: Manifest file ${file} is empty" > /dev/stderr
            debug "file ${file} is empty"
            return 1
        else
            debug "file ${file} has ${fsize} bytes"
        fi
    done

    return 0
}

# Remove the current image.
# This is useful before starting a test, in order to make sure that
# we're using the latest image available to us.
remove_current_image()
{
    # Remove the current downloaded image.  Just do it if the image
    # spec (${DOCKER_IMAGE}) starts with ${DOCKER_REGISTRY}, because
    # we don't want to remove locally built images.
    if echo "${DOCKER_IMAGE}" | grep -q "^${DOCKER_REGISTRY}"; then
        docker image rm --force "${DOCKER_IMAGE}" > /dev/null 2>&1
    fi
}
