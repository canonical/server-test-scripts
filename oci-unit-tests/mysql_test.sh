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

oneTimeSetUp() {
    # Make sure we're using the latest OCI image.
    docker pull --quiet "${DOCKER_IMAGE}" > /dev/null

    docker network create "$DOCKER_NETWORK" > /dev/null 2>&1
}

setUp() {
    password=$(dd if=/dev/urandom bs=1 count=16 2>/dev/null | md5sum | head -c 16)
    id=$$
}

oneTimeTearDown() {
    docker network rm "$DOCKER_NETWORK" > /dev/null 2>&1
}

tearDown() {
    if [ -n "${container}" ]; then
        stop_container_sync "${container}"
    fi
    if [ -n "${volume}" ]; then
        docker volume rm "${volume}" > /dev/null 2>&1
    fi
}

# Helper function to invoke the mysql server.
# It accepts extra arguments that are then passed to the server.
docker_run_server() {
    docker run \
           --network "$DOCKER_NETWORK" \
           --rm \
	   -d \
	   --name mysql_test_${id} \
	   "$@" \
	   "${DOCKER_IMAGE}"
}

# Helper function to invoke the mysql client.
#
# The first argument (optional) is always considered to be the user
# that will connect to the server.
#
# The rest of the arguments are passed directly to "mysql".
docker_run_mysql() {
    local user=root

    if [ -n "$1" ]; then
	user="$1"
	shift
    fi

    # When it receives the password via CLI, mysql always displays a
    # warning saying that this is insecure.  That's why we filter out
    # these lines in the end.
    docker run \
	   --network "$DOCKER_NETWORK" \
	   --rm \
	   -i \
	   "${DOCKER_IMAGE}" \
	   mysql -h mysql_test_${id} -u "${user}" -p"${password}" -s "$@" 2>&1 \
	| grep -vxF "mysql: [Warning] Using a password on the command line interface can be insecure."
}

# Helper function to send a SQL statement to the mysql client.
docker_mysql_execute() {
    local sql="${1}"
    cat <<EOF | docker_run_mysql "${TEST_MYSQL_USER:-root}" "${TEST_MYSQL_DB}"
${sql};
EOF
}

wait_mysql_container_ready() {
    local container="${1}"
    local log="\[System\] \[MY-[0-9]+\] \[Server\] /usr/sbin/mysqld: ready for connections\..*port: 3306"
    # mysqld takes a long time to start.
    local timeout=300

    wait_container_ready "${container}" "${log}" "${timeout}"
}

test_list_and_create_databases() {
    debug "Creating mysql container (user root)"
    container=$(docker_run_server -e MYSQL_ROOT_PASSWORD="${password}")
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_mysql_container_ready "${container}" || return 1
    debug "Testing connection as root, looking for \"mysql\" DB"
    # default db is still "mysql"
    out=$(docker_mysql_execute "SHOW DATABASES" | grep "^mysql")
    assertEquals "DB listing did not include \"mysql\"" "mysql" "${out}" || return 1
    # Verify we can create a new DB, since we are root
    test_db="test_db${id}"
    debug "Trying to create a new DB called ${test_db} as user root"
    docker_mysql_execute "CREATE DATABASE ${test_db}"
    # list DB
    debug "Verifying DB ${test_db} was created"
    out=$(docker_mysql_execute "SHOW DATABASES" | grep "^${test_db}")
    assertEquals "DB listing did not include \"${test_db}\"" "${test_db}" "${out}" || return 1
}

test_create_user_and_database() {
    admin_user="user_${id}"
    test_db="test_db_${id}"

    debug "Creating container with MYSQL_USER=${admin_user} and MYSQL_DATABASE=${test_db}"
    container=$(docker_run_server \
        -e MYSQL_USER=${admin_user} \
        -e MYSQL_PASSWORD="${password}" \
	-e MYSQL_DATABASE=${test_db} \
	-e MYSQL_ROOT_PASSWORD="${password}")
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_mysql_container_ready "${container}" || return 1

    # list DB
    debug "Verifying DB ${test_db} was created"
    out=$(TEST_MYSQL_USER="${admin_user}" docker_mysql_execute "SHOW DATABASES" | grep "^${test_db}")
    assertEquals "DB listing did not include \"${test_db}\"" "${test_db}" "${out}" || return 1
}

test_default_database_name() {
    test_db="test_db_${id}"
    debug "Creating container with MYSQL_DATABASE=${test_db}"
    container=$(docker_run_server \
        -e MYSQL_DATABASE=${test_db} \
        -e MYSQL_ROOT_PASSWORD="${password}")
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_mysql_container_ready "${container}" || return 1
    debug "Checking if database ${test_db} was created"
    out=$(docker_mysql_execute "SHOW DATABASES" | grep "^${test_db}")
    assertEquals "Failed to create test database" "${test_db}" "${out}" || return 1
}

test_persistent_volume_keeps_changes() {
# Verify that a container launched with a volume that already has a DB in it
# won't re-initialize it, thus preserving the data.
    debug "Creating persistent volume"
    volume=$(docker volume create)
    assertNotNull "Failed to create a volume" "${volume}" || return 1
    debug "Launching container"
    container=$(docker_run_server \
        -e MYSQL_ROOT_PASSWORD="${password}" \
        --mount source="${volume}",target=/var/lib/mysql)

    assertNotNull "Failed to start the container" "${container}" || return 1
    # wait for it to be ready
    wait_mysql_container_ready "${container}" || return 1

    # Create test database
    test_db="test_db_${id}"
    debug "Creating test database ${test_db}"
    docker_mysql_execute "CREATE DATABASE ${test_db}"
    out=$(docker_mysql_execute "SHOW DATABASES" | grep "^${test_db}")
    assertEquals "Failed to create test database" "${test_db}" "${out}" || return 1

    # create test table
    test_table="test_data_${id}"
    debug "Creating test table ${test_table} with data"
    sql="CREATE TABLE ${test_table} (id INT, description TEXT);
         INSERT INTO ${test_table} (id,description) VALUES (${id}, 'hello');"
    TEST_MYSQL_DB="${test_db}" docker_mysql_execute "${sql}"
    # There's no easy way to specify the field delimiter to mysql, so
    # we have to resort to tr.
    sql="SELECT * FROM ${test_table}"
    out=$(TEST_MYSQL_DB="${test_db}" docker_mysql_execute "${sql}" | tr '\t' '%')
    assertEquals "Failed to verify test table" "${id}%hello" "${out}" || return 1

    # stop container, which deletes it because it was launched with --rm
    stop_container_sync "${container}"
    # launch another one with the same volume, and the data we created above
    # must still be there
    # By using the same --name also makes sure the previous container is really
    # gone, otherwise the new one wouldn't start
    debug "Launching new container with same volume"
    container=$(docker_run_server \
        -e MYSQL_ROOT_PASSWORD="${password}" \
        --mount source="${volume}",target=/var/lib/mysql)

    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_mysql_container_ready "${container}" || return 1
    # data we created previously should still be there
    debug "Verifying database ${test_db} and table ${test_table} are there with our data"
    sql="SELECT * FROM ${test_table}"
    out=$(TEST_MYSQL_DB="${test_db}" docker_mysql_execute "${sql}" | tr '\t' '%')
    assertEquals "Failed to verify test table" "${id}%hello" "${out}" || return 1
}

load_shunit2
