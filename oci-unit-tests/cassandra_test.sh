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

readonly CQLSH_DOCKER_IMAGE="cassandra-cqlsh:test"

oneTimeSetUp() {
    id=$$

    # Remove image before test.
    remove_current_image

    # Make sure we're using the latest OCI image.
    docker pull --quiet "${DOCKER_IMAGE}" > /dev/null

    docker network create "$DOCKER_NETWORK" > /dev/null 2>&1

    # build image with cqlsh client
    docker build -t $CQLSH_DOCKER_IMAGE ./cassandra_test_data > /dev/null 2>&1
}

oneTimeTearDown() {
    docker network rm "$DOCKER_NETWORK" > /dev/null 2>&1
    # remove local image with cqlsh client
    docker rmi -f $CQLSH_DOCKER_IMAGE > /dev/null 2>&1
}

tearDown() {
    if [ -n "${container}" ]; then
        stop_container_sync "${container}"
    fi
    if [ -n "${volume}" ]; then
        docker volume rm "${volume}" > /dev/null 2>&1
    fi
}

# Helper function to execute cassandra with some common arguments.
docker_run_server() {
    docker run \
     --network "$DOCKER_NETWORK" \
     --rm \
     -d \
     --name cassandra_test_${id} \
     "$@" \
     "${DOCKER_IMAGE}"
}

# Helper function to execute cqlsh with some common arguments.
docker_run_client() {
    # mount data into the container
    cqlsh_file="$(realpath $(dirname "$0"))/cassandra_test_data/hello-cassandra.cqlsh"
    docker run \
     --network "$DOCKER_NETWORK" \
     --rm \
     -it \
     --name cqlsh_test_${id} \
     -v "${cqlsh_file}":/hello-cassandra.cqlsh \
     "${CQLSH_DOCKER_IMAGE}" \
     cassandra_test_${id} \
     "$@"
}

wait_cassandra_container_ready() {
    local container="${1}"
    local log="Startup complete"
    wait_container_ready "${container}" "${log}" 120
}

test_start_and_connect() {
    container=$(docker_run_server)
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_cassandra_container_ready "${container}" || return 1
    docker_run_client -e "CREATE KEYSPACE mykeyspace WITH REPLICATION = {'class':'SimpleStrategy','replication_factor' : 1};"
    assertTrue "Could not create new keyspace" $?
    docker_run_client -e "CREATE KEYSPACE mykeyspace WITH REPLICATION = {'class':'SimpleStrategy','replication_factor' : 1};" | grep -qF AlreadyExists
    assertTrue "keyspace should be duplicated" $?
}

# Run simple transactions from ./cassandra_test_data
test_run_transactions() {
    container=$(docker_run_server)
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_cassandra_container_ready "${container}" || return 1
    debug "Running transactions"
    docker_run_client -f /hello-cassandra.cqlsh | grep -qF '4.0-rc1'
    assertTrue "Transaction samples failed" $?
}

# Verify that DBs are preserved in persistent volumes
test_persistent_db() {
    debug "Creating persistent volume"
    volume=$(docker volume create)
    container=$(docker_run_server -v "${volume}":/var/lib/cassandra)
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_cassandra_container_ready "${container}" || return 1
    docker_run_client -e "CREATE KEYSPACE persistentkeyspace WITH REPLICATION = {'class':'SimpleStrategy','replication_factor' : 1};"
    docker_run_client -k persistentkeyspace -e "CREATE TABLE oci(id int primary key, name varchar);"
    docker_run_client -k persistentkeyspace -e "INSERT INTO oci (id, name) VALUES (1, 'ubuntu:impish');"
    docker_run_client -k persistentkeyspace -e "SELECT * FROM oci;" | grep -qF 'ubuntu:impish'
    assertTrue "Failed to fetch data from DB" $?
    # stop container, which deletes it because it was launched with --rm
    stop_container_sync "${container}"
    # launch new container with the same volume and verify that the data exists
    debug "Launching new container with same volume"
    container=$(docker_run_server -v "${volume}":/var/lib/cassandra)
    wait_cassandra_container_ready "${container}" || return 1
    docker_run_client -k persistentkeyspace -e "SELECT * FROM oci;" | grep -qF 'ubuntu:impish'
    assertTrue "Data was not persisted" $?
    # stop container, which deletes it because it was launched with --rm
    # then we remove the volume and verify the data is no longer there
    stop_container_sync "${container}"
    docker volume rm "${volume}" > /dev/null 2>&1
    volume=$(docker volume create)
    container=$(docker_run_server -v "${volume}":/var/lib/cassandra)
    wait_cassandra_container_ready "${container}" || return 1
    docker_run_client -k persistentkeyspace -e "SELECT * FROM oci;" | grep -qF 'ubuntu:impish'
    assertFalse "Data was persisted when it shouldn't" $?
}

test_manifest_exists() {
    debug "Testing that the manifest file is available in the image"
    container=$(docker_run_server)

    check_manifest_exists "${container}"
    assertTrue "Manifest file(s) do(es) not exist in image" $?
}

load_shunit2
