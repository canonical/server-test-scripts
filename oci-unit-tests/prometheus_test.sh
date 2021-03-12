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

readonly DOCKER_PUSHGATEWAY_IMAGE="prom/pushgateway"
readonly PROM_PORT=50000
readonly ALERTMANAGER_PORT=50001
readonly PUSHGATEWAY_PORT=50002

if [ -z "${DOCKER_ALERTMANAGER_IMAGE}" ]; then
    # If undefined, guess by deriving from $DOCKER_IMAGE's name
    DOCKER_ALERTMANAGER_IMAGE=$(echo "$DOCKER_IMAGE" | sed 's/prometheus:/prometheus-alertmanager:/')
fi

oneTimeSetUp() {
    # Make sure we're using the latest OCI image.
    docker pull --quiet "${DOCKER_IMAGE}" > /dev/null

    # Cleanup stale resources
    tearDown
    oneTimeTearDown

    # Setup network
    docker network create "$DOCKER_NETWORK" > /dev/null 2>&1
}

setUp() {
    suffix=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)
}

oneTimeTearDown() {
    docker network rm "$DOCKER_NETWORK" > /dev/null 2>&1
}

tearDown() {
    for container in $(docker ps -a --filter "name=$DOCKER_PREFIX" --format "{{.Names}}"); do
        debug "Removing container ${container}"
        stop_container_sync "${container}"
    done
    if [ -n "${volume}" ]; then
        docker volume rm "${volume}" > /dev/null 2>&1
    fi
}

# Helper function to execute prometheus with some common arguments.
# It accepts extra arguments.
docker_run_prom() {
    docker run \
	   --network "$DOCKER_NETWORK" \
	   --rm \
	   -d \
	   --publish ${PROM_PORT}:9090 \
	   --name "${DOCKER_PREFIX}_${suffix}" \
	   "$@" \
	   "${DOCKER_IMAGE}"
}

# Helper function to execute alertmanager.
docker_run_alertmanager() {
    docker run \
	   --network "$DOCKER_NETWORK" \
	   --rm \
	   -d \
	   --publish ${ALERTMANAGER_PORT}:9093 \
	   --name "${DOCKER_PREFIX}_alertmanager_${suffix}" \
	   "$DOCKER_ALERTMANAGER_IMAGE"
}

# Helper function to execute pushgateway.
docker_run_pushgateway() {
    docker run \
	   --network "$DOCKER_NETWORK" \
	   --rm \
	   -d \
	   --publish ${PUSHGATEWAY_PORT}:9091 \
	   --name "${DOCKER_PREFIX}_pushgateway_${suffix}" \
	   $DOCKER_PUSHGATEWAY_IMAGE
}

wait_prometheus_container_ready() {
    local container="${1}"
    local log="Server is ready to receive web requests."
    wait_container_ready "${container}" "${log}"
}

wait_alertmanager_container_ready() {
    local container="${1}"
    local log="Listening address=:9093"
    wait_container_ready "${container}" "${log}"
}

wait_pushgateway_container_ready() {
    local container="${1}"
    local log="listen_address=:9091"
    wait_container_ready "${container}" "${log}"
}

test_cli() {
    debug "Check prometheus help via CLI"
    temp_dir=$(mktemp -d)
    docker run --rm --name "${DOCKER_PREFIX}_${suffix}" ubuntu/prometheus:edge --help 2>"${temp_dir}/prom_help"
    out=$(cat "${temp_dir}/prom_help") && ret=1
    if echo "${out}" | grep "The Prometheus monitoring server" >/dev/null; then
        ret=0
    fi
    assertTrue $ret
    rm -rf "${temp_dir}"
}

test_default_target() {
    debug "Creating prometheus container"
    container=$(docker_run_prom)
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_prometheus_container_ready "${container}" || return 1

    # Give some time for prometheus to check the health status of the target.
    # The default scrape interval is 15 seconds.
    sleep 20

    debug "Check if the default prometheus target is running"
    out=$(curl --silent "http://localhost:${PROM_PORT}/targets" \
	    | grep job-prometheus \
            | cut -d '>' -f 2 \
            | cut -d '<' -f 1)
    assertEquals "Default prometheus target" "prometheus (1/1 up)" "${out}" || return 1
}

test_alertmanager_config() {
    debug "Creating alertmanager container"
    container_aux=$(docker_run_alertmanager)
    wait_alertmanager_container_ready "${container_aux}" || return 1

    debug "Creating prometheus container with alertmanager configured"
    temp_dir=$(mktemp -d)
    alertmanager_url="${DOCKER_PREFIX}_alertmanager_${suffix}:9093"
    cat > "${temp_dir}/prometheus.yml" << EOF
alerting:
  alertmanagers:
  - static_configs:
    - targets:
      - ${alertmanager_url}
EOF
    container=$(docker_run_prom --volume "${temp_dir}/prometheus.yml:/etc/prometheus/prometheus.yml")
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_prometheus_container_ready "${container}" || return 1

    debug "Check if the alertmanager is configured"
    out=$(curl --silent "http://localhost:${PROM_PORT}/status")
    assertTrue echo "${out}" | grep "${alertmanager_url}" >/dev/null
}

