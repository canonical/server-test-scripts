#!/bin/bash

: "${UBUNTU_SERIES:=jammy}"
VM_PREFIX="ha-agent-virsh-${UBUNTU_SERIES}-${AGENT}-node"
VM_SERVICES="services-${UBUNTU_SERIES}"
HA_NETWORK="ha"

# Remove all cluster nodes
virsh list --state-running --name | grep "^$VM_PREFIX" | xargs -L 1 --no-run-if-empty virsh destroy
virsh list --state-shutoff --name | grep "^$VM_PREFIX" | xargs -L 1 --no-run-if-empty virsh undefine --remove-all-storage

# Remove VM running external services if it exists
if virsh list --name | grep ${VM_SERVICES}; then
  virsh destroy ${VM_SERVICES}
  virsh undefine --remove-all-storage ${VM_SERVICES}
fi

# Remove the HA specific network
if virsh net-list --name | grep ${HA_NETWORK}; then
  virsh net-destroy "${HA_NETWORK}"
  virsh net-undefine "${HA_NETWORK}"
fi

# Check for leftover VMs (cleanup failed!)
! virsh list --all --name | grep -q "^$VM_PREFIX" || exit 1
