#!/bin/bash

virsh shutdown node01
virsh shutdown node02
virsh shutdown node03

sleep 20
virsh undefine node01 --remove-all-storage
virsh undefine node02 --remove-all-storage
virsh undefine node03 --remove-all-storage
