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

readonly DOCKER_PREFIX=oci_telegraf_test
readonly DOCKER_IMAGE="squeakywheel/telegraf:edge"
readonly TELEGRAF_PORT=9273

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

# Helper function to execute telegraf.
docker_run_telegraf() {
    docker run \
	   --rm \
	   -d \
	   --name "${DOCKER_PREFIX}_${suffix}" \
	   "$@" \
	   $DOCKER_IMAGE
}

wait_telegraf_container_ready() {
    local container="${1}"
    local log="\[agent\] Config: Interval:.+, Quiet:.+, Hostname:.+"
    wait_container_ready "${container}" "${log}"
}

# Verify that telegraf is up and running.
test_telegraf_up() {
    debug "Creating telegraf container"
    container=$(docker_run_telegraf)
    wait_telegraf_container_ready "${container}" || return 1

    debug "Verifying that we can access the web endpoint"
    local metrics
    metrics=$(curl --silent "http://localhost:${TELEGRAF_PORT}/metrics")
    assertTrue echo "${metrics}" | grep -q diskio || return 1
    assertTrue echo "${metrics}" | grep -q inodes || return 1
    assertTrue echo "${metrics}" | grep -q cpu || return 1
}

# Verify that using a custom configuration file works, and that
# telegraf can properly write its metrics to an http endpoint.
test_telegraf_custom_config_http_endpoint() {
    debug "Creating telegraf container with custom config, writing to http endpoint"

    # We have to start the container using the host's network,
    # otherwise we won't be able to listen to it.
    #
    # FIXME: Obtain host's internal IP, and make telegraf write
    # directly to it.  Windows/Mac accept "host.docker.internal", but
    # GNU/Linux doesn't.
    container=$(docker_run_telegraf \
		    --network=host \
		    -v "$PWD"/telegraf_test_data/telegraf.conf:/etc/telegraf/telegraf.conf)
    wait_telegraf_container_ready "${container}" || return 1

    # Listen to telegraf.
    local data
    # We have to use "timeout" here because otherwise "nc" will keep
    # listening to the port.
    data="$(timeout 5s nc -q 0 -w 20 -l -p 8080)"
    assertTrue echo "${data}" | grep -q diskio || return 1
    assertTrue echo "${data}" | grep -q inodes || return 1
    assertTrue echo "${data}" | grep -q cpu || return 1
}

load_shunit2
