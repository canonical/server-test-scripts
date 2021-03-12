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

readonly ALERTMANAGER_PORT=60001

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

# Helper function to execute alertmanager.
docker_run_alertmanager() {
    docker run \
	   --rm \
	   -d \
	   --publish ${ALERTMANAGER_PORT}:9093 \
	   --name "${DOCKER_PREFIX}_${suffix}" \
	   "${DOCKER_IMAGE}"
}

wait_alertmanager_container_ready() {
    local container="${1}"
    local log="Listening address=:9093"
    wait_container_ready "${container}" "${log}"
}

test_fire_an_alert() {
    debug "Creating alertmanager container"
    container=$(docker_run_alertmanager)
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_alertmanager_container_ready "${container}" || return 1

    debug "Triggering alert"
    data=$(cat <<EOF
{
  "status": "firing",
  "labels": {
    "alertname": "my_testing_alert",
    "service": "test_service",
    "severity": "warning",
    "instance": "fake_instance"
  },
  "annotations": {
    "summary": "This is the summary",
    "description": "This is the description."
  },
  "generatorURL": "https://fake_instance.example/metrics",
  "startsAt": "2020-08-11T16:00:00+00:00"
}
EOF
)

    debug "Check if the alert was successfully fired"
    response=$(curl --silent --request POST "http://localhost:${ALERTMANAGER_PORT}/api/v1/alerts" --data "[$data]")
    assertTrue echo "${response}" | grep success >/dev/null
}

load_shunit2
