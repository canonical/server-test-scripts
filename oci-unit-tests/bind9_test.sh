# shellcheck shell=dash

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"
. "$(dirname "$0")/helper/common_vars.sh"

# cheat sheet:
#  assertTrue $?
#  assertEquals ["explanation"] 1 2
#  oneTimeSetUp()
#  oneTimeTearDown()
#  setUp() - run before each test
#  tearDown() - run after each test

oneTimeSetUp() {
    # Remove image before test.
    remove_current_image

    # Make sure we're using the latest OCI image.
    docker pull --quiet "${DOCKER_IMAGE}" > /dev/null 2>&1

    # Cleanup stale resources
    tearDown
    oneTimeTearDown

    # Setup network
    docker network create "${DOCKER_NETWORK}" > /dev/null 2>&1
}

oneTimeTearDown() {
    docker network rm "${DOCKER_NETWORK}" > /dev/null 2>&1
}

tearDown() {
    local container

    for container in $(docker ps --filter "name=${DOCKER_PREFIX}" --format "{{.Names}}"); do
        debug "Removing container ${container}"
        stop_container_sync "${container}"
    done
}

wait_bind9_container_ready() {
    local container="${1}"
    local log="running"
    wait_container_ready "${container}" "${log}"
}


test_local_connection() {
    local container

    debug "Creating all-defaults bind9 container"
    container=$(run_container_service)
    assertNotNull "Failed to start the container" "${container}" || return 1

    wait_bind9_container_ready "${container}" || return 1

    debug "Installing test dependencies locally"
    install_container_packages "${container}" "lsof" || return 1

    debug "Checking for service on local port 53"
    docker exec "${container}" lsof -i:53 | grep -q LISTEN

    assertTrue ${?}
}

test_network_connection() {
    local container_server
    local container_client

    debug "Creating all-defaults bind9 container (server)"
    container_server=$(SUFFIX=server run_container_service)
    assertNotNull "Failed to start the container" "${container_server}" || return 1

    # Wait for server to be ready
    wait_bind9_container_ready "${container_server}" || return 1

    debug "Creating all-defaults bind9 container (client)"
    container_client=$(SUFFIX=client run_container_service)
    assertNotNull "Failed to start the container" "${container_client}" || return 1

    # Wait for client to be ready
    wait_bind9_container_ready "${container_client}" || return 1

    debug "Installing test dependencies (client)"
    install_container_packages "${container_client}" "bind9-dnsutils" || return 1

    # Use dig from the client to the server's IP
    debug "Querying DNS server"
    docker exec "${container_client}" dig "@${DOCKER_PREFIX}_server" -p 53 ubuntu.com > /dev/null
    assertTrue ${?}
}

test_manifest_exists() {
    local container

    debug "Testing that the manifest file is available in the image"
    container=$(run_container_service)

    check_manifest_exists "${container}"
    assertTrue "Manifest file(s) do(es) not exist in image" ${?}
}

load_shunit2
