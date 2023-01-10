# shellcheck shell=bash

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"
# shellcheck disable=SC1090
. "$(dirname "$0")/../vm_utils.sh"

oneTimeSetUp() {
  get_network_data_nic1

  readonly RESOURCE_NAME="fence-scsi"
  readonly SCSI_DEVICE="/dev/sda"
}

configure_cluster_properties() {
  run_command_in_node "${IP_VM01}" "sudo pcs property set stonith-enabled=true"
  run_command_in_node "${IP_VM01}" "sudo pcs property set stonith-action=reboot"
  run_command_in_node "${IP_VM01}" "sudo pcs property set no-quorum-policy=stop"
}

configure_fence_scsi() {
  run_command_in_node "${IP_VM01}" "sudo pcs stonith create ${RESOURCE_NAME} fence_scsi \
	  pcmk_host_list=\"${VM01} ${VM02} ${VM03}\" devices=${SCSI_DEVICE} \
	  meta provides=unfencing"
}

test_fence_scsi_is_started() {
  configure_cluster_properties
  configure_fence_scsi

  sleep 15
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo pcs status")
  echo "${cluster_status}" | grep "${RESOURCE_NAME}" | grep Started
  assertTrue $?
}

test_all_scsi_reservation_keys_are_created() {
  run_command_in_node "${IP_VM01}" "sudo sg_persist ${SCSI_DEVICE} | grep -A3 '3 registered reservation keys'"
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
  cluster_status=$(run_command_in_node "${IP_TARGET}" "sudo pcs status")
  echo "${cluster_status}" | grep "${VM_RESOURCE}" | grep -i offline
  assertTrue $?

  # Check if its reservation key was removed
  run_command_in_node "${IP_TARGET}" "sudo sg_persist ${SCSI_DEVICE} | grep -A2 '2 registered reservation keys'"
  assertTrue $?

  # Check if the resource is still correctly running in another node
  cluster_status=$(run_command_in_node "${IP_TARGET}" "sudo pcs status")
  echo "${cluster_status}" | grep "${RESOURCE_NAME}" | grep Started
  assertTrue $?
}

load_shunit2
