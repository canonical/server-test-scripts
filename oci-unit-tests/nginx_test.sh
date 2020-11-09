# shellcheck shell=dash

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
readonly DOCKER_NETWORK=nginx_test
readonly DOCKER_IMAGE="squeakywheel/nginx:edge"

oneTimeSetUp() {
    docker network create $DOCKER_NETWORK > /dev/null 2>&1
}

setUp() {
    id=$$
}

oneTimeTearDown() {
    docker network rm $DOCKER_NETWORK > /dev/null 2>&1
}

tearDown() {
    if [ -n "${container}" ]; then
        stop_container_sync "${container}"
    fi
}

docker_run_server() {
    docker run \
       --network $DOCKER_NETWORK \
       --rm \
       -d \
       --name nginx_test_${id} \
       "$@" \
       $DOCKER_IMAGE
}

wait_nginx_container_ready() {
    local container="${1}"
    local log="Configuration complete"
    wait_container_ready "${container}" "${log}"
}

test_default_config() {
    debug "Creating all-defaults nginx container"
    container=$(docker_run_server -p 48080:80)

    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_nginx_container_ready "${container}" || return 1

    assertTrue "curl -sS http://127.0.0.1:48080 | grep -Fq 'Welcome to nginx!'"
}

test_default_config_ipv6() {
    debug "Creating all-defaults nginx container"
    container=$(docker_run_server -p 48080:80)

    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_nginx_container_ready "${container}" || return 1

    assertTrue "curl -sS http://[::1]:48080 | grep -Fq 'Welcome to nginx!'"
}

test_static_files() {
    debug "Creating container with known static files"
    test_data_wwwroot="$PWD/nginx_test_data/html"
    container=$(docker_run_server -p 48080:80 -v "$test_data_wwwroot:/var/www/html:ro")

    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_nginx_container_ready "${container}" || return 1

    orig_checksum=$(md5sum "$test_data_wwwroot/test.txt" | awk '{ print $1 }')
    retrieved_checksum=$(curl -sS http://127.0.0.1:48080/test.txt | md5sum | awk '{ print $1 }')

    assertEquals "${orig_checksum}" "${retrieved_checksum}"
}

test_static_files_read_only_mode() {
    debug "Creating container with known static files"
    test_data_wwwroot="$PWD/nginx_test_data/html"
    nginx_scratch=$(mktemp -d /tmp/nginx-cache-XXXXXXXX)
    container=$(docker_run_server -p 48080:80 --read-only -v "$nginx_scratch:/var/lib/nginx" -v "$nginx_scratch:/var/log/nginx" -v "$nginx_scratch:/var/run" -v "$test_data_wwwroot:/var/www/html:ro")

    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_nginx_container_ready "${container}" || return 1

    orig_checksum=$(md5sum "$test_data_wwwroot/test.txt" | awk '{ print $1 }')
    retrieved_checksum=$(curl -sS http://127.0.0.1:48080/test.txt | md5sum | awk '{ print $1 }')

    assertEquals "${orig_checksum}" "${retrieved_checksum}"

    rm -rf "$nginx_scratch"
}

test_custom_config() {
    debug "Creating container with custom config"
    custom_config="$PWD/nginx_test_data/nginx.conf"
    test_data_wwwroot="$PWD/nginx_test_data/html"
    container=$(docker_run_server -p 48080:80 -v "$custom_config:/etc/nginx/nginx.conf:ro" -v "$test_data_wwwroot:/srv/www/html:ro")

    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_nginx_container_ready "${container}" || return 1

    orig_checksum=$(md5sum "$test_data_wwwroot/index.html" | awk '{ print $1 }')
    retrieved_checksum=$(curl -sS http://127.0.0.1:48080/ | md5sum | awk '{ print $1 }')

    assertEquals "${orig_checksum}" "${retrieved_checksum}"
}

load_shunit2
