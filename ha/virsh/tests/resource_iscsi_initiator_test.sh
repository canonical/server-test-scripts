# shellcheck shell=bash

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"
# shellcheck disable=SC1090
. "$(dirname "$0")/../vm_utils.sh"

target_add_acl() {
  run_command_in_node "${IP_VM_SERVICES}" "sudo targetcli iscsi/${TARGET}/tpg1/acls create ${IQN}:${INITIATOR}"
}

configure_initiator() {
  run_in_all_nodes "DEBIAN_FRONTEND=noninteractive sudo apt-get install -y open-iscsi >/dev/null"
  run_in_all_nodes "echo \"InitiatorName=${IQN}:${INITIATOR}\" | sudo tee /etc/iscsi/initiatorname.iscsi"
  run_in_all_nodes "sudo systemctl restart open-iscsi iscsid"
}

oneTimeSetUp() {
  get_network_data_nic1
  get_vm_services_ip_addresses

  readonly RESOURCE_NAME="iscsi-initiator-rsc"
  readonly INITIATOR="initiator-test"
  readonly TARGET="${IQN}:${VM_SERVICES_ISCSI_TARGET}"
  readonly PORTAL="${IP_VM_SERVICES}:3260"
  
  target_add_acl
  configure_initiator
}

configure_cluster_properties() {
  run_command_in_node "${IP_VM01}" "sudo pcs property set stonith-enabled=false"
}

configure_resource() {
  run_command_in_node "${IP_VM01}" "sudo pcs resource create ${RESOURCE_NAME} ocf:heartbeat:iscsi \
	  target=${TARGET} portal=${PORTAL} --wait"
}

test_iscsi_initiator_resource_is_started() {
  configure_cluster_properties
  configure_resource

  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo pcs status")
  echo "${cluster_status}" | grep "${RESOURCE_NAME}" | grep Started
  assertTrue "Could not infer ${RESOURCE_NAME} readiness from status output:\n${cluster_status}" $?
}

check_iscsi_block_info() {
  IP="${1}"
  iscsi_block_info=$(run_command_in_node "${IP}" "sudo lsblk --scsi")

  echo "${iscsi_block_info}" | grep "iscsi"
  assertTrue "Could not infer if block is provided via iSCSI:\n${iscsi_block_info}" $?
  echo "${iscsi_block_info}" | grep "LIO"
  assertTrue "Could not infer if block vendor is LIO:\n${iscsi_block_info}" $?
  echo "${iscsi_block_info}" | grep "iscsi-disk01"
  assertTrue "Could not infer if this is the correct block provided byt the iSCSI target:\n${iscsi_block_info}" $?
}

test_iscsi_disk_is_ready() {
  find_node_running_resource "${RESOURCE_NAME}"
  check_iscsi_block_info "${IP_RESOURCE}"
}

test_move_resource() {
  find_node_to_move_resource "${RESOURCE_NAME}"

  # Move resource to another node
  run_command_in_node "${IP_VM01}" "sudo pcs resource move ${RESOURCE_NAME} ${VM_TARGET} --wait"

  # Check if resource is started in the target node
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo pcs status")
  echo "${cluster_status}" | grep "${RESOURCE_NAME}" | grep Started | grep "${VM_TARGET}"
  assertTrue "Could not infer ${RESOURCE_NAME} location correctness from the status info:\n${cluster_status}" $?

  # Check if the iSCSI block device was moved to the target node
  check_iscsi_block_info "${IP_TARGET}"

  # Check if the iSCSI disk is not available anymore in the previous node
  iscsi_block=$(run_command_in_node "${IP_RESOURCE}" "sudo lsblk --scsi")
  [ -z "${iscsi_block}" ]
  assertTrue "Could not infer if the iSCSI block is not available:\n${iscsi_block}" $?
}

load_shunit2
