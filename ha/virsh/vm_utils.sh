# shellcheck shell=bash

UBUNTU_SERIES="${UBUNTU_SERIES:-impish}"

VM_SERVICES="services-${UBUNTU_SERIES}"
IQN="iqn.$(date '+%Y-%m').com.test.storage"

VM_SERVICES_ISCSI_TARGET="target01"
VM01_ISCSI_INITIATOR="initiator01"
VM02_ISCSI_INITIATOR="initiator02"
VM03_ISCSI_INITIATOR="initiator03"

VM01="ha-agent-virsh-${UBUNTU_SERIES}-${AGENT}-node01"
VM02="ha-agent-virsh-${UBUNTU_SERIES}-${AGENT}-node02"
VM03="ha-agent-virsh-${UBUNTU_SERIES}-${AGENT}-node03"

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

get_vm_services_ip_address() {
  IP_VM_SERVICES=$(virsh domifaddr "${VM_SERVICES}" | grep ipv4 | xargs | cut -d ' ' -f4 | cut -d '/' -f1)
}

get_all_nodes_ip_address() {
  IP_VM01=$(virsh domifaddr "${VM01}" | grep ipv4 | xargs | cut -d ' ' -f4 | cut -d '/' -f1)
  IP_VM02=$(virsh domifaddr "${VM02}" | grep ipv4 | xargs | cut -d ' ' -f4 | cut -d '/' -f1)
  IP_VM03=$(virsh domifaddr "${VM03}" | grep ipv4 | xargs | cut -d ' ' -f4 | cut -d '/' -f1)
}

run_command_in_node() {
  NODE="${1}"
  CMD="${2}"
  ${SSH} ubuntu@"${NODE}" "${CMD}" || exit 1
}

run_in_all_nodes() {
  CMD="${1}"
  for node_ip in "${IP_VM01}" "${IP_VM02}" "${IP_VM03}"; do
    ${SSH} ubuntu@"${node_ip}" "${CMD}"
  done
}

copy_to_all_nodes() {
  FILE="${1}"
  for node_ip in "${IP_VM01}" "${IP_VM02}" "${IP_VM03}"; do
    copy_to_node "${node_ip}" "${FILE}"
  done
}

copy_to_node() {
  NODE="${1}"
  FILE="${2}"
  ${SCP} "${FILE}" ubuntu@"${NODE}":/home/ubuntu/
}

get_name_node_running_resource() {
  RES_NAME="${1}"
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo crm status | grep ${RES_NAME}")
  node_running_resource=$(echo "${cluster_status}" | rev | cut -d ' ' -f 1 | rev)
}

find_node_running_resource() {
  RES_NAME="${1}"
  get_name_node_running_resource "${RES_NAME}"

  # Get the IP address of the VM running the resource
  case $node_running_resource in
    "${VM01}")
      export IP_RESOURCE="${IP_VM01}"
      export VM_RESOURCE="${VM01}"
      ;;
    "${VM02}")
      export IP_RESOURCE="${IP_VM02}"
      export VM_RESOURCE="${VM02}"
      ;;
    *)
      export IP_RESOURCE="${IP_VM03}"
      export VM_RESOURCE="${VM03}"
      ;;
  esac
}

find_node_to_move_resource() {
  RES_NAME="${1}"
  get_name_node_running_resource "${RES_NAME}"

  case $node_running_resource in
    "${VM01}")
      export IP_TARGET="${IP_VM02}"
      export VM_TARGET="${VM02}"
      ;;
    "${VM02}")
      export IP_TARGET="${IP_VM03}"
      export VM_TARGET="${VM03}"
      ;;
    *)
      export IP_TARGET="${IP_VM01}"
      export VM_TARGET="${VM01}"
      ;;
  esac
}

block_until_cloud_init_is_done() {
  NODE="${1}"

  # set debconf frontend to Noninteractive
  run_command_in_node "${NODE}" "echo 'debconf debconf/frontend select Noninteractive' | sudo debconf-set-selections"
  run_command_in_node "${NODE}" "cloud-init status --wait"
}
