# shellcheck shell=bash

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"
# shellcheck disable=SC1090
. "$(dirname "$0")/../vm_utils.sh"

install_targetcli() {
  run_in_all_nodes "DEBIAN_FRONTEND=noninteractive sudo apt-get install -y targetcli-fb >/dev/null"
}

oneTimeSetUp() {
  get_network_data_nic1
  install_targetcli

  readonly TARGET_RESOURCE_NAME="iscsi-target-rsc"
  readonly LUN_RESOURCE_NAME="iscsi-lun0-rsc"
  readonly RESOURCE_GROUP="iscsi-target-group"
  readonly TARGET="${IQN}:${VM_SERVICES_ISCSI_TARGET}"
  readonly DEVICE="/dev/mapper/mpatha"
  readonly LUN="0"
}

configure_cluster_properties() {
  run_command_in_node "${IP_VM01}" "sudo pcs property set stonith-enabled=false"
}

configure_resources() {
 run_command_in_node "${IP_VM01}" "sudo pcs resource create ${TARGET_RESOURCE_NAME} \
	 ocf:heartbeat:iSCSITarget \
	 implementation=lio-t \
	 iqn=\"${TARGET}\" \
	 --group ${RESOURCE_GROUP} \
	 --wait=60"
 run_command_in_node "${IP_VM01}" "sudo pcs resource create ${LUN_RESOURCE_NAME} \
	 ocf:heartbeat:iSCSILogicalUnit \
	 implementation=lio-t \
	 target_iqn=\"${TARGET}\" \
	 path=\"${DEVICE}\" \
	 lun=${LUN} \
	 --group ${RESOURCE_GROUP} \
	 --wait=60"
}

test_iscsi_target_resources_are_started() {
  configure_cluster_properties
  configure_resources

  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo pcs status")
  echo "${cluster_status}" | grep "${TARGET_RESOURCE_NAME}" | grep Started
  assertTrue "Could not infer ${TARGET_RESOURCE_NAME} readiness from status output:\n${cluster_status}" $?
  echo "${cluster_status}" | grep "${LUN_RESOURCE_NAME}" | grep Started
  assertTrue "Could not infer ${LUN_RESOURCE_NAME} readiness from status output:\n${cluster_status}" $?

  # Check if both resource are running on the same node
  target_location=$(run_command_in_node "${IP_VM01}" \
			"sudo pcs resource status ${TARGET_RESOURCE_NAME} | \
			 grep ${TARGET_RESOURCE_NAME} | sed -r 's,.*Started (.*)$,\1,'")
  lun_location=$(run_command_in_node "${IP_VM01}" \
			"sudo pcs resource status ${LUN_RESOURCE_NAME} | \
			 grep ${LUN_RESOURCE_NAME} | sed -r 's,.*Started (.*)$,\1,'")
  [[ "${target_location}" == "${lun_location}" ]]
  assertTrue "Could not infer ${TARGET_RESOURCE_NAME} and ${LUN_RESOURCE_NAME} colocation from the status output:\n${cluster_status}" $?
}

check_iscsi_info() {
  IP="${1}"

  target_info=$(run_command_in_node "${IP}" "sudo targetcli iscsi/${TARGET} ls")

  # Check if IQN was correctly configured
  echo "${target_info}" | grep "${IQN}" | grep target
  assertTrue "Could not infer ${IQN} correctness from the iSCSI target info:\n${target_info}" $?

  # Check if lun0 was correctly configured
  echo "${target_info}" | grep "${LUN}" | grep "${DEVICE}"
  assertTrue "Could not infer ${LUN} and ${DEVICE} correctness from the iSCSI target info:\n${target_info}" $?
}

test_iscsi_target_info() {
  find_node_running_resource "${TARGET_RESOURCE_NAME}"
  check_iscsi_info "${IP_RESOURCE}"
}

test_move_resource() {
  find_node_to_move_resource "${TARGET_RESOURCE_NAME}"

  # Move resource to another node
  run_command_in_node "${IP_VM01}" "sudo pcs resource move ${TARGET_RESOURCE_NAME} ${VM_TARGET} --wait=60"

  # Check if both resources are started in the target node
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo pcs status")
  echo "${cluster_status}" | grep "${TARGET_RESOURCE_NAME}" | grep Started | grep "${VM_TARGET}"
  assertTrue "Could not infer ${TARGET_RESOURCE_NAME} location correctness from the status info:\n${cluster_status}" $?
  echo "${cluster_status}" | grep "${LUN_RESOURCE_NAME}" | grep Started | grep "${VM_TARGET}"
  assertTrue "Could not infer ${LUN_RESOURCE_NAME} location correctness from the status info:\n${cluster_status}" $?

  # Check if the iSCSI target config was moved to the target node
  check_iscsi_info "${IP_TARGET}"
}

load_shunit2
