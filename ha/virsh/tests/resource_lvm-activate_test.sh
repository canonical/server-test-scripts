# shellcheck shell=bash

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"
# shellcheck disable=SC1090
. "$(dirname "$0")/../vm_utils.sh"

setup_lvm() {
  run_in_all_nodes "DEBIAN_FRONTEND=noninteractive sudo apt-get install -y lvm2 >/dev/null"
  run_in_all_nodes "sudo sed -e '/system_id_source = \"none\"/s/none/uname/' -i /etc/lvm/lvm.conf"

  # The extra disk is usually /dev/vdc
  run_in_all_nodes "test -b /dev/vdc && sudo sgdisk -n 0:0:0 /dev/vdc >/dev/null"

  # LVM opperations
  run_in_all_nodes "sudo pvcreate /dev/vdc1 >/dev/null"
  run_in_all_nodes "sudo vgcreate ${VG} /dev/vdc1 >/dev/null"
  run_in_all_nodes "sudo lvcreate -l100%FREE -n ${VOL} ${VG} >/dev/null"
  run_in_all_nodes "sudo vgchange -an ${VG} >/dev/null"
}

oneTimeSetUp() {
  get_network_data_nic1

  readonly RESOURCE_NAME="lvm2-activator"
  readonly VG="clustervg"
  readonly VOL="clustervol"
  setup_lvm
}

configure_cluster_properties() {
  run_command_in_node "${IP_VM01}" "sudo pcs property set stonith-enabled=false"
}

configure_lvm_activate_resource() {
  NAME="${1}"
  VOLGROUP="${2}"
  run_command_in_node "${IP_VM01}" "sudo pcs resource create ${NAME} ocf:heartbeat:LVM-activate \
	  vgname=${VOLGROUP} vg_access_mode=system_id --wait=120"
}

test_lvm_activate_is_started() {
  configure_cluster_properties
  configure_lvm_activate_resource "${RESOURCE_NAME}" "${VG}"

  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo pcs status")
  echo "${cluster_status}" | grep "${RESOURCE_NAME}" | grep Started
  assertTrue $?
}

test_if_lvm_volume_device_is_created() {
  find_node_running_resource "${RESOURCE_NAME}"

  # Check if the LVM volume device is present in the node running the resource
  run_command_in_node "${IP_RESOURCE}" "test -L /dev/${VG}/${VOL}"
  assertTrue $?

  # Check if the logical volume has the attribute 'a' which means active
  run_command_in_node "${IP_RESOURCE}" "sudo lvs | grep ${VOL} | grep -q a"
  assertTrue $?

}

test_move_resource() {
  find_node_to_move_resource "${RESOURCE_NAME}"

  # Move resource to another VM
  run_command_in_node "${IP_VM01}" "sudo pcs resource move ${RESOURCE_NAME} ${VM_TARGET} --wait=60"
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo pcs status")
  echo "${cluster_status}" | grep "${RESOURCE_NAME}" | grep Started
  assertTrue $?

  # Check if the LVM volume device is present in the new node
  run_command_in_node "${IP_TARGET}" "test -L /dev/${VG}/${VOL}"
  assertTrue $?

  # Check if the logical volume has the attribute 'a' which means active in the new node
  run_command_in_node "${IP_TARGET}" "sudo lvs | grep ${VOL} | grep -q a"
  assertTrue $?

  # Check if the logical volume does not have the attribute 'a' which means inactive in the old node
  run_command_in_node "${IP_RESOURCE}" "sudo lvs | grep ${VOL} | grep -vq a"
  assertTrue $?
}

load_shunit2
