# shellcheck shell=bash

UBUNTU_SERIES="${UBUNTU_SERIES:-jammy}"

VM_SERVICES="ha-agent-virsh-${UBUNTU_SERIES::1}-${AGENT}-services"
IQN="iqn.$(date '+%Y-%m').com.test.storage"

VM_SERVICES_ISCSI_TARGET="target01"
VM01_ISCSI_INITIATOR="initiator01"
VM02_ISCSI_INITIATOR="initiator02"
VM03_ISCSI_INITIATOR="initiator03"

VM01="ha-agent-virsh-${UBUNTU_SERIES::1}-${AGENT}-node01"
VM02="ha-agent-virsh-${UBUNTU_SERIES::1}-${AGENT}-node02"
VM03="ha-agent-virsh-${UBUNTU_SERIES::1}-${AGENT}-node03"

HACLUSTER_USER="hacluster"
HACLUSTER_PASSWD="dummy12345"
CLUSTER_NAME="test-cluster"

# Interface names can only be 15 chars long.
HA_NETWORK="ha-${UBUNTU_SERIES::1}-${AGENT}"
HA_NETWORK=${HA_NETWORK::15}

DHCP_CLIENT="dhcpcd"
if [[ "${UBUNTU_SERIES}" == "jammy" ]] || [[ "${UBUNTU_SERIES}" == "mantic" ]]; then
  DHCP_CLIENT="dhclient"
fi

get_network_data_nic1() {
  IP_VM01=$(virsh domifaddr "${VM01}" | grep ipv4 | xargs | cut -d ' ' -f4 | cut -d '/' -f1)
  MAC_VM01=$(virsh domifaddr "${VM01}" | grep ipv4 | xargs | cut -d ' ' -f2)

  IP_VM02=$(virsh domifaddr "${VM02}" | grep ipv4 | xargs | cut -d ' ' -f4 | cut -d '/' -f1)
  MAC_VM02=$(virsh domifaddr "${VM02}" | grep ipv4 | xargs | cut -d ' ' -f2)

  IP_VM03=$(virsh domifaddr "${VM03}" | grep ipv4 | xargs | cut -d ' ' -f4 | cut -d '/' -f1)
  MAC_VM03=$(virsh domifaddr "${VM03}" | grep ipv4 | xargs | cut -d ' ' -f2)
}

get_network_data_nic2() {
  IP2_VM01=$(virsh domifaddr "${VM01}" | grep ipv4 | xargs | cut -d ' ' -f8 | cut -d '/' -f1)
  MAC2_VM01=$(virsh domifaddr "${VM01}" | grep ipv4 | xargs | cut -d ' ' -f6)

  IP2_VM02=$(virsh domifaddr "${VM02}" | grep ipv4 | xargs | cut -d ' ' -f8 | cut -d '/' -f1)
  MAC2_VM02=$(virsh domifaddr "${VM02}" | grep ipv4 | xargs | cut -d ' ' -f6)

  IP2_VM03=$(virsh domifaddr "${VM03}" | grep ipv4 | xargs | cut -d ' ' -f8 | cut -d '/' -f1)
  MAC2_VM03=$(virsh domifaddr "${VM03}" | grep ipv4 | xargs | cut -d ' ' -f6)
}

run_command_in_node() {
  NODE="${1}"
  CMD="${2}"
  ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      ubuntu@"${NODE}" \
      "${CMD}" || exit 1
}

get_name_first_nic() {
  NODE_IP="${1}"
  run_command_in_node "${NODE_IP}" 'find /sys/class/net/* ! -name "*lo" -printf "%f " | cut -d " " -f1'
}

get_name_second_nic() {
  NODE_IP="${1}"
  run_command_in_node "${NODE_IP}" 'find /sys/class/net/* ! -name "*lo" -printf "%f " | cut -d " " -f2'
}

get_vm_services_ip_addresses() {
  IP_VM_SERVICES=$(virsh domifaddr "${VM_SERVICES}" | grep ipv4 | xargs | cut -d ' ' -f4 | cut -d '/' -f1)

  # Workaround to get an IP address in the second network interface
  network_interface=$(get_name_second_nic "${IP_VM_SERVICES}")
  run_command_in_node "${IP_VM_SERVICES}" "sudo ${DHCP_CLIENT} ${network_interface}"
  sleep 10
  IP2_VM_SERVICES=$(virsh domifaddr "${VM_SERVICES}" | grep ipv4 | xargs | cut -d ' ' -f8 | cut -d '/' -f1)
}

run_in_all_nodes() {
  CMD="${1}"
  for node_ip in "${IP_VM01}" "${IP_VM02}" "${IP_VM03}"; do
    run_command_in_node "${node_ip}" "${CMD}"
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
  scp -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      "${FILE}" \
      ubuntu@"${NODE}":/home/ubuntu/
}

get_name_node_running_resource() {
  RES_NAME="${1}"
  cluster_status=$(run_command_in_node "${IP_VM01}" "sudo pcs resource status ${RES_NAME} | grep ${RES_NAME}")
  node_running_resource=$(echo "${cluster_status}" | sed -r 's,.*Started (.*)$,\1,')
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
  run_command_in_node "${NODE}" "flock /var/cache/debconf/config.dat true"
  run_command_in_node "${NODE}" "echo 'debconf debconf/frontend select Noninteractive' | sudo debconf-set-selections"
  run_command_in_node "${NODE}" " if ! cloud-init status --wait; then if [ "$?" -eq 1 ]; \
    then echo 'ERROR: cloud-init failed to initialize'; exit 1; fi; fi"
  sleep 5
}

backoff() {
  # Exponential backoff function. Positional args:
  # CONDITION_FUNCTION_NAME: Function to determine wheather to backoff. It must
  # return 0 when no waiting is needed or 1 when we want to wait.
  # BACKOFF_FACTOR: Factor for exponential backoff function. Default value: 2.
  # MAX_RETRIES: Maximum number of retries. This defaults to 7 so we wait at
  # most 254 seconds with the last wait being of 128 seconds.
  CONDITION_FUNCTION_NAME="${1}"
  BACKOFF_FACTOR="${2:-2}"
  MAX_RETRIES="${3:-7}"
  for i in $(seq 0 ${MAX_RETRIES}); do
    if [ $i -gt 0 ]; then
      sleep $((BACKOFF_FACTOR ** i))
    fi
    if $CONDITION_FUNCTION_NAME; then
      return 0
    fi
  done
  echo "WARNING: wait condition not matched for ${CONDITION_FUNCTION_NAME}"
  return 1
}
