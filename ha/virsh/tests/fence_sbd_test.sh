# shellcheck shell=bash

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"
# shellcheck disable=SC1090
. "$(dirname "$0")/../vm_utils.sh"

oneTimeSetUp() {
  get_network_data_nic1

  readonly RESOURCE_NAME="fence-sbd"
  readonly MPATH_DEVICE="/dev/mapper/mpatha"
}

configure_cluster_properties() {
  run_command_in_node "${IP_VM01}" "sudo pcs property set stonith-enabled=true"
  run_command_in_node "${IP_VM01}" "sudo pcs property set stonith-timeout=30"
  run_command_in_node "${IP_VM01}" "sudo pcs property set stonith-action=reboot"
  run_command_in_node "${IP_VM01}" "sudo pcs property set no-quorum-policy=stop"
  run_command_in_node "${IP_VM01}" "sudo pcs property set have-watchdog=true"
}

configure_watchdog() {
  run_in_all_nodes "sudo apt-get install -y watchdog"
  run_in_all_nodes "sudo modprobe softdog"
  run_in_all_nodes "sudo sed -i 's#watchdog_module=\"none\"#watchdog_module=\"softdog\"#' /etc/default/watchdog"
}

configure_sbd() {
  run_command_in_node "${IP_VM01}" "sudo pcs cluster stop --all"
  run_in_all_nodes "sudo apt-get install -y sbd"
  run_in_all_nodes "sudo systemctl enable sbd"
  run_in_all_nodes "sudo sed -i '/^# *SBD_DEVICE=/cSBD_DEVICE=\"${MPATH_DEVICE}\"' /etc/default/sbd"
  run_command_in_node "${IP_VM01}" "sudo sbd -d ${MPATH_DEVICE} create"
  configure_watchdog
  run_command_in_node "${IP_VM01}" "sudo pcs cluster start --all"
  sleep 10
}

configure_fence_sbd() {
  configure_sbd
  run_command_in_node "${IP_VM01}" "sudo pcs stonith create ${RESOURCE_NAME} fence_sbd \
	  devices=${MPATH_DEVICE}"
}

test_fence_sbd_is_started() {
  configure_cluster_properties
  configure_fence_sbd

  sleep 15
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo pcs status")
  echo "${cluster_status}" | grep "${RESOURCE_NAME}" | grep Started
  assertTrue $?
}

test_all_nodes_listed_by_sbd_device() {
  number_of_nodes=$(run_command_in_node "${IP_VM01}" "sudo sbd -d ${MPATH_DEVICE} list | wc -l")
  [[ "${number_of_nodes}" == "3" ]]
  assertTrue $?
}

test_fence_node_running_the_resource() {
  find_node_running_resource "${RESOURCE_NAME}"
  find_node_to_move_resource "${RESOURCE_NAME}"

  # Do not accept connection from the unique network interface to get the node
  # running the resource disconnected from the Corosync ring.
  run_command_in_node "${IP_RESOURCE}" "sudo iptables -A INPUT -j DROP"

  # Check if the node got offline
  sleep 20
  cluster_status=$(run_command_in_node "${IP_TARGET}" "sudo pcs status")
  echo "${cluster_status}" | grep "${VM_RESOURCE}" | grep -i offline
  assertTrue $?

  # Check if the fenced node is marked as reset
  sbd_list=$(run_command_in_node "${IP_TARGET}" "sudo sbd -d ${MPATH_DEVICE} list")
  echo "${sbd_list}" | grep "${VM_RESOURCE}" | grep reset
  assertTrue $?

  # Check if the resource is still correctly running in another node
  cluster_status=$(run_command_in_node "${IP_TARGET}" "sudo pcs status")
  echo "${cluster_status}" | grep "${RESOURCE_NAME}" | grep Started
  assertTrue $?
}

load_shunit2
