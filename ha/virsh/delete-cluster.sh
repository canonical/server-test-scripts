#!/bin/bash

: "${UBUNTU_SERIES:=impish}"
VM_PREFIX="fence-test-virsh-${UBUNTU_SERIES}-node"
VM_SERVICES="services-${UBUNTU_SERIES}"

# Remove all cluster nodes
virsh list --state-running --name | grep "^$VM_PREFIX" | xargs -L 1 --no-run-if-empty virsh destroy
virsh list --state-shutoff --name | grep "^$VM_PREFIX" | xargs -L 1 --no-run-if-empty virsh undefine --remove-all-storage

# Remove VM running external services if it exists
if virsh list --name | grep ${VM_SERVICES}; then
  virsh destroy ${VM_SERVICES}
  virsh undefine --remove-all-storage ${VM_SERVICES}
fi

# Check for leftover VMs (cleanup failed!)
! virsh list --all --name | grep -q "^$VM_PREFIX" || exit 1
