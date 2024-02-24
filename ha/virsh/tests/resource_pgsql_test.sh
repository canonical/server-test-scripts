# shellcheck shell=bash

# Based on LP: #2013084; and
# https://wiki.clusterlabs.org/wiki/PgSQL_Replicated_Cluster; and
# https://clusterlabs.github.io/PAF

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"
# shellcheck disable=SC1090
. "$(dirname "$0")/../vm_utils.sh"

PG_HBA="\
host    all             all     127.0.0.1/32        trust\n\
host    all             all     192.168.0.0/16      trust\n\
host    replication     all     192.168.0.0/16      trust"

if [[ "${UBUNTU_SERIES}" = "noble" ]]; then
  # the pgsql agent is in main starting from noble (24.04)
  RESOURCE_AGENTS_PKG=resource-agents-base
else
  RESOURCE_AGENTS_PKG=resource-agents-extra
fi

setup_cluster() {
  # we do not need VM03 here: let's put it in maintainance mode
  run_command_in_node "${IP_VM01}" "sudo pcs cluster node remove ${VM03}"
  run_in_all_nodes "DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "${RESOURCE_AGENTS_PKG}" postgresql >/dev/null"
  PGSQL_VERSION=$(run_command_in_node "${IP_VM01}" "pg_config --version")
  # PostgreSQL 16.1 (Ubuntu 16.1-1build1)
  PGSQL_VERSION=$(echo "${PGSQL_VERSION}" | sed -E -n 's/PostgreSQL ([0-9]+)\..*/\1/p')
}

setup_main_server() {
  run_command_in_node "${IP_VM01}" "sudo pg_conftool "${PGSQL_VERSION}" main set listen_addresses '*'"
  run_command_in_node "${IP_VM01}" "sudo pg_conftool "${PGSQL_VERSION}" main set wal_level hot_standby"
  run_command_in_node "${IP_VM01}" "sudo pg_conftool "${PGSQL_VERSION}" main set synchronous_commit  on"
  run_command_in_node "${IP_VM01}" "sudo pg_conftool "${PGSQL_VERSION}" main set archive_mode on"
  run_command_in_node "${IP_VM01}" "sudo pg_conftool "${PGSQL_VERSION}" main set archive_command 'cp %p /var/lib/postgresql/"${PGSQL_VERSION}"/main/pg_archive/%f'"
  run_command_in_node "${IP_VM01}" "sudo pg_conftool "${PGSQL_VERSION}" main set max_wal_senders 5"
  # wal_keep_segments was renamed
  # https://www.postgresql.org/docs/13/release-13.html
  run_command_in_node "${IP_VM01}" "sudo pg_conftool "${PGSQL_VERSION}" main set wal_keep_size 512"
  run_command_in_node "${IP_VM01}" "sudo pg_conftool "${PGSQL_VERSION}" main set hot_standby on"
  run_command_in_node "${IP_VM01}" "sudo pg_conftool "${PGSQL_VERSION}" main set restart_after_crash off"
  # replication_timeout was renamed
  # https://www.postgresql.org/docs/9.3/release-9-3.html
  run_command_in_node "${IP_VM01}" "sudo pg_conftool "${PGSQL_VERSION}" main set wal_sender_timeout 5000"
  run_command_in_node "${IP_VM01}" "sudo pg_conftool "${PGSQL_VERSION}" main set wal_receiver_status_interval 2"
  run_command_in_node "${IP_VM01}" "sudo pg_conftool -- "${PGSQL_VERSION}" main set max_standby_streaming_delay -1"
  run_command_in_node "${IP_VM01}" "sudo pg_conftool -- "${PGSQL_VERSION}" main set max_standby_archive_delay -1"
  run_command_in_node "${IP_VM01}" "sudo pg_conftool "${PGSQL_VERSION}" main set synchronous_commit on"
  run_command_in_node "${IP_VM01}" "sudo pg_conftool "${PGSQL_VERSION}" main set restart_after_crash off"
  run_command_in_node "${IP_VM01}" "sudo pg_conftool "${PGSQL_VERSION}" main set hot_standby_feedback on"
  run_command_in_node "${IP_VM01}" "sudo sed -i \"$ a ${PG_HBA}\" /etc/postgresql/"${PGSQL_VERSION}"/main/pg_hba.conf"
  # create archive and tmp directories
  run_command_in_node "${IP_VM01}" "sudo -u postgres mkdir -p /var/lib/postgresql/"${PGSQL_VERSION}"/main/pg_archive"
  run_command_in_node "${IP_VM01}" "sudo -u postgres mkdir -p /var/lib/postgresql/"${PGSQL_VERSION}"/tmp"
  # workaround for entry added in the resource agent. This is added in the main config file to workaround postgresql >= 12 changes
  run_command_in_node "${IP_VM01}" "sudo -u postgres touch /var/lib/postgresql/"${PGSQL_VERSION}"/tmp/recovery.conf"
  run_command_in_node "${IP_VM01}" "sudo systemctl restart postgresql"
  sleep 10
}

