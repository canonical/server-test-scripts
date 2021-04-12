#!/bin/bash

set -x

VM_NAME="${1}"
WORK_DIR="${2:-$(pwd)}"
CONFIG_DIR="${3:-"${WORK_DIR}/config"}"
IMAGES_DIR="${4:-"${WORK_DIR}/images"}"
UBUNTU_SERIES="${5:-"hirsute"}"
PUB_KEY_FILE="${6:-"/home/$(whoami)/.ssh/id_rsa.pub"}"

CLOUD_IMAGE_FILENAME="${UBUNTU_SERIES}-server-cloudimg-amd64.img"
CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/${UBUNTU_SERIES}/current/${CLOUD_IMAGE_FILENAME}"

PUB_KEY=$(cat ${PUB_KEY_FILE})

RAM=1024
VCPU=1

setup_workdir() {
  mkdir -p ${IMAGES_DIR}/base \
  	   ${IMAGES_DIR}/${VM_NAME} \
  	   ${CONFIG_DIR}
}

download_base_image() {
  if [ ! -f ${IMAGES_DIR}/base/${CLOUD_IMAGE_FILENAME} ]; then
    wget -P ${IMAGES_DIR}/base ${CLOUD_IMAGE_URL}
  fi
}

create_qcow2_image() {
  if [ ! -f ${IMAGES_DIR}/${VM_NAME}/${VM_NAME}.qcow2 ]; then
    qemu-img create \
    	-F qcow2 \
    	-b ${IMAGES_DIR}/base/${CLOUD_IMAGE_FILENAME} \
    	-f qcow2 \
    	${IMAGES_DIR}/${VM_NAME}/${VM_NAME}.qcow2 \
    	10G
  fi
}

create_config() {
  create_user_data
  create_meta_data
}

create_user_data() {
  cat > ${CONFIG_DIR}/user-data <<EOF
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
package_update: true
package_upgrade: true
packages: ['corosync', 'pacemaker', 'pacemaker-cli-utils', 'crmsh', 'resource-agents', 'fence-agents']
EOF
}

create_meta_data() {
  echo "instance-id: $(uuidgen || echo i-abcdefg)" > ${CONFIG_DIR}/meta-data
}

create_seed_disk() {
  cloud-localds --verbose \
  	${IMAGES_DIR}/${VM_NAME}/${VM_NAME}-seed.qcow2 \
  	${CONFIG_DIR}/user-data \
  	${CONFIG_DIR}/meta-data
}

launch_vm() {
  virt-install \
  	--connect qemu:///system \
  	--virt-type kvm \
  	--name ${VM_NAME} \
  	--ram ${RAM} \
  	--vcpus=${VCPU} \
  	--os-type linux \
	--os-variant ubuntu18.04 \
  	--disk path=${IMAGES_DIR}/${VM_NAME}/${VM_NAME}.qcow2,device=disk \
  	--disk path=${IMAGES_DIR}/${VM_NAME}/${VM_NAME}-seed.qcow2,device=disk \
  	--import \
  	--network network=default,model=virtio \
  	--noautoconsole
}

get_vm_info() {
  id=$(virsh dominfo ${VM_NAME} | grep "Id" | xargs | cut -d ' ' -f2)
  status=$(virsh domstate ${VM_NAME} | xargs)

  echo "VM ${VM_NAME} of ID ${id} is ${status}"
}


setup_workdir
download_base_image
create_qcow2_image
create_config
create_seed_disk
launch_vm
get_vm_info
