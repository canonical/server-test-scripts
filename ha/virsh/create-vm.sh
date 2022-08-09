#!/bin/bash

set -eux -o pipefail

: "${UBUNTU_SERIES:=jammy}"

VM_NAME="test"
WORK_DIR=$(pwd)
CONFIG_DIR="${WORK_DIR}/config"
IMAGES_DIR="${WORK_DIR}/images"
PUB_KEY_FILE="/home/$(whoami)/.ssh/id_rsa.pub"

CLOUD_IMAGE_FILENAME="${UBUNTU_SERIES}-server-cloudimg-amd64.img"
CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/${UBUNTU_SERIES}/current/${CLOUD_IMAGE_FILENAME}"

PUB_KEY=$(cat "${PUB_KEY_FILE}")

RAM=1024
VCPU=1

HA_NETWORK="ha"

while [[ $# -gt 0 ]]; do
  option="$1"
  case $option in
    --vm-name)
      VM_NAME="$2"
      shift
      shift
      ;;
    --network-name)
      HA_NETWORK="$2"
      shift
      shift
      ;;
    --work-dir)
      WORK_DIR="$2"
      shift
      shift
      ;;
    --config-dir)
      CONFIG_DIR="$2"
      shift
      shift
      ;;
    --images-dir)
      IMAGES_DIR="$2"
      shift
      shift
      ;;
    --pub-key)
      PUB_KEY_FILE="$2"
      shift
      shift
      ;;
    *)
      # Do nothing
      ;;
  esac
done

setup_workdir() {
  mkdir -p "${IMAGES_DIR}"/base \
	   "${IMAGES_DIR}"/"${VM_NAME}" \
	   "${CONFIG_DIR}"
}

download_base_image() {
  if [ ! -f "${IMAGES_DIR}"/base/"${CLOUD_IMAGE_FILENAME}" ]; then
    wget --quiet -P "${IMAGES_DIR}"/base "${CLOUD_IMAGE_URL}"
  fi
}

create_qcow2_image() {
  if [ ! -f "${IMAGES_DIR}"/"${VM_NAME}"/"${VM_NAME}".qcow2 ]; then
    qemu-img create \
    	-F qcow2 \
	-b "${IMAGES_DIR}"/base/"${CLOUD_IMAGE_FILENAME}" \
    	-f qcow2 \
	"${IMAGES_DIR}"/"${VM_NAME}"/"${VM_NAME}".qcow2 \
    	10G
  fi
}

create_config() {
  create_user_data
  create_meta_data
}

create_user_data() {
  cat > "${CONFIG_DIR}"/user-data <<EOF
#cloud-config
hostname: ${VM_NAME}
users:
  - default
  - name: ubuntu
    passwd: "\$6\$exDY1mhS4KUYCE/2\$zmn9ToZwTKLhCw.b4/b.ZRTIZM30JZ4QrOQ2aOXJ8yk96xpcCof0kxKwuX1kqLG/ygbJ1f8wxED22bTL4F46P0"
    ssh-authorized-keys:
      - ${PUB_KEY}
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    groups: sudo
    shell: /bin/bash
runcmd:
  - echo "AllowUsers ubuntu" >> /etc/ssh/sshd_config
  - systemctl restart ssh
apt:
  sources:
    proposed.list:
      source: "deb http://archive.ubuntu.com/ubuntu ${UBUNTU_SERIES}-proposed main universe"
package_update: true
packages: ['corosync', 'pacemaker', 'pacemaker-cli-utils', 'pcs', 'resource-agents-base', 'fence-agents-base']
EOF
}

create_meta_data() {
  echo "instance-id: $(uuidgen || echo i-abcdefg)" > "${CONFIG_DIR}"/meta-data
}

create_seed_disk() {
  cloud-localds --verbose \
	"${IMAGES_DIR}"/"${VM_NAME}"/"${VM_NAME}"-seed.qcow2 \
	"${CONFIG_DIR}"/user-data \
	"${CONFIG_DIR}"/meta-data
}

create_storage_disk() {
  if [ ! -f "${IMAGES_DIR}"/"${VM_NAME}"/"${VM_NAME}"-storage.qcow2 ]; then
    qemu-img create \
	-f qcow2 \
	"${IMAGES_DIR}"/"${VM_NAME}"/"${VM_NAME}"-storage.qcow2 \
	1G
  fi
}

create_ha_network() {
  cat > "${CONFIG_DIR}"/ha-network.xml <<EOF
<network>
  <name>${HA_NETWORK}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='${HA_NETWORK}' stp='on' delay='0'/>
  <ip address='192.168.30.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.30.2' end='192.168.30.254'/>
    </dhcp>
  </ip>
</network>
EOF

  virsh net-define "${CONFIG_DIR}"/ha-network.xml
  virsh net-start "${HA_NETWORK}"
}

define_ha_network() {
  if ! virsh net-list --name  | grep "${HA_NETWORK}"; then
    create_ha_network
  fi
}

launch_vm() {
  virt-install \
  	--virt-type kvm \
	--name "${VM_NAME}" \
  	--ram ${RAM} \
  	--vcpus=${VCPU} \
  	--os-type linux \
	--os-variant ubuntu18.04 \
	--disk path="${IMAGES_DIR}"/"${VM_NAME}"/"${VM_NAME}".qcow2,device=disk \
	--disk path="${IMAGES_DIR}"/"${VM_NAME}"/"${VM_NAME}"-seed.qcow2,device=disk \
	--disk path="${IMAGES_DIR}"/"${VM_NAME}"/"${VM_NAME}"-storage.qcow2,device=disk \
  	--import \
  	--network network=default,model=virtio \
	--network network="${HA_NETWORK}",model=virtio \
  	--noautoconsole
}

get_vm_info() {
  id=$(virsh dominfo "${VM_NAME}" | grep "Id" | xargs | cut -d ' ' -f2)
  status=$(virsh domstate "${VM_NAME}" | xargs)

  echo "VM ${VM_NAME} of ID ${id} is ${status}"
}


setup_workdir
download_base_image
create_qcow2_image
create_config
create_seed_disk
create_storage_disk
define_ha_network
launch_vm
get_vm_info
