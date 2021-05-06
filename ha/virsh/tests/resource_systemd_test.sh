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
ExecStart=/bin/bash -c \"while true; do echo \$(hostname) | netcat -q 0 -l -p 8080; done\"

[Install]
WantedBy=multi-user.target
EOF
"
  run_in_all_nodes "sudo cp /home/ubuntu/gethostname.service /etc/systemd/system/"
  run_in_all_nodes "sudo systemctl daemon-reload"
}

oneTimeSetUp() {
  get_all_nodes_ip_address
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
  # Find out in which node the resource is running
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo crm status | grep ${RESOURCE_NAME}")
  node_running_resource=$(echo "${cluster_status}" | rev | cut -d ' ' -f 1 | rev)

  # Get the IP address of the VM running the resource
  case $node_running_resource in
    "${VM01}")
      IP_RESOURCE="${IP_VM01}"
      VM_RESOURCE="${VM01}"
      ;;
    "${VM02}")
      IP_RESOURCE="${IP_VM02}"
      VM_RESOURCE="${VM02}"
      ;;
    *)
      IP_RESOURCE="${IP_VM03}"
      VM_RESOURCE="${VM03}"
      ;;
  esac

  # netcat uses an old version of the HTTP protocol
  running_node=$(curl --silent --http0.9 "${IP_RESOURCE}":8080)
  [[ "${running_node}" == *"${VM_RESOURCE}"* ]]
  assertTrue $?
}

test_move_resource() {
  # Find which node is not running the resource
  case $node_running_resource in
    "${VM01}")
      VM_TARGET="${VM02}"
      IP_TARGET="${IP_VM02}"
      ;;
    "${VM02}")
      VM_TARGET="${VM03}"
      IP_TARGET="${IP_VM03}"
      ;;
    *)
      VM_TARGET="${VM01}"
      IP_TARGET="${IP_VM01}"
      ;;
  esac

  # Move resource to another node
  run_command_in_node "${IP_VM01}" "sudo crm resource move ${RESOURCE_NAME} ${VM_TARGET}"
  sleep 5

  # Check if the resource is started in the target node
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo crm status")
  echo "${cluster_status}" | grep "${RESOURCE_NAME}" | grep Started | grep "${VM_TARGET}"
  assertTrue $?

  # Check if the systemd service is running in the target node
  running_node=$(curl --silent --http0.9 "${IP_TARGET}":8080)
  [[ "${running_node}" == *"${VM_TARGET}"* ]]
  assertTrue $?

  # Make sure the service is not running on the previous node
  running_in_previous_node=0
  if curl --silent --http0.9 "${VM_RESOURCE}":8080; then
    running_in_previous_node=1
  fi
  assertTrue "${running_in_previous_node}"
}

load_shunit2