test_alerts_config() {
    debug "Creating prometheus container with an alerts config file"
    temp_dir=$(mktemp -d)
    alert_name="InstanceDown"
    cat > "${temp_dir}/prometheus.yml" << EOF
rule_files:
  - alerts.yml
EOF
    cat > "${temp_dir}/alerts.yml" << EOF
groups:
- name: oci-test
  rules:
  - alert: ${alert_name}
    expr: up == 0
    for: 5m
    labels:
      severity: major
    annotations:
      summary: "Instance down"
      description: "Instance of this job has been down for more than 5 minutes."
EOF
    container=$(docker_run_prom --volume "${temp_dir}/prometheus.yml:/etc/prometheus/prometheus.yml" \
                                --volume "${temp_dir}/alerts.yml:/etc/prometheus/alerts.yml")
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_prometheus_container_ready "${container}" || return 1

    debug "Check if the alert is active"
    out=$(curl --silent "http://localhost:${PROM_PORT}/alerts")
    assertTrue echo "${out}" | grep "${alert_name}" | grep active >/dev/null
}

push_dummy_metric_data() {
    local metric_name=$1
    local metric_value=$2
    local job_name=$3
    local instance_name=$4

    rc=$(echo "${metric_name} ${metric_value}" |
	    curl --silent --data-binary @- "http://localhost:${PUSHGATEWAY_PORT}/metrics/job/${job_name}/instance/${instance_name}")
    $rc || return 1
}

check_dummy_metric_status() {
    local metric_name=$1
    local metric_value=$2
    local job_name=$3
    local instance_name=$4

    instance=$(curl --silent "http://localhost:${PROM_PORT}/api/v1/query?query=${metric_name}" | jq .data.result[0].metric.instance)
    assertEquals "Metric instance" "\"${instance_name}\"" "${instance}" || return 1
    job=$(curl --silent "http://localhost:${PROM_PORT}/api/v1/query?query=${metric_name}" | jq .data.result[0].metric.job)
    assertEquals "Metric job" "\"${job_name}\"" "${job}" || return 1
    value=$(curl --silent "http://localhost:${PROM_PORT}/api/v1/query?query=${metric_name}" | jq .data.result[0].value[1])
    assertEquals "Metric value" "\"${metric_value}\"" "${value}" || return 1
}

test_persistent_volume_keeps_changes() {
    # Verify that a container launched with a volume that already has data in
    # it won't re-initialize it, thus preserving the data.
    debug "Creating persistent volume"
    volume=$(docker volume create)
    assertNotNull "Failed to create a volume" "${volume}" || return 1

    debug "Creating pushgateway container"
    container_aux=$(docker_run_pushgateway)
    wait_pushgateway_container_ready "${container_aux}" || return 1

    debug "Creating prometheus container with a volume to persist data and configured to scrape pushgateway"
    temp_dir=$(mktemp -d)
    cat > "${temp_dir}/prometheus.yml" << EOF
scrape_configs:
  - job_name: 'pushgateway'
    honor_labels: true
    scrape_interval: 1s
    static_configs:
    - targets: ["${DOCKER_PREFIX}_pushgateway_${suffix}:9091"]
EOF
    container=$(docker_run_prom --mount source="${volume}",target=/prometheus \
                                --volume "${temp_dir}/prometheus.yml:/etc/prometheus/prometheus.yml")
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_prometheus_container_ready "${container}" || return 1

    debug "Submit a dummy metric to pushgateway"
    metric_name="test_metric"
    metric_value="3.14"
    job_name="pushgateway"
    instance_name="server01"
    push_dummy_metric_data $metric_name $metric_value $job_name $instance_name

    # Make sure the new metric was scrapped by prometheus
    sleep 20

    debug "Check dummy metric in prometheus"
    check_dummy_metric_status $metric_name $metric_value $job_name $instance_name

    debug "Stop prometheus container"
    stop_container_sync "${container}"

    debug "Start a new prometheus container using the same volume"
    container=$(docker_run_prom --mount source="${volume}",target=/prometheus \
                                --volume "${temp_dir}/prometheus.yml:/etc/prometheus/prometheus.yml")
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_prometheus_container_ready "${container}" || return 1

    debug "Check dummy metric in the new prometheus container"
    check_dummy_metric_status $metric_name $metric_value $job_name $instance_name

    rm -rf "${temp_dir}"
}

load_shunit2
