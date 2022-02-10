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

readonly LOCAL_PORT=63180

oneTimeSetUp() {
    # Remove image before test.
    remove_current_image

    # Make sure we're using the latest OCI image.
    docker pull --quiet "${DOCKER_IMAGE}" > /dev/null

    # Cleanup stale resources
    tearDown
}

tearDown() {
    for container in $(docker ps --filter "name=$DOCKER_PREFIX" --format "{{.Names}}"); do
        debug "Removing container ${container}"
        stop_container_sync "${container}"
    done
}

docker_run_server() {
    suffix=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)
    docker run \
       --rm \
       -d \
       --name "${DOCKER_PREFIX}_${suffix}" \
       "$@" \
       "${DOCKER_IMAGE}"
}

wait_grafana_container_ready() {
    local container="${1}"
    local log="HTTP Server Listen"
    wait_container_ready "${container}" "${log}"
}

check_login_page() {
    local page_addr="${1}"
    LOGIN_PAGE=$(curl -Ss http://"${page_addr}":"${LOCAL_PORT}"/login)
    EXPECT="<title>Grafana</title>"
    echo "${LOGIN_PAGE}" | grep -Fq "${EXPECT}"
    assertTrue "${EXPECT} not found in login page:\n${LOGIN_PAGE}" $?
}

test_default_config() {
    debug "Creating all-defaults Grafana container"
    container=$(docker_run_server -p "$LOCAL_PORT:3000")

    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_grafana_container_ready "${container}" || return 1

    docker exec "$container" pgrep grafana-server > /dev/null
    assertTrue "Could not find processes for grafana-server" $?

    # Without Javascript the web UI doesn't do much. 
    check_login_page "127.0.0.1"
}

test_default_config_ipv6() {
    debug "Creating all-defaults Grafana container"
    container=$(docker_run_server -p "$LOCAL_PORT:3000")

    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_grafana_container_ready "${container}" || return 1

    check_login_page "[::1]"
}

test_persistent_storage() {
    grafana_scratch=$(mktemp -d /tmp/grafana-XXXXXXXX)

    debug "Creating Grafana container with persistent storage"
    uid=$(id -u)
    container=$(docker_run_server --user "$uid" -p "$LOCAL_PORT:3000" -v "$grafana_scratch:/var/lib/grafana")

    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_grafana_container_ready "${container}" || return 1

    check_login_page "127.0.0.1"

    debug "Shutting down container"
    stop_container_sync "${container}"

    debug "Check database is in persistent storage"
    assertTrue "test -f '$grafana_scratch/grafana.db'"

    debug "Starting Grafana container with same persistent storage"
    container=$(docker_run_server --user "$uid" -p "$LOCAL_PORT:3000" -v "$grafana_scratch:/var/lib/grafana")
    wait_grafana_container_ready "${container}" || return 1

    check_login_page "127.0.0.1"

    # Cleanup
    rm -rf "$grafana_scratch"
}

test_manifest_exists() {
    debug "Testing that the manifest file is available in the image"
    container=$(docker_run_server)

    check_manifest_exists "${container}" manifest.yaml snapcraft.yaml
    assertTrue "Manifest file(s) do(es) not exist or is(are) empty in image" $?
}

load_shunit2
