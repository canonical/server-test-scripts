# shellcheck shell=dash

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"

# cheat sheet:
#  assertTrue $?
#  assertEquals 1 2
#  oneTimeSetUp()
#  oneTimeTearDown()
#  setUp() - run before each test
#  tearDown() - run after each test

# The name of the temporary docker network we will create for the
# tests.
readonly DOCKER_PREFIX=oci_cortex_test
readonly DOCKER_IMAGE="squeakywheel/cortex:edge"
readonly CORTEX_PORT=60009

oneTimeSetUp() {
    # Make sure we're using the latest OCI image.
    docker pull --quiet "$DOCKER_IMAGE" > /dev/null

    # Cleanup stale resources
    tearDown
}

setUp() {
    suffix=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)
}

tearDown() {
    for container in $(docker ps -a --filter "name=$DOCKER_PREFIX" --format "{{.Names}}"); do
        debug "Removing container ${container}"
        stop_container_sync "${container}"
    done
}

# Helper function to execute cortex.
docker_run_cortex() {
    # The volume and the --config.file extra argument should not be needed but
    # the default config is not good enough to start a container without those
    # options at the moment. More info see LP #1903860.
    docker run \
	   --rm \
	   -d \
	   --publish ${CORTEX_PORT}:9009 \
	   --name "${DOCKER_PREFIX}_${suffix}" \
	   --volume "$PWD/cortex_test_data/cortex.yaml:/etc/cortex/cortex.yaml" \
	   $DOCKER_IMAGE \
           "--config.file=/etc/cortex/cortex.yaml"
}

wait_cortex_container_ready() {
    local container="${1}"
    local log="creating table"
    wait_container_ready "${container}" "${log}"
}

test_services_status() {
    debug "Creating cortex container"
    container=$(docker_run_cortex)
    wait_cortex_container_ready "${container}" || return 1

    debug "Check if all the expected services are running"
    response=$(curl --silent "http://localhost:${CORTEX_PORT}/services")
    assertTrue echo "${response}" | grep -A1 "memberlist-kv"  | grep Running > /dev/null
    assertTrue echo "${response}" | grep -A1 "server"         | grep Running > /dev/null
    assertTrue echo "${response}" | grep -A1 "store"          | grep Running > /dev/null
    assertTrue echo "${response}" | grep -A1 "table-manager"  | grep Running > /dev/null
    assertTrue echo "${response}" | grep -A1 "query-frontend" | grep Running > /dev/null
    assertTrue echo "${response}" | grep -A1 "distributor"    | grep Running > /dev/null
    assertTrue echo "${response}" | grep -A1 "ingester"       | grep Running > /dev/null
    assertTrue echo "${response}" | grep -A1 "ring"           | grep Running > /dev/null
    assertTrue echo "${response}" | grep -A1 "querier"        | grep Running > /dev/null
}

load_shunit2
