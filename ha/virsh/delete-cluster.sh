#!/bin/bash

VM_PREFIX="fence-test-virsh-node0"

virsh list --state-running --name | grep "^$VM_PREFIX" | xargs -L 1 --no-run-if-empty virsh destroy
virsh list --state-shutoff --name | grep "^$VM_PREFIX" | xargs -L 1 --no-run-if-empty virsh undefine --remove-all-storage

# Check for leftover VMs (cleanup failed!)
! virsh list --all --name | grep -q "^$VM_PREFIX" || exit 1