setup_replica() {
  run_command_in_node "${IP_VM02}" "sudo systemctl stop postgresql"
  run_command_in_node "${IP_VM02}" "sudo sh -c 'rm -rf /var/lib/postgresql/"${PGSQL_VERSION}"/main/*'"
  run_command_in_node "${IP_VM02}" "sudo -u postgres pg_basebackup -h ${IP_VM01} -U postgres -D /var/lib/postgresql/"${PGSQL_VERSION}"/main -X stream -P -v"
  run_command_in_node "${IP_VM02}" "sudo -u postgres mkdir -p /var/lib/postgresql/"${PGSQL_VERSION}"/main/pg_archive"
  run_command_in_node "${IP_VM02}" "sudo -u postgres mkdir -p /var/lib/postgresql/"${PGSQL_VERSION}"/tmp"
  # workaround for entry added in the resource agent. These are added in the main config file to workaround postgresql >= 12 changes
  run_command_in_node "${IP_VM02}" "sudo -u postgres touch /var/lib/postgresql/"${PGSQL_VERSION}"/tmp/recovery.conf"
  run_command_in_node "${IP_VM02}" "sudo -u postgres touch /var/lib/postgresql/"${PGSQL_VERSION}"/tmp/rep_mode.conf"
  # recovery.conf was integrated into postgresql.conf back in postgresql 12; so this differs from the guides
  # the standby_mode option was removed and replaced with adding a standby.signal file in the data directory
  run_command_in_node "${IP_VM02}" "sudo touch /var/lib/postgresql/"${PGSQL_VERSION}"/main/standby.signal"
  run_command_in_node "${IP_VM02}" "sudo pg_conftool "${PGSQL_VERSION}" main set primary_conninfo 'host=${IP_VM01} port=5432 user=postgres application_name=${VM02}'"
  run_command_in_node "${IP_VM02}" "sudo pg_conftool "${PGSQL_VERSION}" main set restore_command 'cp /var/lib/postgresql/"${PGSQL_VERSION}"/main/pg_archive/%f %p'"
  run_command_in_node "${IP_VM02}" "sudo pg_conftool "${PGSQL_VERSION}" main set recovery_target_timeline 'latest'"
  run_command_in_node "${IP_VM02}" "sudo pg_conftool "${PGSQL_VERSION}" main set listen_addresses '*'"
  run_command_in_node "${IP_VM02}" "sudo sed -i \"$ a ${PG_HBA}\" /etc/postgresql/"${PGSQL_VERSION}"/main/pg_hba.conf"
  run_command_in_node "${IP_VM02}" "sudo systemctl start postgresql"
  sleep 10
}

