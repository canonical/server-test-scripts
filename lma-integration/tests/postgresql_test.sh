. $(dirname $0)/helper/test_helper.sh

# cheat sheet:
#  assertTrue $?
#  assertEquals 1 2
#  oneTimeSetUp()
#  oneTimeTearDown()
#  setUp() - run before each test
#  tearDown() - run after each test

setUp() {
    password=$(dd if=/dev/urandom bs=1 count=16 2>/dev/null | md5sum | head -c 16)
    id=$$
}

tearDown() {
    stop_container_sync "${container}"
    if [ -n "${volume}" ]; then
        docker volume rm "${volume}" > /dev/null 2>&1
    fi
}

test_default_database_name() {
# POSTGRES_DB
# This optional environment variable can be used to define a different name for
# the default database that is created when the image is first started. If it
# is not specified, then the value of POSTGRES_USER will be used.
    test_db="database${id}"
    debug "Creating container with POSTGRES_DB=${test_db}"
    container=$(docker run --rm -d \
        -e POSTGRES_DB=${test_db} \
        -e POSTGRES_PASSWORD=${password} \
        -p 5432:5432 \
        --name postgresql_test_${id} \
        squeakywheel/postgres:edge \
    )
    assertNotNull "${container}"
    ready_log="database system is ready to accept connections"
    wait_container_ready "${container}" "${ready_log}"
    debug "Checking if database ${test_db} was created"
    out=$(psql postgresql://postgres:${password}@127.0.0.1 -q -l -A -t -F % | grep "^${test_db}" | cut -d % -f 1)
    assertEquals "Failed to create test database" "${test_db}" "${out}"
}

test_persistent_volume_keeps_changes() {
    volume=$(docker volume create)
    assertNotNull "Failed to create a volume" "${volume}"
    debug "Launching container"
    container=$(docker run --rm -d \
        -e POSTGRES_PASSWORD=${password} \
        -p 5432:5432 \
        --mount source=${volume},target=/var/lib/postgresql/data \
        --name postgresql_test_${id} \
        squeakywheel/postgres:edge \
    )
    assertNotNull "${container}"
    # wait for it to be ready
    ready_log="database system is ready to accept connections"
    wait_container_ready "${container}" "${ready_log}"

    debug "Creating test database with data"
    # Create test database
    test_db="test_db_${id}"
    psql postgresql://postgres:${password}@127.0.0.1/postgres -q -c \
        "CREATE DATABASE ${test_db};"
    out=$(psql postgresql://postgres:${password}@127.0.0.1 -q -l -A -t -F % | grep "^${test_db}" | cut -d % -f 1)
    assertEquals "Failed to create test database" "${test_db}" "${out}"

    # create test table
    test_table="test_data_${id}"
    psql postgresql://postgres:${password}@127.0.0.1/${test_db} -q <<EOF
CREATE TABLE ${test_table} (id INT, description TEXT);
INSERT INTO ${test_table} (id,description) VALUES (${id}, 'hello');
EOF
    out=$(psql -F % -A -t postgresql://postgres:${password}@127.0.0.1/${test_db} -q -c \
        "SELECT * FROM ${test_table};")
    assertEquals "Failed to verify test table" "${id}%hello" "${out}"

    # stop container, which deletes it because it was launched with --rm
    stop_container_sync ${container}
    # launch another one with the same volume, and the data we created above
    # must still be there
    # By using the same --name also makes sure the previous container is really
    # gone, otherwise the new one wouldn't start
    debug "Launching new container with same volume"
    container=$(docker run --rm -d \
        -p 5432:5432 \
        --mount source=${volume},target=/var/lib/postgresql/data \
        --name postgresql_test_${id} \
        squeakywheel/postgres:edge \
    )
    ready_log="database system is ready to accept connections"
    wait_container_ready "${container}" "${ready_log}"
    # data we created previously should still be there
    debug "Verifying database ${test_db} and table ${test_table} are there with our data"
    out=$(psql -F % -A -t postgresql://postgres:${password}@127.0.0.1/${test_db} -q -c \
        "SELECT * FROM ${test_table};")
    assertEquals "Failed to verify test table" "${id}%hello" "${out}"
}

load_shunit2

