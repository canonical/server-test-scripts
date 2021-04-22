#!/bin/bash

virsh destroy node01
virsh destroy node02
virsh destroy node03

virsh undefine node01 --remove-all-storage
virsh undefine node02 --remove-all-storage
virsh undefine node03 --remove-all-storage
