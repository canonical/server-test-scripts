#!/bin/bash

: "${UBUNTU_SERIES:=impish}"
VM_PREFIX="fence-test-virsh-${UBUNTU_SERIES}-node"

virsh list --state-running --name | grep "^$VM_PREFIX" | xargs -L 1 --no-run-if-empty virsh destroy
virsh list --state-shutoff --name | grep "^$VM_PREFIX" | xargs -L 1 --no-run-if-empty virsh undefine --remove-all-storage

# Check for leftover VMs (cleanup failed!)
! virsh list --all --name | grep -q "^$VM_PREFIX" || exit 1
