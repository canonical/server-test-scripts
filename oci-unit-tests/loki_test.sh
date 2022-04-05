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

readonly LOKI_PORT=3100
readonly PROMTAIL_PORT=9080
readonly PROMTAIL_CONFIG_FILE=promtail-local-config.yaml

oneTimeSetUp() {
    # Remove image before test.
    remove_current_image

    # Make sure we're using the latest OCI image.
    docker pull --quiet "${DOCKER_IMAGE}" > /dev/null

    docker network create "$DOCKER_NETWORK" > /dev/null 2>&1

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

oneTimeTearDown() {
    docker network rm "$DOCKER_NETWORK" > /dev/null 2>&1
}

# Helper function to execute loki.
docker_run_loki() {
    docker run \
	   --rm \
	   -d \
	   --name "${DOCKER_PREFIX}_${suffix}" \
	   "$@" \
	   "${DOCKER_IMAGE}"
}

docker_run_promtail() {
    docker run \
           --rm \
           -d \
           --name "${DOCKER_PREFIX}_${suffix}_promtail" \
           "$@" \
           --entrypoint "" \
           "${DOCKER_IMAGE}" \
           /usr/bin/promtail -config.file=/etc/loki/"${PROMTAIL_CONFIG_FILE}"
}

wait_loki_container_ready() {
    local container="${1}"
    local log="msg=\"Loki started\"$"
    wait_container_ready "${container}" "${log}"
}

wait_promtail_container_ready() {
    local container="${1}"
    local log="msg=\"Starting Promtail\""
    wait_container_ready "${container}" "${log}"
}

# Verify that loki is up and running.
test_loki_up() {
    debug "Creating loki container"

    container=$(docker_run_loki -p "${LOKI_PORT}:${LOKI_PORT}")
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_loki_container_ready "${container}" || return 1

    debug "Verifying that we can access the web endpoint"
    local metrics
    metrics="$(curl --silent "http://localhost:${LOKI_PORT}/metrics")"
    assertTrue "Check if the cortex_query_frontend_retries_sum metric is present" "echo \"${metrics}\" | grep -qF cortex_query_frontend_retries_sum"
    assertTrue "Check if the loki_boltdb_shipper_compact_tables_operation_duration_seconds metric is present" "echo \"${metrics}\" | grep -qF loki_boltdb_shipper_compact_tables_operation_duration_seconds"
}

# Verify that promtail and loki can talk to each other.
test_loki_and_promtail() {
    debug "Creating loki and promtail containers with custom config, making sure they talk to each other"

    container=$(docker_run_loki \
		-p "${LOKI_PORT}:${LOKI_PORT}" \
		--network "${DOCKER_NETWORK}")
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_loki_container_ready "${container}" || return 1

    local tempdir
    tempdir=$(mktemp -d)
    trap 'rm -rf ${tempdir}' 0 INT QUIT ABRT PIPE TERM
    cat > "${tempdir}/${PROMTAIL_CONFIG_FILE}" << __EOF__
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://${DOCKER_PREFIX}_${suffix}:${LOKI_PORT}/loki/api/v1/push

scrape_configs:
- job_name: system
  static_configs:
  - targets:
      - localhost
    labels:
      job: varlogs
      __path__: /var/log/*log
__EOF__

    local promtail_container
    promtail_container=$(docker_run_promtail \
		-p "${PROMTAIL_PORT}:${PROMTAIL_PORT}" \
		--network "${DOCKER_NETWORK}" \
		-v "${tempdir}"/"${PROMTAIL_CONFIG_FILE}":/etc/loki/"${PROMTAIL_CONFIG_FILE}")
    assertNotNull "Failed to start the container" "${promtail_container}" || return 1
    wait_promtail_container_ready "${promtail_container}" || return 1

    # We have to sleep a bit and give some time for promtail to connect to loki.
    sleep 5

    local values
    local match_re='{"status":"success","data":["varlogs"]}'
    values=$(curl -s http://127.0.0.1:"${LOKI_PORT}"/loki/api/v1/label/job/values)
    assertTrue "Check if the promtail job is successfully displayed by loki" "echo \"${values}\" | grep -qFx \"${match_re}\""

    match_re='{"status":"success","data":\[.*\/var\/log\/dpkg\.log.*\]}'
    values=$(curl -s http://127.0.0.1:"${LOKI_PORT}"/loki/api/v1/label/filename/values)
    assertTrue "Check if loki is monitoring log files via promtail" "echo \"${values}\" | grep -q \"${match_re}\""
    rm -rf "${tempdir}"
}

test_manifest_exists() {
    debug "Testing that the manifest file is available in the image"
    container=$(docker_run_loki)

    check_manifest_exists "${container}"
    assertTrue "Manifest file(s) do(es) not exist or is(are) empty in image" $?
}

load_shunit2
