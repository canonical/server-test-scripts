#!/bin/bash
set -ux

PREFIX="testkvm"

lxc list | grep "$PREFIX"
lxc list -c n --format csv | grep "$PREFIX" | xargs lxc stop
lxc list -c n --format csv | grep "$PREFIX" | xargs lxc delete
rm /tmp/qemu-libvirt-test.sh.lock

exit 0
