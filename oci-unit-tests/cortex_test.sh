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

readonly CORTEX_PORT=60009

oneTimeSetUp() {
    # Make sure we're using the latest OCI image.
    docker pull --quiet "${DOCKER_IMAGE}" > /dev/null

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
    docker run \
	   --rm \
	   -d \
	   --publish ${CORTEX_PORT}:9009 \
	   --name "${DOCKER_PREFIX}_${suffix}" \
	   "${DOCKER_IMAGE}"
}

wait_cortex_container_ready() {
    local container="${1}"
    local log="creating table"
    wait_container_ready "${container}" "${log}"
}

test_services_status() {
    debug "Creating cortex container"
    container=$(docker_run_cortex)
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_cortex_container_ready "${container}" || return 1

    debug "Check if all the expected services are running"
    local response
    response=$(curl --silent "http://localhost:${CORTEX_PORT}/services")
    assertTrue "Check if memberlist-kv is in the server response"  "echo \"${response}\" | grep -A1 memberlist-kv  | grep -q Running"
    assertTrue "Check if server is in the server response"         "echo \"${response}\" | grep -A1 server         | grep -q Running"
    assertTrue "Check if store is in the server response"          "echo \"${response}\" | grep -A1 store          | grep -q Running"
    assertTrue "Check if table-manager is in the server response"  "echo \"${response}\" | grep -A1 table-manager  | grep -q Running"
    assertTrue "Check if query-frontend is in the server response" "echo \"${response}\" | grep -A1 query-frontend | grep -q Running"
    assertTrue "Check if distributor is in the server response"    "echo \"${response}\" | grep -A1 distributor    | grep -q Running"
    assertTrue "Check if ingester is in the server response"       "echo \"${response}\" | grep -A1 ingester       | grep -q Running"
    assertTrue "Check if ring is in the server response"           "echo \"${response}\" | grep -A1 ring           | grep -q Running"
    assertTrue "Check if querier is in the server response"        "echo \"${response}\" | grep -A1 querier        | grep -q Running"
}

load_shunit2
