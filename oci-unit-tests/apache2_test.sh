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

readonly LOCAL_PORT=59080

oneTimeSetUp() {
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

wait_apache2_container_ready() {
    local container="${1}"
    local log="apache2"
    wait_container_ready "${container}" "${log}"
}

test_default_config() {
    debug "Creating all-defaults apache2 container"
    container=$(docker_run_server -p "$LOCAL_PORT:80")

    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_apache2_container_ready "${container}" || return 1

    assertTrue "curl -sS http://127.0.0.1:$LOCAL_PORT | grep -Fq 'It works!'"
}

test_default_config_ipv6() {
    debug "Creating all-defaults apache2 container"
    container=$(docker_run_server -p "$LOCAL_PORT:80")

    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_apache2_container_ready "${container}" || return 1

    assertTrue "curl -sS http://[::1]:$LOCAL_PORT | grep -Fq 'It works!'"
}

test_static_content() {
    debug "Creating all-defaults apache2 container"
    test_data_wwwroot="$(realpath -e $(dirname "$0"))/apache2_test_data/html"
    container=$(docker_run_server -p "$LOCAL_PORT:80" -v "$test_data_wwwroot:/var/www/html:ro")

    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_apache2_container_ready "${container}" || return 1

    orig_checksum=$(md5sum "$test_data_wwwroot/test.txt" | awk '{ print $1 }')
    retrieved_checksum=$(curl -sS http://127.0.0.1:$LOCAL_PORT/test.txt | md5sum | awk '{ print $1 }')

    assertEquals "Checksum mismatch in retrieved test.txt" "${orig_checksum}" "${retrieved_checksum}"
}

test_custom_config() {
    debug "Creating apache2 container with custom config"
    custom_config="$(realpath -e $(dirname "$0"))/apache2_test_data/apache2_simple.conf"
    test_data_wwwroot="$(realpath -e $(dirname "$0"))/apache2_test_data/html"
    container=$(docker_run_server -p "$LOCAL_PORT:80" -v "$custom_config:/etc/apache2/apache2.conf:ro" -v "$test_data_wwwroot:/srv/www:ro")

    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_apache2_container_ready "${container}" || return 1

    orig_checksum=$(md5sum "$test_data_wwwroot/index.html" | awk '{ print $1 }')
    retrieved_checksum=$(curl -sS "http://127.0.0.1:$LOCAL_PORT" | md5sum | awk '{ print $1 }')

    assertEquals "Checksum mismatch in retrieved index.hml" "${orig_checksum}" "${retrieved_checksum}"
}


load_shunit2
