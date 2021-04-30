#!/bin/bash

set -eux -o pipefail

# shellcheck disable=SC1090
. "$(dirname "$0")/vm_utils.sh"

WORK_DIR="${1:-$(pwd)}"
CONFIG_DIR="${2:-"${WORK_DIR}/config"}"

CREATE_VM_SCRIPT="$(pwd)/create-vm.sh"

check_requirements() {
    hash virsh ssh-keygen wget virt-install qemu-img cloud-localds uuidgen || exit 127
}

create_nodes() {
  for vm in "${VM01}" "${VM02}" "${VM03}"; do
    ${CREATE_VM_SCRIPT} "${vm}" "$(pwd)"
  done
  virsh list
}

get_nodes_ip_address() {
  sleep 30
  get_all_nodes_ip_address
}

write_hosts() {
  cat > "${CONFIG_DIR}"/hosts <<EOF
127.0.0.1 localhost

# The following lines are desirable for IPv6 capable hosts
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts

${IP_VM01} ${VM01}
${IP_VM02} ${VM02}
${IP_VM03} ${VM03}
EOF
}

write_corosync_conf() {
  cat > "${CONFIG_DIR}"/corosync.conf <<EOF
totem {
        version: 2
        secauth: off
        cluster_name: testcluster
        transport: udp
}

nodelist {
        node {
                ring0_addr: ${IP_VM01}
                name: ${VM01}
                nodeid: 1
        }
        node {
                ring0_addr: ${IP_VM02}
                name: ${VM02}
                nodeid: 2
        }
        node {
                ring0_addr: ${IP_VM03}
                name: ${VM03}
                nodeid: 3
        }
}

quorum {
        provider: corosync_votequorum
        two_node: 0
}

qb {
        ipc_type: native
}

logging {

        fileline: on
        to_stderr: on
        to_logfile: yes
        logfile: /var/log/corosync/corosync.log
        to_syslog: no
        debug: off
}
EOF
}

write_config_files() {
  write_hosts
  write_corosync_conf
}

generate_ssh_key_in_the_host() {
  if [ ! -f "$HOME"/.ssh/virsh_fence_test_id_rsa ]; then
    ssh-keygen -q -f "$HOME"/.ssh/virsh_fence_test_id_rsa -N "" -C "virsh fence agent test key"
    cat "$HOME"/.ssh/virsh_fence_test_id_rsa.pub >> "$HOME"/.ssh/authorized_keys
  fi
}

verify_all_nodes_reachable_via_ssh() {
  for _ in {0..9}; do
    if run_in_all_nodes true; then
      return 0
    fi
    sleep 2
  done
  exit 1
}

copy_ssh_key_to_all_nodes() {
  run_in_all_nodes "mkdir -p /home/ubuntu/.ssh"
  copy_to_all_nodes "$HOME/.ssh/virsh_fence_test_id_rsa"
  run_in_all_nodes "cp /home/ubuntu/virsh_fence_test_id_rsa /home/ubuntu/.ssh/id_rsa"
  run_in_all_nodes "chmod 600 /home/ubuntu/.ssh/id_rsa"
}

copy_config_files_to_all_nodes() {
  copy_to_all_nodes "${CONFIG_DIR}"/hosts
  copy_to_all_nodes "${CONFIG_DIR}"/corosync.conf
}

block_until_cloud_init_is_done() {
  run_in_all_nodes "cloud-init status --wait"
}

setup_config_files_in_all_nodes() {
  run_in_all_nodes 'sudo cp /home/ubuntu/hosts /etc/'
  run_in_all_nodes 'sudo cp /home/ubuntu/corosync.conf /etc/corosync/'
  run_in_all_nodes 'sudo systemctl restart corosync'
}

check_if_all_nodes_are_online() {
  sleep 30
  cluster_status=$(${SSH} ubuntu@"${IP_VM01}" sudo crm status)
  nodes_online=$(echo "${cluster_status}" | grep -A1 "Node List" | grep Online)

  if [[ "${nodes_online}" == *"${VM01}"* ]] && \
	[[ "${nodes_online}" == *"${VM02}"* ]] && \
	[[ "${nodes_online}" == *"${VM03}"* ]] ; then
    echo "You cluster is all set! All nodes are online!"
  else
    echo "Something is wrong, your cluster is not properly working."
  fi
}

check_requirements
create_nodes
get_nodes_ip_address
write_config_files
generate_ssh_key_in_the_host
verify_all_nodes_reachable_via_ssh
copy_ssh_key_to_all_nodes
copy_config_files_to_all_nodes
block_until_cloud_init_is_done
setup_config_files_in_all_nodes
check_if_all_nodes_are_online
