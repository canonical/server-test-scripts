#!/bin/bash
set -eux

PREFIX="testkvm"

lxc list | grep "$PREFIX"
lxc list -c n --format csv | grep -v "$PREFIX" | xargs lxc stop
lxc list -c n --format csv | grep -v "$PREFIX" | xargs lxc delete
rm /tmp/qemu-libvirt-test.sh.lock
