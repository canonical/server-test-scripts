# shellcheck shell=dash

ROOTDIR=$(realpath -e "$(dirname "$0")")
export ROOTDIR

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

# Creates a new docker container from $DOCKER_IMAGE.
#
# By default, creates a temporary container running the software under
# test as a daemon service.  The container is automatically removed
# when the daemon exits.  All parameters to run_container_service() are
# passed directly through to the contained software daemon.  The docker
# behavior can be adjusted through environmental variables listed
# below.  In particular, $suffix can be used to distinguish between
# multiple containers used in a given test, such as 'client' and
# 'server'.
#
# Parameters:
#   $@: parameters to pass through to the container
# Environment:
#   $DOCKER_IMAGE: Name of the image containing the software to be tested.
#       Defaults to "docker.io/ubuntu/<package>:edge"
#   $DOCKER_PREFIX: Common prefix for all containers for this test.
#       Defaults to "oci_<package>_test".
#   $DOCKER_NETWORK: User-created network to connect the container to.
#       Defaults to "oci_<package>_test_net".
#   $SUFFIX: Optional tag for ensuring unique container names.
#       Defaults to a random string.
#
# Stdout: Name of created container.
# Returns: Error code from docker, or 0 on success.
run_container_service() {
    SUFFIX=${SUFFIX:-$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)}
    docker run \
       --network "${DOCKER_NETWORK}" \
       --rm \
       -d \
       --name "${DOCKER_PREFIX}_${SUFFIX}" \
       "${DOCKER_IMAGE}" \
       "$@"
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

    sleep 2
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
    sleep 5
    debug "done"
}

# $1: container id
# ${2...}: source package names to be installed
install_container_packages()
{
    local retval=0
    local id="${1}"
    shift

    docker exec -u root "${id}" apt-get -qy update > /dev/null
    for package in "${@}"; do
        debug "Installing ${package} into ${id}"
        if docker exec -u root "${id}" \
               apt-get -qy install "${package}" \
               > /dev/null 2>&1;
        then
            debug "${package} installation succeeded"
        else
            fail "ERROR, failed to install '${package}' into ${id}"
            retval=1
        fi
    done

    return ${retval}
}

# $1: container id
# ${2...}: required manifest files
check_manifest_exists()
{
    local id="${1}"
    shift
    local manifest_dir="/usr/share/rocks"
    local found=""

    # The expected files for each image type.
    local possible_manifest_files="dpkg.query manifest.yaml snapcraft.yaml upstream"
    if [ -n "${1}" ]; then
        local required_manifest_files="dpkg.query ${*}"
    else
        local required_manifest_files="dpkg.query"
    fi

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
                if [ -n "${found}" ]; then
                    found="${found} ${got_file}"
                else
                    found="${got_file}"
                fi
            fi
        done
    done

    if [ -z "${found}" ]; then
        echo "E: No manifest file found in the image" > /dev/stderr
        debug "not found"
        return 1
    else
      debug "Verifying required manifest file(s) presence [${required_manifest_files}]"
        for required_file in ${required_manifest_files}; do
            if ! echo "${found}" | grep -qFw "${required_file}"; then
                echo "E: Required manifest file ${required_file} is missing" > /dev/stderr
                debug "Required manifest file ${required_file} is missing"
                return 1
            fi
        done
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
