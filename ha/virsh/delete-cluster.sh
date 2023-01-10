#!/bin/bash

: "${UBUNTU_SERIES:=jammy}"
VM_PREFIX="ha-agent-virsh-${UBUNTU_SERIES::1}-${AGENT}"
HA_NETWORK="ha-${UBUNTU_SERIES::1}-${AGENT}"
HA_NETWORK=${HA_NETWORK::15}

# Remove all nodes
virsh list --state-running --name | grep "^$VM_PREFIX" | xargs -L 1 --no-run-if-empty virsh destroy
virsh list --state-shutoff --name | grep "^$VM_PREFIX" | xargs -L 1 --no-run-if-empty virsh undefine --remove-all-storage

# Remove the HA specific network
if virsh net-list --name --all | grep ${HA_NETWORK}; then
  virsh net-destroy "${HA_NETWORK}"
  virsh net-undefine "${HA_NETWORK}"
fi

# Check for leftover VMs (cleanup failed!)
! virsh list --all --name | grep -q "^$VM_PREFIX" || exit 1
