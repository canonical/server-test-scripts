# shellcheck shell=bash

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"
# shellcheck disable=SC1090
. "$(dirname "$0")/../vm_utils.sh"

oneTimeSetUp() {
  get_all_nodes_ip_address

  readonly FLOATING_IP="192.168.122.255"
  readonly NETMASK="24"
  readonly RESOURCE_NAME="cluster-ip"
}

configure_cluster_properties() {
  run_command_in_node "${IP_VM01}" "sudo crm configure property stonith-enabled=off"
}

configure_ipaddr2_resource() {
  NAME="${1}"
  IP="${2}"
  MASK="${3}"
  run_command_in_node "${IP_VM01}" "sudo crm configure primitive ${NAME} ocf:heartbeat:IPaddr2 \
	  ip=${IP} cidr_netmask=${MASK} op monitor interval=30s"
}

test_ipaddr2_is_started() {
  configure_cluster_properties
  configure_ipaddr2_resource "${RESOURCE_NAME}" "${FLOATING_IP}" "${NETMASK}"

  run_command_in_node "${IP_VM01}" "sudo crm cluster wait_for_startup"
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo crm status")
  echo "${cluster_status}" | grep "${RESOURCE_NAME}" | grep Started
  assertTrue $?
}

test_if_correct_ip_address_is_set() {
  find_node_running_resource "${RESOURCE_NAME}"

  # Check if the IP address was correctly set as secondary in the default NIC
  ip_address_out=$(run_command_in_node "${IP_RESOURCE}" "ip address")
  echo "${ip_address_out}" | grep secondary | grep "${IP}/${NETMASK}"
  assertTrue $?
}

test_move_resource() {
  find_node_to_move_resource "${RESOURCE_NAME}"

  # Move resource to another VM
  run_command_in_node "${IP_VM01}" "sudo crm resource move ${RESOURCE_NAME} ${VM_TARGET}"
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo crm status")
  echo "${cluster_status}" | grep "${RESOURCE_NAME}" | grep Started
  assertTrue $?

  # Check if the IP address was correctly set as secondary in the default NIC
  ip_address_output=$(run_command_in_node "${IP_TARGET}" "ip address")
  echo "${ip_address_output}" | grep secondary | grep "${IP}/${NETMASK}"
  assertTrue $?
}

load_shunit2
