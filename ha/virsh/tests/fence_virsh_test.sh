# shellcheck shell=bash

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"
# shellcheck disable=SC1090
. "$(dirname "$0")/../vm_utils.sh"

oneTimeSetUp() {
  get_all_nodes_ip_address

  readonly HOST_IP="192.168.122.1"
  readonly HOST_USER="${USER}"
  readonly PRIVATE_SSH_KEY="/home/ubuntu/.ssh/id_rsa"
}

test_cluster_nodes_are_online() {
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo crm status")
  nodes_online=$(echo "${cluster_status}" | grep -A1 "Node List" | grep Online)

  for vm in "${VM01}" "${VM02}" "${VM03}"; do
    [[ "${nodes_online}" == *"${vm}"* ]]
    assertTrue $?
  done
}

configure_cluster_properties() {
  run_command_in_node "${IP_VM01}" "sudo crm configure property stonith-enabled=on"
  run_command_in_node "${IP_VM01}" "sudo crm configure property stonith-action=reboot"
  run_command_in_node "${IP_VM01}" "sudo crm configure property no-quorum-policy=stop"
  run_command_in_node "${IP_VM01}" "sudo crm configure property have-watchdog=false"
}

configure_fence_virsh() {
  node="${1}"
  run_command_in_node "${IP_VM01}" "sudo crm configure primitive fence-${node} stonith:fence_virsh \
	  params ip=${HOST_IP} ssh=true plug=${node} login=${HOST_USER} \
	  identity_file=${PRIVATE_SSH_KEY} use_sudo=true delay=1"
  run_command_in_node "${IP_VM01}" "sudo crm configure location fence-${node}-location \
	  fence-${node} -inf: ${node}"
}


test_fence_virsh_is_started() {
  configure_cluster_properties
  configure_fence_virsh "${VM03}"

  sleep 15
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo crm status")
  echo "${cluster_status}" | grep "fence-${VM03}" | grep Started
  assertTrue $?
}

test_fence_a_node() {
  # Do not accept connection from the unique network interface to get node03
  # disconnected from the Corosync ring.
  run_command_in_node "${IP_VM03}" "sudo iptables -A INPUT -j DROP"

  # Check if node03 got offline
  sleep 20
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo crm status")
  echo "${cluster_status}" | grep node03 | grep -i offline
  assertTrue $?

  # Check if node03 is back online after rebooting
  sleep 60
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo crm status")
  echo "${cluster_status}" | grep node03 | grep Online
  assertTrue $?
}

load_shunit2
