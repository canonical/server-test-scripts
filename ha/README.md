# Testbed setup

The testbed is composed of a 3-node cluster with a Corosync/Pacemaker setup.
The scripts provided by this repository were tested only with Ubuntu Hirsute.

## Setting up

Run the `setup-cluster.sh` script with no arguments and it will set up
eveything for you! Make sure you have the following packages installed:

- wget
- qemu
- qemu-utils
- libvirt-clients
- virtinst
- uuid-runtime
- cloud-image-utils

Moreover, a SSH key is needed in your host to be added to the `authorized_keys`
file of each node. By default, the script will try to use
`/home/$(whoami)/.ssh/id_rsa.pub` as your public SSH key.

The setup takes some time but when it is done you will be ready to ssh into the
nodes and the Corosync/Pacemaker cluster will be all set. You can check the
cluster status running `sudo crm status`, all the nodes should be online.

All the virtual machines created using these scripts can be managed using
`virsh` or `virt-manager`.

## Running tests

For now we have only tested the `fence_virsh` agent. To run it, the test for
now expects that the host running the test have an user called `ubuntu` which
is capable of running commands with `sudo` without password. This user also
needs to have the public key of all nodes in its `authorized_keys` file (this
is not automated yet since the scripts are not setting up this user).
Somethings are customizable, take a look at the variables at the top of the
test script.

```
$ bash tests/fence_virsh_test.sh
```
