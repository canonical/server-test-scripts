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

    docker network create "$DOCKER_NETWORK" > /dev/null 2>&1
}

setUp() {
    password=$(dd if=/dev/urandom bs=1 count=16 2>/dev/null | md5sum | head -c 16)
    id=$$
}

oneTimeTearDown() {
    docker network rm "$DOCKER_NETWORK" > /dev/null 2>&1
}

tearDown() {
    if [ -n "${container}" ]; then
        stop_container_sync "${container}"
    fi
    if [ -n "${volume}" ]; then
        docker volume rm "${volume}" > /dev/null 2>&1
    fi
}

# Helper function to execute redis-server with some common arguments.
# It accepts extra arguments that are then passed to redis-server.
docker_run_server() {
    docker run \
	   --network "$DOCKER_NETWORK" \
	   --rm \
	   -d \
	   --name redis_test_${id} \
	   "$@" \
	   "${DOCKER_IMAGE}"
}

# Helper function to execute redis-cli with some common arguments.  It
# will automatically connect to the redis-server instance running at
# redis_test_${id}.  It also accepts extra arguments that are passed
# to redis-cli.
docker_run_cli() {
    docker run \
	   --network "$DOCKER_NETWORK" \
	   --rm \
	   -i \
	   "${DOCKER_IMAGE}" \
	   redis-cli -h redis_test_${id} "$@"
}

wait_redis_container_ready() {
    local container="${1}"
    local log="Ready to accept connections"
    wait_container_ready "${container}" "${log}"
}

# Test invoking a container with ALLOW_EMPTY_PASSWORD=yes and then
# connecting to it.
test_start_and_connect_container_without_password() {
    debug "Creating container without password"
    container=$(docker_run_server -e ALLOW_EMPTY_PASSWORD=yes)

    assertNotNull "Failed to start the container (without password)" "${container}" || return 1
    wait_redis_container_ready "${container}" || return 1

    debug "Testing connection to container without password"
    out=$(docker_run_cli \
	      ping | grep "^PONG")
    assertEquals "Pinging redis-server (without password) succeeded" "PONG" "${out}" || return 1
}

# Test invoking a container providing a password for it and then
# connecting to it.
test_start_and_connect_container_with_password() {
    debug "Creating container with password"
    container=$(docker_run_server \
		    -e REDIS_PASSWORD="${password}")

    assertNotNull "Failed to start the container (with password)" "${container}" || return 1
    wait_redis_container_ready "${container}" || return 1

    debug "Testing connection to container with password"
    out=$(cat <<EOF | docker_run_cli  | grep "^PONG"
auth ${password}
ping
EOF
	  )
    assertEquals "Pinging redis-server (with password) succeeded" "PONG" "${out}" || return 1
}

# Test the insertion and retrieval of values.
test_insert_retrieve_values() {
    debug "Creating container with password to test insertion/retrieval of values"
    container=$(docker_run_server \
		    -e REDIS_PASSWORD="${password}")

    assertNotNull "Failed to start the container (with password) to test insertion/retrieval of values" "${container}" || return 1
    wait_redis_container_ready "${container}" || return 1

    debug "Inserting values into the database"
    out=$(cat <<EOF | docker_run_cli | grep "^OK" | uniq
auth ${password}
set foo 100
set bar 200
EOF
	  )
    assertEquals "Insertion of values into the database worked" "OK" "${out}" || return 1

    debug "Retrieving values from the database"
    out=$(cat <<EOF | docker_run_cli | grep '^[0-9]' | tr '\n' ' '
auth ${password}
get foo
get bar
EOF
       )
    assertEquals "Retrieval of values from the database succeeded" "100 200 " "${out}" || return 1
}

# Test setting a persistent volume to a redis-server container,
# inserting some data into the database, deleting the initial
# redis-server container, creating a new redis-server container
# attached to the same persistent volume, and verifying that the data
# is still present in the database.
test_persistent_volume_keeps_changes() {
# Verify that a container launched with a volume that already has a DB in it
# won't re-initialize it, thus preserving the data.
    debug "Creating persistent volume"
    volume=$(docker volume create)
    assertNotNull "Failed to create a volume" "${volume}" || return 1
    debug "Launching container (with volume)"
    container=$(docker_run_server \
		    -e REDIS_PASSWORD="${password}" \
		    --mount source="${volume}",target=/var/lib/redis)
    assertNotNull "Failed to start the container (with volume)" "${container}" || return 1
    # wait for it to be ready
    wait_redis_container_ready "${container}" || return 1

    # Populate the database
    debug "Inserting values into the database (with volume)"
    out=$(cat <<EOF | docker_run_cli | grep "^OK" | uniq
auth ${password}
set foo 100
set bar 200
EOF
	  )
    assertEquals "Insertion of values into the database (with volume) worked" "OK" "${out}" || return 1

    debug "Retrieving values from the database (with volume)"
    out=$(cat <<EOF | docker_run_cli | grep '^[0-9]' | tr '\n' ' '
auth ${password}
get foo
get bar
EOF
       )
    assertEquals "Retrieval of values from the database (with volume) succeeded" "100 200 " "${out}" || return 1

    # stop container, which deletes it because it was launched with --rm
    debug "Stopping (i.e., deleting) the container (with volume)"
    stop_container_sync "${container}"
    # launch another one with the same volume, and the data we created above
    # must still be there
    # By using the same --name also makes sure the previous container is really
    # gone, otherwise the new one wouldn't start
    debug "Launching second container (with volume)"
    container=$(docker_run_server \
		    -e REDIS_PASSWORD="${password}" \
		    --mount source="${volume}",target=/var/lib/redis)
    assertNotNull "Failed to start the second container (with volume)" "${container}" || return 1
    # wait for it to be ready
    wait_redis_container_ready "${container}" || return 1

    # data we created previously should still be there
    debug "Retrieving values from the second container's database (with volume)"
    out=$(cat <<EOF | docker_run_cli | grep '^[0-9]' | tr '\n' ' '
auth ${password}
get foo
get bar
EOF
       )
    assertEquals "Retrieval of values from the second container's database (with volume) succeeded" "100 200 " "${out}" || return 1
}

load_shunit2
