# shellcheck shell=bash

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"
# shellcheck disable=SC1090
. "$(dirname "$0")/../vm_utils.sh"

oneTimeSetUp() {
  get_network_data_nic1

  readonly RESOURCE_NAME="fence-mpath"
  readonly MPATH_DEVICE="/dev/mapper/mpatha"
  readonly NODE1_RES_KEY="1"
  readonly NODE2_RES_KEY="2"
  readonly NODE3_RES_KEY="3"
}

configure_cluster_properties() {
  run_command_in_node "${IP_VM01}" "sudo crm configure property stonith-enabled=on"
  run_command_in_node "${IP_VM01}" "sudo crm configure property stonith-action=reboot"
  run_command_in_node "${IP_VM01}" "sudo crm configure property no-quorum-policy=stop"
  run_command_in_node "${IP_VM01}" "sudo crm configure property have-watchdog=false"
}

add_res_key_to_multipath_config() {
  run_command_in_node "${IP_VM01}" "sudo sed -i '/^}$/i reservation_key 0x${NODE1_RES_KEY}' /etc/multipath.conf"
  run_command_in_node "${IP_VM02}" "sudo sed -i '/^}$/i reservation_key 0x${NODE2_RES_KEY}' /etc/multipath.conf"
  run_command_in_node "${IP_VM03}" "sudo sed -i '/^}$/i reservation_key 0x${NODE3_RES_KEY}' /etc/multipath.conf"
  run_in_all_nodes "sudo systemctl reload multipathd"
}

configure_fence_mpath() {
  add_res_key_to_multipath_config
  run_command_in_node "${IP_VM01}" "sudo crm configure primitive ${RESOURCE_NAME} stonith:fence_mpath \
	  params \
	  pcmk_host_map=\"${VM01}:${NODE1_RES_KEY};${VM02}:${NODE2_RES_KEY};${VM03}:${NODE3_RES_KEY}\" \
	  pcmk_host_argument=key \
	  pcmk_monitor_action=metadata \
	  pcmk_reboot_action=off \
	  devices=${MPATH_DEVICE} \
	  meta provides=unfencing"
}

test_fence_mpath_is_started() {
  configure_cluster_properties
  configure_fence_mpath

  sleep 15
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo crm status")
  echo "${cluster_status}" | grep "${RESOURCE_NAME}" | grep Started
  assertTrue $?
}

test_all_mpath_reservation_keys_are_created() {
  run_command_in_node "${IP_VM01}" "sudo mpathpersist -i -k -d ${MPATH_DEVICE} | grep -A3 '6 registered reservation keys'"
  assertTrue $?
}

test_fence_node_running_the_resource() {
  find_node_running_resource "${RESOURCE_NAME}"
  find_node_to_move_resource "${RESOURCE_NAME}"

  # Do not accept connection from the unique network interface to get the node
  # running the resource disconnected from the Corosync ring.
  run_command_in_node "${IP_RESOURCE}" "sudo iptables -A INPUT -j DROP"

  # Check if the node got offline
  sleep 30
  cluster_status=$(run_command_in_node "${IP_TARGET}" "sudo crm status")
  echo "${cluster_status}" | grep "${VM_RESOURCE}" | grep -i offline
  assertTrue $?

  # Check if its reservation key was removed
  run_command_in_node "${IP_TARGET}" "sudo mpathpersist -i -k -d ${MPATH_DEVICE} | grep -A2 '4 registered reservation keys'"
  assertTrue $?

  # Check if the resource is still correctly running in another node
  cluster_status=$(run_command_in_node "${IP_TARGET}" "sudo crm status")
  echo "${cluster_status}" | grep "${RESOURCE_NAME}" | grep Started
  assertTrue $?
}

load_shunit2
