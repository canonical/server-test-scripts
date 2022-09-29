#!/bin/sh

set -eux

RELEASE=${RELEASE-$(distro-info --devel)}
VMNAME=${VMNAME-metric-noninteractive-ssh-$RELEASE}

cleanup() {
  if lxc info "$VMNAME" >/dev/null 2>&1; then
    echo "Cleaning up: $VMNAME"
    lxc delete "$VMNAME" --force
  fi
}

trap cleanup EXIT

setup_lxd_minimal_remote() {
  # Minimal images are leaner and boot faster.
  lxc remote list --format csv | grep -q '^ubuntu-minimal-daily,' && return
  lxc remote add --protocol simplestreams ubuntu-minimal-daily https://cloud-images.ubuntu.com/minimal/daily/
}

cexec() {
  # This assumes that in the official LXD images
  # user 'ubuntu' always has UID 1000.
  lxc exec --user=1000 --cwd=/home/ubuntu "$VMNAME" -- "$@"
}

Cexec() {
  # capital C => root
  lxc exec "$VMNAME" -- "$@"
}

setup_container() {
  lxc launch "ubuntu-minimal-daily:$RELEASE" "$VMNAME"
  cexec cloud-init status --wait >/dev/null

  # Starting from Kinetic sshd is socket activated, which will slow
  # down the very fist login. Start ssh.service manually to avoid this.
  Cexec systemctl start ssh

  # We'll use hyperfine to run the measurement
  Cexec apt-get -q update
  Cexec apt-get -qy install hyperfine

  # Setup passwordless ssh authentication
  cexec ssh-keygen -q -t rsa -f /home/ubuntu/.ssh/id_rsa -N ''
  cexec cp /home/ubuntu/.ssh/id_rsa.pub /home/ubuntu/.ssh/authorized_keys
}


do_measurement() {
  cexec hyperfine --style=basic --min-runs=10 --max-runs=100 --export-json=results.json \
    "ssh -o StrictHostKeyChecking=accept-new localhost true"
  lxc file pull "$VMNAME/home/ubuntu/results.json" results.json
}

cleanup
setup_lxd_minimal_remote
setup_container
do_measurement
cleanup
