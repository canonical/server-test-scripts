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

readonly ZOOKEEPER_PORT=2181
readonly BROKER_PORT=9092

oneTimeSetUp() {
    id=$$

    # Remove image before test.
    remove_current_image

    # Make sure we're using the latest OCI image.
    docker pull --quiet "${DOCKER_IMAGE}" > /dev/null 2>&1

    # Cleanup stale resources
    tearDown
    oneTimeTearDown

    # Setup network
    docker network create "${DOCKER_NETWORK}" > /dev/null 2>&1
}

oneTimeTearDown() {
    docker network rm "${DOCKER_NETWORK}" > /dev/null 2>&1
}

tearDown() {
    local container

    for container in $(docker ps --filter "name=${DOCKER_PREFIX}" --format "{{.Names}}"); do
        debug "Removing container ${container}"
        stop_container_sync "${container}"
    done
}

# Helper function to execute zookeeper with some common arguments.
docker_run_zookeeper() {
    docker run \
     --network "$DOCKER_NETWORK" \
     --rm \
     -d \
     -p "${ZOOKEEPER_PORT}":"${ZOOKEEPER_PORT}" \
     --name "${DOCKER_PREFIX}"_zookeeper_"${id}" \
     "${DOCKER_IMAGE}" \
     zookeeper-server-start.sh /etc/kafka/zookeeper.properties
}

# Helper function to execute kafka with some common arguments.
docker_run_broker() {
    docker run \
     --network "$DOCKER_NETWORK" \
     --rm \
     -d \
     -p "${BROKER_PORT}":"${BROKER_PORT}" \
     --name "${DOCKER_PREFIX}"_kafka_"${id}" \
     "${DOCKER_IMAGE}" \
     kafka-server-start.sh /etc/kafka/server.properties --override \
     zookeeper.connect="${DOCKER_PREFIX}"_zookeeper_"${id}":"${ZOOKEEPER_PORT}"
}

wait_zookeeper_container_ready() {
    local container="${1}"
    local log="INFO binding to port"
    wait_container_ready "${container}" "${log}"
}

wait_kafka_container_ready() {
    local container="${1}"
    local log="started \(kafka.server.KafkaServer\)"
    wait_container_ready "${container}" "${log}"
}

test_local_port_binding() {
    local zookeeper_container
    local kafka_container

    debug "Starting zookeeper"
    zookeeper_container=$(docker_run_zookeeper)
    assertNotNull "Failed to start the zookeeper container" "${zookeeper_container}" || return 1
    wait_zookeeper_container_ready "${zookeeper_container}" || return 1

    install_container_packages "${zookeeper_container}" iproute2
    debug "Checking for zookeeper service on local port ${ZOOKEEPER_PORT}"
    docker exec "${zookeeper_container}" ss -lnt -o "( sport = ${ZOOKEEPER_PORT} )" | grep -q LISTEN
    assertTrue "zookeeper does not seem to be listening on port ${ZOOKEEPER_PORT}" ${?}

    debug "Starting kafka broker"
    kafka_container=$(docker_run_broker)
    assertNotNull "Failed to start the kafka container" "${kafka_container}" || return 1
    wait_kafka_container_ready "${kafka_container}" || return 1

    install_container_packages "${kafka_container}" iproute2
    debug "Checking for kafka service on local port ${BROKER_PORT}"
    docker exec "${kafka_container}" ss -lnt -o "( sport = ${BROKER_PORT} )" | grep -q LISTEN
    assertTrue "kafka does not seem to be listening on port ${BROKER_PORT}" ${?}
}

test_communication() {
    local zookeeper_container
    local kafka_container

    debug "Instantiating kafka setup"
    zookeeper_container=$(docker_run_zookeeper)
    assertNotNull "Failed to start the zookeeper container" "${zookeeper_container}" || return 1
    wait_zookeeper_container_ready "${zookeeper_container}" || return 1
    kafka_container=$(docker_run_broker)
    assertNotNull "Failed to start the kafka container" "${kafka_container}" || return 1
    wait_kafka_container_ready "${kafka_container}" || return 1

    debug "Checking if zookeeper triggered the broker connection follow-ups"
    wait_container_ready "${zookeeper_container}" "Creating new log file" || return 1
}

test_producer_consumer() {
    local zookeeper_container
    local kafka_container

    debug "Instantiating kafka setup"
    zookeeper_container=$(docker_run_zookeeper)
    assertNotNull "Failed to start the zookeeper container" "${zookeeper_container}" || return 1
    wait_zookeeper_container_ready "${zookeeper_container}" || return 1
    kafka_container=$(docker_run_broker)
    assertNotNull "Failed to start the kafka container" "${kafka_container}" || return 1
    wait_kafka_container_ready "${kafka_container}" || return 1

    debug "Starting client container"
    client_container=$(run_container_service sleep 1000)
    assertNotNull "Failed to start client container" "${client_container}" || return 1

    debug "Creating new topic"
    docker exec "${client_container}" kafka-topics.sh \
      --create --partitions 1 --replication-factor 1 --topic quickstart-events \
      --bootstrap-server "${DOCKER_PREFIX}"_kafka_"${id}":"${BROKER_PORT}" | grep -qF 'Created topic quickstart-events'
    assertTrue "Could not create new topic" $?

    debug "Verifying that the new topic was created"
    docker exec "${client_container}" kafka-topics.sh \
      --describe --topic quickstart-events --bootstrap-server \
      "${DOCKER_PREFIX}"_kafka_"${id}":"${BROKER_PORT}" | grep -qF 'Topic: quickstart-events'
    assertTrue "Could not verify that a new topic was created" $?

    debug "Producing test message"
    local tempdir
    tempdir=$(mktemp -d)
    trap 'rm -rf ${tempdir}' 0 INT QUIT ABRT PIPE TERM
    echo "oci test message" > "${tempdir}/kafka_oci_test_message"
    docker exec -i "${client_container}" kafka-console-producer.sh \
      --topic quickstart-events --bootstrap-server \
      "${DOCKER_PREFIX}"_kafka_"${id}":"${BROKER_PORT}" < "${tempdir}/kafka_oci_test_message"
    rm -rf "${tempdir}"

    debug "Consuming test message"
    docker exec "${client_container}" kafka-console-consumer.sh \
      --max-messages 1 --timeout-ms 5000 --topic quickstart-events \
      --from-beginning --bootstrap-server "${DOCKER_PREFIX}"_kafka_"${id}":"${BROKER_PORT}" \
      2>&1 | grep -qF 'oci test message'
    assertTrue "Could not consume message. Was the message produced?" $?
}

test_manifest_exists() {
    local container

    debug "Testing that the manifest file is available in the image"
    container=$(docker_run_zookeeper)

    check_manifest_exists "${container}"
    assertTrue "Manifest file(s) do(es) not exist in image" ${?}
}

load_shunit2