start_ha_pgsql_cluster() {
  run_command_in_node "${IP_VM01}" "sudo pcs property set stonith-enabled=false"
  run_command_in_node "${IP_VM01}" "sudo pcs property set no-quorum-policy=ignore"
  run_command_in_node "${IP_VM01}" "sudo pcs resource defaults update resource-stickiness='INFINITY'"
  run_command_in_node "${IP_VM01}" "sudo pcs resource defaults update migration-threshold='1'"
  # https://github.com/ClusterLabs/resource-agents/issues/620
  #  use /usr/lib/postgresql/"${PGSQL_VERSION}"/bin/pg_ctl instead of /usr/bin/pg_ctlcluster for pgctl
  # tmpdir must be set for pg >= 12 support: https://github.com/ClusterLabs/resource-agents/pull/1452/files
  run_command_in_node "${IP_VM01}" "sudo pcs resource create pgsql ocf:heartbeat:pgsql \
   pgctl='/usr/lib/postgresql/"${PGSQL_VERSION}"/bin/pg_ctl' \
   psql='/usr/bin/psql' \
   pgdata='/var/lib/postgresql/"${PGSQL_VERSION}"/main' \
   tmpdir='/var/lib/postgresql/"${PGSQL_VERSION}"/tmp' \
   config='/etc/postgresql/"${PGSQL_VERSION}"/main/postgresql.conf' \
   socketdir='/var/run/postgresql' \
   rep_mode='sync' \
   node_list='${VM01} ${VM02}' \
   restore_command='cp /var/lib/postgresql/"${PGSQL_VERSION}"/main/pg_archive/%f %p' \
   primary_conninfo_opt='keepalives_idle=60 keepalives_interval=5 keepalives_count=5' \
   master_ip='${IP_VM01}' \
   restart_on_promote='true' \
   op start   timeout='60s' interval='0s'  on-fail='restart' \
   op monitor timeout='60s' interval='4s' on-fail='restart' \
   op monitor timeout='60s' interval='3s'  on-fail='restart' role='Master' \
   op promote timeout='300s' interval='0s'  on-fail='restart' \
   op demote  timeout='60s' interval='0s'  on-fail='stop' \
   op stop    timeout='60s' interval='0s'  on-fail='block' \
   op notify  timeout='60s' interval='0s' \
   promotable promoted-max=1 promoted-node-max=1 clone-max=2 clone-node-max=1 notify=true --wait=180"
  sleep 30
}

oneTimeSetUp() {
  get_network_data_nic1
  setup_cluster
  setup_main_server
  setup_replica
  start_ha_pgsql_cluster
}

test_postgresql_is_started() {
  vm1_is_started=$(run_command_in_node "${IP_VM01}" "pg_isready -h localhost -p 5432")
  echo ${vm1_is_started} | grep -q "localhost:5432 - accepting connections"
  assertTrue $?
  vm2_is_started=$(run_command_in_node "${IP_VM02}" "pg_isready -h localhost -p 5432")
  echo ${vm2_is_started} | grep -q "localhost:5432 - accepting connections"
  assertTrue $?
}

test_replication_success() {
  replication_status=$(run_command_in_node "${IP_VM01}" "sudo -u postgres psql -c 'select client_addr,sync_state from pg_stat_replication;' 2>&1")
  echo ${replication_status} | grep -q "${IP_VM02}.*sync"
  assertTrue $?
}

test_expected_resource_status() {
  status_output=$(run_command_in_node "${IP_VM01}" "sudo pcs status --full")
  echo $status_output | grep -q "Promoted ${VM01}"
  assertTrue $?
  echo $status_output | grep -q "Unpromoted ${VM02}"
  assertTrue $?
}

