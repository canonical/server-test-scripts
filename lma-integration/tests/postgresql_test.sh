. $(dirname $0)/helper/test_helper.sh

# cheat sheet:
#  assertTrue $?
#  assertEquals 1 2
#  oneTimeSetUp()
#  oneTimeTearDown()
#  setUp() - run before each test
#  tearDown() - run after each test

oneTimeSetUp() {
    docker volume prune --force &>/dev/null
}

oneTimeTearDown() {
    docker volume prune --force &>/dev/null
}

setUp() {
    volume=$(docker volume create)
    password=$(dd if=/dev/urandom bs=1 count=16 2>/dev/null | md5sum | head -c 16)
    id=$$
}

tearDown() {
    docker container stop "${container}" &>/dev/null
    while docker container ls | grep -q "${container}"; do
        sleep 1
    done
    docker volume rm "${volume}" &>/dev/null
}

test_persistent_volume() {
    assertNotNull "Failed to create a volume" "${volume}"
    echo "Launching container"
    container=$(docker run --rm -d \
        -e POSTGRES_PASSWORD=${password} \
        -p 5432:5432 \
        --mount source=${volume},target=/var/lib/postgresql/data \
        --name postgresql_test_${id} \
        squeakywheel/postgres:edge \
    )
    assertNotNull "${container}"
    # wait for it to be ready
    echo -n "Waiting for container to be ready "
    logs=$(docker logs ${container} 2>&1 | tail -n 1)
    ready="database system is ready to accept connections"
    while ! echo "${logs}" | grep -q "${ready}"; do
        echo -n "."
        sleep 1
        logs=$(docker logs ${container} 2>&1 | tail -n 1)
    done
    echo

    echo "Creating test database with data"
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
    docker container stop ${container} &>/dev/null
    while docker container ls | grep -q "${container}"; do
        sleep 1
    done
    # launch another one with the same volume, and the data we created above
    # must still be there
    # By using the same --name also makes sure the previous container is really
    # gone, otherwise the new one wouldn't start
    echo "Launching new container with same volume"
    container=$(docker run --rm -d \
        -p 5432:5432 \
        --mount source=${volume},target=/var/lib/postgresql/data \
        --name postgresql_test_${id} \
        squeakywheel/postgres:edge \
    )
    echo -n "Waiting for container to be ready "
    logs=$(docker logs ${container} 2>&1 | tail -n 1)
    ready="database system is ready to accept connections"
    while ! echo "${logs}" | grep -q "${ready}"; do
        echo -n "."
        sleep 1
        logs=$(docker logs ${container} 2>&1 | tail -n 1)
    done
    echo
    out=$(psql -F % -A -t postgresql://postgres:${password}@127.0.0.1/${test_db} -q -c \
        "SELECT * FROM ${test_table};")
    assertEquals "Failed to verify test table" "${id}%hello" "${out}"
}

load_shunit2

