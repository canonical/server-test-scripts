# shellcheck shell=bash

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"
# shellcheck disable=SC1090
. "$(dirname "$0")/../vm_utils.sh"

setup_systemd_service() {
  run_in_all_nodes "DEBIAN_FRONTEND=noninteractive sudo apt-get install -y netcat >/dev/null"
  run_in_all_nodes "cat > /home/ubuntu/gethostname.service <<EOF
[Unit]
Description=foo

[Service]
ExecStart=/bin/bash -c \"while true; do echo \$(hostname) | netcat -l -N 8080; done\"

[Install]
WantedBy=multi-user.target
EOF
"
  run_in_all_nodes "sudo cp /home/ubuntu/gethostname.service /etc/systemd/system/"
  run_in_all_nodes "sudo systemctl daemon-reload"
}

oneTimeSetUp() {
  get_all_nodes_ip_addresses
  setup_systemd_service

  readonly RESOURCE_NAME="gethostname-service"
}

configure_cluster_properties() {
  run_command_in_node "${IP_VM01}" "sudo crm configure property stonith-enabled=off"
}

configure_systemd_resource() {
  NAME="${1}"
  run_command_in_node "${IP_VM01}" "sudo crm configure primitive ${NAME} systemd:gethostname"
}

test_systemd_resource_is_started() {
  configure_cluster_properties
  configure_systemd_resource "${RESOURCE_NAME}"

  # Wait for the systemd service to be started
  sleep 5
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo crm status")
  echo "${cluster_status}" | grep "${RESOURCE_NAME}" | grep Started
  assertTrue $?
}

test_if_hostname_is_correct() {
  find_node_running_resource "${RESOURCE_NAME}"

  running_node=$(netcat -d "${IP_RESOURCE}" 8080)
  [[ "${running_node}" == *"${VM_RESOURCE}"* ]]
  assertTrue $?
}

test_move_resource() {
  find_node_to_move_resource "${RESOURCE_NAME}"

  # Move resource to another node
  run_command_in_node "${IP_VM01}" "sudo crm resource move ${RESOURCE_NAME} ${VM_TARGET}"
  sleep 5

  # Check if the resource is started in the target node
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo crm status")
  echo "${cluster_status}" | grep "${RESOURCE_NAME}" | grep Started | grep "${VM_TARGET}"
  assertTrue $?

  # Check if the systemd service is running in the target node
  running_node=$(netcat -d "${IP_TARGET}" 8080)
  [[ "${running_node}" == *"${VM_TARGET}"* ]]
  assertTrue $?

  # Make sure the service is not running on the previous node
  running_in_previous_node=0
  if netcat -z "${VM_RESOURCE}" 8080; then
    running_in_previous_node=1
  fi
  assertTrue "${running_in_previous_node}"
}

load_shunit2
