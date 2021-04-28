# shellcheck shell=bash

: "${UBUNTU_SERIES:=hirsute}"

# shellcheck disable=SC2034
VM01="fence-test-virsh-${UBUNTU_SERIES}-node01"
# shellcheck disable=SC2034
VM02="fence-test-virsh-${UBUNTU_SERIES}-node02"
# shellcheck disable=SC2034
VM03="fence-test-virsh-${UBUNTU_SERIES}-node03"

# shellcheck disable=SC2034
HOST_IP="192.168.122.1"
# shellcheck disable=SC2034
HOST_USER=$USER
# shellcheck disable=SC2034
PRIVATE_SSH_KEY="/home/ubuntu/.ssh/id_rsa"
