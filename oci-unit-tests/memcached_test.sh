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
    # Make sure we're using the latest OCI image.
    docker pull --quiet "${DOCKER_IMAGE}" > /dev/null

    # Cleanup stale resources
    tearDown
    oneTimeTearDown

    # Setup network
    docker network create "$DOCKER_NETWORK" > /dev/null 2>&1
}

oneTimeTearDown() {
        docker network rm "$DOCKER_NETWORK" > /dev/null 2>&1
}

tearDown() {
    for container in $(docker ps --filter "name=$DOCKER_PREFIX" --format "{{.Names}}"); do
        debug "Removing container ${container}"
        stop_container_sync "${container}"
    done
}

docker_run_server() {
    local suffix=${suffix:-$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)}
    docker run \
       --network "$DOCKER_NETWORK" \
       --rm \
       -d \
       --name "${DOCKER_PREFIX}_${suffix}" \
       "${DOCKER_IMAGE}" \
       memcached \
       "$@"
}

test_local_connection() {
    debug "Creating all-defaults memcached container"
    container=$(docker_run_server)
    assertNotNull "Failed to start the container" "${container}" || return 1

    docker exec "$container" /usr/share/memcached/scripts/memcached-tool 127.0.0.1:11211 > /dev/null
    assertTrue $?
}

test_network_connection() {
    debug "Creating all-defaults memcached container (server)"
    container_server=$(suffix=server docker_run_server --listen=0.0.0.0)
    assertNotNull "Failed to start the container" "${container_server}" || return 1

    debug "Creating all-defaults memcached container (client)"
    container_client=$(suffix=client docker_run_server)
    assertNotNull "Failed to start the container" "${container_client}" || return 1

    docker exec "$container_client" /usr/share/memcached/scripts/memcached-tool "${DOCKER_PREFIX}_server:11211" > /dev/null
    assertTrue $?
}

test_custom_flags() {
    debug "Creating all-defaults memcached container"
    container=$( \
        docker_run_server \
        --memory-limit=42 \
        --enable-shutdown \
        --listen=0.0.0.0 \
        --max-reqs-per-event=10 \
        --port=22122 \
        --udp-port=11211 \
        --disable-evictions \
        --enable-coredumps \
        --disable-cas \
        --enable-largepages \
        --disable-flush-all \
        --disable-dumping \
    )
    assertNotNull "Failed to start the container" "${container}" || return 1

    docker exec "$container" /usr/share/memcached/scripts/memcached-tool 127.0.0.1:22122 > /dev/null
    assertTrue $?
}

test_libmemcached_compliance() {
    debug "Creating all-defaults memcached container (server)"
    container_server=$(suffix=server docker_run_server --listen=0.0.0.0)
    assertNotNull "Failed to start the container" "${container_server}" || return 1

    debug "Creating memcached container with libmemcached-tools"
    container_client=$(suffix=client docker_run_server)
    assertNotNull "Failed to start the container" "${container_client}" || return 1
    docker exec -u root "$container_client" apt-get -qy update
    docker exec -u root "$container_client" apt-get -qy --option=Dpkg::options::=--force-unsafe-io install libmemcached-tools

    docker exec "$container_client" memcping --servers="${DOCKER_PREFIX}_server"
    assertTrue $?
    docker exec "$container_client" memccat --servers="${DOCKER_PREFIX}_server"
    assertTrue $?
    docker exec "$container_client" memcflush --servers="${DOCKER_PREFIX}_server"
    assertTrue $?
    docker exec "$container_client" memcslap --servers="${DOCKER_PREFIX}_server"
    assertTrue $?
}

test_data_storage_and_retrieval() {
    debug "Creating all-defaults memcached container (server)"
    container_server=$(suffix=server docker_run_server --listen=0.0.0.0)
    assertNotNull "Failed to start the container" "${container_server}" || return 1

    debug "Creating memcached container (client)"
    container_client=$(suffix=client docker_run_server)
    assertNotNull "Failed to start the container" "${container_client}" || return 1

    debug "Installing libmemcached-tools"
    docker exec -u root "$container_client" apt-get -q update
    docker exec -u root "$container_client" apt-get -qy --option=Dpkg::options::=--force-unsafe-io install libmemcached-tools

    debug "Running store/retrieve test"
    data="test data"
    docker exec "$container_client" sh -c "echo '$data' > /tmp/test_data"
    docker exec "$container_client" memccp --servers="${DOCKER_PREFIX}_server" /tmp/test_data
    retr_data=$(docker exec "$container_client" memccat --servers="${DOCKER_PREFIX}_server" test_data)
    assertEquals "Store/retrieve data" "$data" "$retr_data"
}

load_shunit2
