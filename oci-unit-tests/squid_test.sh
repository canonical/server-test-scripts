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

readonly http_server_image="docker.io/python:latest"

oneTimeSetUp() {
    id=$$

    # Remove image before test.
    remove_current_image

    # Make sure we're using the latest OCI image.
    docker pull --quiet "${DOCKER_IMAGE}" > /dev/null

    # Pull python image for minimal http server
    docker pull --quiet "${http_server_image}"  > /dev/null

    docker network create "${DOCKER_NETWORK}" > /dev/null 2>&1
}

oneTimeTearDown() {
    docker network rm "${DOCKER_NETWORK}" > /dev/null 2>&1
    docker rmi "${http_server_image}" > /dev/null
}

tearDown() {
    if [ -n "${container}" ]; then
        stop_container_sync "${container}"
    fi
    if [ -n "${webserver}" ]; then
        stop_container_sync "${webserver}"
    fi
    if [ -n "${volume}" ]; then
        docker volume rm "${volume}" > /dev/null 2>&1
    fi
}

# Helper function to execute squid with some common arguments.
docker_run_server() {
    docker run \
     --network "${DOCKER_NETWORK}" \
     --rm \
     -d \
     --name squid_test_"${id}" \
     "$@" \
     "${DOCKER_IMAGE}"
}

# Helper function to start a simple HTTP server
start_http_server() {
    docker run \
     --network "${DOCKER_NETWORK}" \
     --rm \
     -d \
     --name squid_test_http_server_"${id}" \
     "$@" \
     "${http_server_image}" python3 -m http.server
}

# Helper function to wait for squid to be up and listening for new connections
wait_squid_container_ready() {
    local container="${1}"
    local log="socket opened."
    wait_container_ready "${container}" "${log}"
}

# Helper function to search for strings in the logs
assert_in_logs() {
    local attempts=0
    while ! docker logs "${1}" 2>&1 | grep -qE "${2}"; do
        if [ $attempts -ge 2 ]; then
            fail "'${2}' not available in '${1}'s logs"
            break
        fi
        sleep 1
        attempts=$((attempts+1))
    done
}

# Test simple proxied http connection
test_start_and_connect() {
    container=$(docker_run_server -p 3128:3128)
    webserver=$(start_http_server -p 8000:8000)
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_squid_container_ready "${container}"
    http_proxy=localhost:3128 curl -s http://squid_test_http_server_"${id}":8000 | grep -qF 'Directory listing for'
    assertTrue "Could not access proxy" $?
    assert_in_logs "${container}" "TCP_MISS/200"
    assert_in_logs "${webserver}" '"GET / HTTP/1.1" 200'
}

# Test simple proxied ipv6 http connection
test_start_and_connect_ipv6() {
    container=$(docker_run_server -p 3128:3128)
    webserver=$(start_http_server -p 8000:8000)
    assertNotNull "Failed to start the container" "${container}" || return 1
    assertNotNull "Failed to start the container" "${webserver}" || return 1
    wait_squid_container_ready "${container}"
    http_proxy='http://[::1]:3128' curl -s http://squid_test_http_server_"${id}":8000 | grep -qF 'Directory listing for'
    assertTrue "Could not access proxy" $?
    assert_in_logs "${container}" "TCP_MISS/200"
    assert_in_logs "${webserver}" '"GET / HTTP/1.1" 200'
}

# Test loading squid with a custom configuration file
test_custom_configuration() {
    container=$(docker_run_server -p 3128:3128 -v "${ROOTDIR}"/squid_test_data/custom_config:/etc/squid)
    webserver=$(start_http_server -p 8000:8000)
    assertNotNull "Failed to start the squid container" "${container}" || return 1
    assertNotNull "Failed to start the webserver container" "${webserver}" || return 1
    wait_squid_container_ready "${container}"
    http_proxy=http://localhost:3128 curl -I -s http://squid_test_http_server_"${id}":8000 | grep -qF ERR_ACCESS_DENIED
    assertTrue "Missing squid's access denied header" $?
    assert_in_logs "${container}" "TCP_DENIED/403"
}

# Test if logs are indeed persisted in the proper volume
test_persistent_logs() {
    debug "Creating persistent volume"
    volume=$(docker volume create)
    container=$(docker_run_server -p 3128:3128 -v "${volume}":/var/log/squid)
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_squid_container_ready "${container}"
    # request some unavailable service
    docker exec "${container}" cat /var/log/squid/access.log | grep -qF 'GET http://localhost:8000/'
    assertFalse "Sanity check failed; the test string was already logged" $?
    http_proxy=localhost:3128 curl -s http://localhost:8000 > /dev/null
    docker exec "${container}" cat /var/log/squid/access.log | grep -qF 'GET http://localhost:8000/'
    assertTrue "Access was not properly logged" $?
    # stop container, which deletes it because it was launched with --rm
    stop_container_sync "${container}"
    container=$(docker_run_server -p 3128:3128 -v "${volume}":/var/log/squid)
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_squid_container_ready "${container}"
    # Check if the old entry is still present
    docker exec "${container}" cat /var/log/squid/access.log | grep -qF 'GET http://localhost:8000/'
    assertTrue "Logs were not preserved" $?
}

# Test if the cache is persisted and served through different instances of the image
test_persistent_cache() {
    debug "Creating persistent volume"
    volume=$(docker volume create)
    container=$(docker_run_server -p 3128:3128 -v "${volume}":/var/spool/squid -v "${ROOTDIR}"/squid_test_data/cache_config:/etc/squid)
    webserver=$(start_http_server -p 8000:8000)
    assertNotNull "Failed to start the squid container" "${container}" || return 1
    assertNotNull "Failed to start the webserver container" "${webserver}" || return 1
    wait_squid_container_ready "${container}"
    # Perform a simple http request and verify a TCP_MISS was logged
    http_proxy=http://localhost:3128 curl -s http://squid_test_http_server_${id}:8000 | grep -qF 'Directory listing for'
    assertTrue "Could not access proxy" $?
    assert_in_logs "${container}" "TCP_MISS/200"
    # stop container, which deletes it because it was launched with --rm
    stop_container_sync "${container}"
    container=$(docker_run_server -p 3128:3128 -v "${volume}":/var/spool/squid -v "${ROOTDIR}"/squid_test_data/cache_config:/etc/squid)
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_squid_container_ready "${container}"
    # Perform a simple http request and verify the response was already cached
    http_proxy=http://localhost:3128 curl -s http://squid_test_http_server_${id}:8000 | grep -qF 'Directory listing for'
    assertTrue "Could not access proxy" $?
    docker logs "${container}" 2>&1 | grep -qF "TCP_MISS/200"
    assertFalse "Logs persisted from the last run, invalidating this test"
    assert_in_logs "${container}" "TCP_REFRESH_MODIFIED/200"
}

# Test if the manifest file exists
test_manifest_exists() {
    debug "Testing that the manifest file is available in the image"
    container=$(docker_run_server)

    check_manifest_exists "${container}"
    assertTrue "Manifest file(s) do(es) not exist or is(are) empty in image" $?
}

load_shunit2
