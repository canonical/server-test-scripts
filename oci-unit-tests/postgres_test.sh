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
    image="${DOCKER_IMAGE}"
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

wait_postgres_container_ready() {
    local container="${1}"
    local log="\[1\] LOG:\s*database system is ready to accept connections"
    wait_container_ready "${container}" "${log}"
}

test_set_admin_user() {
# POSTGRES_USER
# This optional environment variable is used in conjunction with
# POSTGRES_PASSWORD to set a user and its password. This variable will create
# the specified user with superuser power and a database with the same name. If
# it is not specified, then the default user of postgres will be used.
    admin_user="user${id}"
    debug "Creating container with POSTGRES_USER=${admin_user}"
    container=$(docker run \
        --network "$DOCKER_NETWORK" \
        --rm -d \
        -e POSTGRES_USER=${admin_user} \
        -e POSTGRES_PASSWORD="${password}" \
        -p 5432:5432 \
        --name postgres_test_${id} \
        "${image}" \
    )
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_postgres_container_ready "${container}" || return 1
    debug "Testing connection as ${admin_user}, looking for \"postgres\" DB"
    # default db is still "postgres"
    out=$(docker run \
              --network "$DOCKER_NETWORK" \
              --rm \
              "${image}" \
              psql "postgresql://${admin_user}:${password}@postgres_test_${id}" -q -l -A -t -F % | grep "^postgres" | cut -d % -f 1)
    assertEquals "DB listing did not include \"postgres\"" postgres "${out}" || return 1
    # Verify we can create a new DB, since we are an admin
    test_db="test_db${id}"
    debug "Trying to create a new DB called ${test_db} as user ${admin_user}"
    docker run \
        --network "$DOCKER_NETWORK" \
        --rm \
        "${image}" \
        psql "postgresql://${admin_user}:${password}@postgres_test_${id}" -q -c \
        "CREATE DATABASE ${test_db};"
    # list DB
    debug "Verifying DB ${test_db} was created"
    out=$(docker run \
              --network "$DOCKER_NETWORK" \
              --rm \
              "${image}" \
              psql "postgresql://${admin_user}:${password}@postgres_test_${id}" -q -l -A -t -F % | grep "^${test_db}" | cut -d % -f 1)
    assertEquals "DB listing did not include \"postgres\"" "${test_db}" "${out}" || return 1
}

test_default_database_name() {
# POSTGRES_DB
# This optional environment variable can be used to define a different name for
# the default database that is created when the image is first started. If it
# is not specified, then the value of POSTGRES_USER will be used.
    test_db="database${id}"
    debug "Creating container with POSTGRES_DB=${test_db}"
    container=$(docker run \
        --network "$DOCKER_NETWORK" \
        --rm -d \
        -e POSTGRES_DB=${test_db} \
        -e POSTGRES_PASSWORD="${password}" \
        -p 5432:5432 \
        --name postgres_test_${id} \
        "${image}" \
    )
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_postgres_container_ready "${container}" || return 1
    debug "Checking if database ${test_db} was created"
    out=$(docker run \
              --network "$DOCKER_NETWORK" \
              --rm \
              "${image}" \
              psql "postgresql://postgres:${password}@postgres_test_${id}" -q -l -A -t -F % | grep "^${test_db}" | cut -d % -f 1)
    assertEquals "Failed to create test database" "${test_db}" "${out}" || return 1
}

test_persistent_volume_keeps_changes() {
# Verify that a container launched with a volume that already has a DB in it
# won't re-initialize it, thus preserving the data.
    debug "Creating persistent volume"
    volume=$(docker volume create)
    assertNotNull "Failed to create a volume" "${volume}" || return 1
    debug "Launching container"
    container=$(docker run \
        --network "$DOCKER_NETWORK" \
        --rm -d \
        -e POSTGRES_PASSWORD="${password}" \
        -p 5432:5432 \
        --mount source="${volume}",target=/var/lib/postgresql/data \
        --name postgres_test_${id} \
        "${image}" \
    )
    assertNotNull "Failed to start the container" "${container}" || return 1
    # wait for it to be ready
    wait_postgres_container_ready "${container}" || return 1

    # Create test database
    test_db="test_db_${id}"
    debug "Creating test database ${test_db}"
    docker run \
        --network "$DOCKER_NETWORK" \
        --rm \
        "${image}" \
        psql "postgresql://postgres:${password}@postgres_test_${id}/postgres" -q -c \
        "CREATE DATABASE ${test_db};"
    out=$(docker run \
              --network "$DOCKER_NETWORK" \
              --rm \
              "${image}" \
              psql "postgresql://postgres:${password}@postgres_test_${id}" -q -l -A -t -F % | grep "^${test_db}" | cut -d % -f 1)
    assertEquals "Failed to create test database" "${test_db}" "${out}" || return 1

    # create test table
    test_table="test_data_${id}"
    debug "Creating test table ${test_table} with data"
    docker run \
        --network "$DOCKER_NETWORK" \
        --rm \
        "${image}" \
        psql "postgresql://postgres:${password}@postgres_test_${id}/${test_db}" -q -c \
        "CREATE TABLE ${test_table} (id INT, description TEXT); INSERT INTO ${test_table} (id,description) VALUES (${id}, 'hello');"
    out=$(docker run \
              --network "$DOCKER_NETWORK" \
              --rm \
              "${image}" \
              psql -F % -A -t "postgresql://postgres:${password}@postgres_test_${id}/${test_db}" -q -c \
              "SELECT * FROM ${test_table};")
    assertEquals "Failed to verify test table" "${id}%hello" "${out}" || return 1

    # stop container, which deletes it because it was launched with --rm
    stop_container_sync "${container}"
    # launch another one with the same volume, and the data we created above
    # must still be there
    # By using the same --name also makes sure the previous container is really
    # gone, otherwise the new one wouldn't start
    debug "Launching new container with same volume"
    container=$(docker run \
        --network "$DOCKER_NETWORK" \
        --rm -d \
        -p 5432:5432 \
        --mount source="${volume}",target=/var/lib/postgresql/data \
        --name postgres_test_${id} \
        "${image}" \
    )
    ready_log="database system is ready to accept connections"
    wait_container_ready "${container}" "${ready_log}"
    # data we created previously should still be there
    debug "Verifying database ${test_db} and table ${test_table} are there with our data"
    out=$(docker run \
              --network "$DOCKER_NETWORK" \
              --rm \
              "${image}" \
              psql -F % -A -t "postgresql://postgres:${password}@postgres_test_${id}/${test_db}" -q -c \
              "SELECT * FROM ${test_table};")
    assertEquals "Failed to verify test table" "${id}%hello" "${out}" || return 1
}

load_shunit2