test_read_write_expectations() {
  # use inactive node as client
  run_command_in_node "${IP_VM03}" "DEBIAN_FRONTEND=noninteractive sudo apt-get install -y postgresql-client > /dev/null"
  run_command_in_node "${IP_VM01}" "sudo -u postgres psql -c 'create database ha_test;' > /dev/null 2>&1"
  run_command_in_node "${IP_VM01}" "sudo -u postgres psql -c \"create user ha_user with encrypted password 'ha_pass';\" > /dev/null 2>&1"
  run_command_in_node "${IP_VM01}" "sudo -u postgres psql -c 'grant all privileges on database ha_test to ha_user' > /dev/null 2>&1"
  # This is needed starting from postgresql-15 due to
  # https://www.postgresql.org/docs/14/ddl-schemas.html#DDL-SCHEMAS-PATTERNS
  run_command_in_node "${IP_VM01}" "sudo -u postgres psql -c 'ALTER DATABASE ha_test OWNER TO ha_user;' > /dev/null 2>&1"
  run_command_in_node "${IP_VM03}" "echo '${IP_VM01}:5432:ha_test:ha_user:ha_pass' > .pgpass"
  run_command_in_node "${IP_VM03}" "echo '${IP_VM02}:5432:ha_test:ha_user:ha_pass' >> .pgpass"
  run_command_in_node "${IP_VM03}" "chmod 0600 .pgpass"
  run_command_in_node "${IP_VM03}" "psql -h ${IP_VM01} -p 5432 -d ha_test -U ha_user -w -c 'CREATE TABLE ubuntu (id INT PRIMARY KEY, txt VARCHAR(255))' > /dev/null 2>&1"
  run_command_in_node "${IP_VM03}" "psql -h ${IP_VM01} -p 5432 -d ha_test -U ha_user -w -c \"INSERT INTO ubuntu (id, txt) VALUES (1, 'noble')\" > /dev/null 2>&1"
  noble_db_entry=$(run_command_in_node "${IP_VM03}" "psql -h ${IP_VM01} -p 5432 -d ha_test -U ha_user -w -c 'SELECT * FROM ubuntu'")
  echo ${noble_db_entry} | grep -q noble
  assertTrue $?
  # read only
  noble_ro_db_entry=$(run_command_in_node "${IP_VM03}" "psql -h ${IP_VM02} -p 5432 -d ha_test -U ha_user -w -c 'SELECT * FROM ubuntu'")
  echo ${noble_ro_db_entry} | grep -q noble
  assertTrue $?
  forbidden_insert=$(run_command_in_node "${IP_VM03}" "psql -h ${IP_VM02} -p 5432 -d ha_test -U ha_user -w -c \"INSERT INTO ubuntu (id, txt) VALUES (2, 'jammy')\" 2>&1")
  echo $forbidden_insert | grep -q 'cannot execute INSERT in a read-only transaction'
  assertTrue $?
  # verify nothing was written
  jammy_db_entry=$(run_command_in_node "${IP_VM03}" "psql -h ${IP_VM02} -p 5432 -d ha_test -U ha_user -w -c 'SELECT * FROM ubuntu'")
  echo ${jammy_db_entry} | grep -q jammy
  assertFalse $?
}

test_expected_resource_promotion() {
  run_command_in_node "${IP_VM01}" "sudo pkill -9 postgres"
  sleep 15
  while run_command_in_node "${IP_VM01}" "sudo pcs status --full" | grep 'Promoting'; do
    sleep 5
  done
  status_output=$(run_command_in_node "${IP_VM01}" "sudo pcs status --full")
  echo $status_output | grep -q "Promoted ${VM02}"
  assertTrue $?
}

test_promoted_db_server() {
  run_command_in_node "${IP_VM03}" "psql -h ${IP_VM02} -p 5432 -d ha_test -U ha_user -w -c \"INSERT INTO ubuntu (id, txt) VALUES (2, 'jammy')\" > /dev/null"
  db_entries=$(run_command_in_node "${IP_VM03}" "psql -h ${IP_VM02} -p 5432 -d ha_test -U ha_user -w -c 'SELECT * FROM ubuntu'")
  echo ${db_entries} | grep -q noble
  assertTrue $?
  echo ${db_entries} | grep -q jammy
  assertTrue $?
}

load_shunit2
