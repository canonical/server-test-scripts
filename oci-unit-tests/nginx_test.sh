. $(dirname $0)/helper/test_helper.sh

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

load_shunit2
