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
  readonly IQN="iqn.2022-02.com.test"
  readonly DEVICE="/dev/mapper/mpatha"
  readonly LUN="0"
}

configure_cluster_properties() {
  run_command_in_node "${IP_VM01}" "sudo crm configure property stonith-enabled=off"
}

configure_resources() {
  run_command_in_node "${IP_VM01}" "sudo crm configure<<EOF
primitive ${TARGET_RESOURCE_NAME} iSCSITarget \
	  params implementation=lio-t iqn=\"${IQN}:target\"
primitive ${LUN_RESOURCE_NAME} iSCSILogicalUnit \
	  params implementation=lio-t target_iqn=\"${IQN}:target\" path=\"${DEVICE}\" lun=${LUN}
group iscsi-target-group ${TARGET_RESOURCE_NAME} ${LUN_RESOURCE_NAME}
commit
EOF"
}

test_iscsi_target_resources_are_started() {
  configure_cluster_properties
  configure_resources

  # Wait for changes to be applied and check if the resource are started
  sleep 5
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo crm status")
  echo "${cluster_status}" | grep "${TARGET_RESOURCE_NAME}" | grep Started
  assertTrue "Could not infer ${TARGET_RESOURCE_NAME} readiness from status output:\n${cluster_status}" $?
  echo "${cluster_status}" | grep "${LUN_RESOURCE_NAME}" | grep Started
  assertTrue "Could not infer ${LUN_RESOURCE_NAME} readiness from status output:\n${cluster_status}" $?

  # Check if both resource are running on the same node
  target_location=$(run_command_in_node "${IP_VM01}" \
			"sudo crm resource locate ${TARGET_RESOURCE_NAME} | cut -d ':' -f2")
  lun_location=$(run_command_in_node "${IP_VM01}" \
			"sudo crm resource locate ${LUN_RESOURCE_NAME} | cut -d ':' -f2")
  [[ "${target_location}" == "${lun_location}" ]]
  assertTrue "Could not infer ${TARGET_RESOURCE_NAME} and ${LUN_RESOURCE_NAME} colocation from the status output:\n${cluster_status}" $?
}

check_iscsi_info() {
  IP="${1}"

  target_info=$(run_command_in_node "${IP}" "sudo targetcli iscsi/${IQN}:target ls")

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
  run_command_in_node "${IP_VM01}" "sudo crm resource move ${TARGET_RESOURCE_NAME} ${VM_TARGET}"
  sleep 10

  # Check if both resources are started in the target node
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo crm status")
  echo "${cluster_status}" | grep "${TARGET_RESOURCE_NAME}" | grep Started | grep "${VM_TARGET}"
  assertTrue "Could not infer ${TARGET_RESOURCE_NAME} location correctness from the status info:\n${cluster_status}" $?
  echo "${cluster_status}" | grep "${LUN_RESOURCE_NAME}" | grep Started | grep "${VM_TARGET}"
  assertTrue "Could not infer ${LUN_RESOURCE_NAME} location correctness from the status info:\n${cluster_status}" $?

  # Check if the iSCSI target config was moved to the target node
  check_iscsi_info "${IP_TARGET}"
}

load_shunit2
