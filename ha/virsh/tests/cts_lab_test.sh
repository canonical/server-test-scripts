# shellcheck shell=bash

# Run some of the CTS Lab tests
# https://github.com/ClusterLabs/pacemaker/tree/main/cts#using-the-cts-lab

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"
# shellcheck disable=SC1090
. "$(dirname "$0")/../vm_utils.sh"

setup_cluster() {
  run_in_all_nodes "DEBIAN_FRONTEND=noninteractive sudo apt-get install -y pacemaker-cts >/dev/null"
  DEBIAN_FRONTEND=noninteractive sudo apt-get install -y pacemaker-cts >/dev/null
}

test_cts_lab() {
  run_command_in_node "${IP_VM01}" "sudo /usr/share/pacemaker/tests/cts/CTSlab.py --nodes '${VM02} ${VM03}' --clobber-cib --populate-resources --test-ip-base 192.168.122.255 --stonith xvm 50"
}

load_shunit2
