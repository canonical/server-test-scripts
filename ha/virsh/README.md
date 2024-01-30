# Testbed setup

The testbed is composed of a 3-node cluster with a Corosync/Pacemaker setup.
The scripts provided by this repository are tested for each currently supported
Ubuntu series.

If you wish to run the tests in a virtual machine, do ensure you have enough
resources to do so.  For instance:

```
lxc launch ubuntu-daily:jammy ha-jammy --vm --config limits.memory=16GB --device root,size=50GB
```

## Running tests

Setting up the environment:

```
$ sudo apt install -y wget qemu qemu-utils libvirt-clients virtinst uuid-runtime cloud-image-utils shunit2 qemu-kvm libvirt-daemon-system bridge-utils
$ ssh-keygen
$ sudo systemctl enable libvirtd
$ sudo systemctl start libvirtd
```

Run the whole test suite:

```
$ ./run_tests.sh
```

Run specific tests for specific Ubuntu series:

```
$ TESTS=tests/resource_pgsql_test.sh UBUNTU_SERIES=jammy ./run_tests.sh
```

## Debugging

Please check the `run_tests.sh` script.

In summary, you can run the cluster by running the `setup-cluster.sh` script
(ensure you have the dependencies listed above installed).

Moreover, a SSH key is needed in your host to be added to the `authorized_keys`
file of each node. By default, the script will try to use
`${HOME}/.ssh/id_rsa.pub` as your public SSH key.

The setup takes some time but when it is done you will be ready to ssh into the
nodes and the Corosync/Pacemaker cluster will be all set. You can check the
cluster status running `sudo pcs status`, all the nodes should be online.

All the virtual machines created using these scripts can be managed using
`virsh` or `virt-manager`.

You can run specific tests (without destroying the whole environment after the
test run) from the `tests` directory. e.g.,

```
$ bash tests/fence_virsh_test.sh
```

For now, the tests expects that the host running them will have a `ubuntu`
user, who is capable of running commands with `sudo` without password. This
user also needs to have the public key of all nodes in its `authorized_keys`
file (this is not automated yet since the scripts are not setting up this
user). Some things are customizable, take a look at the variables at the top of
the test script.
