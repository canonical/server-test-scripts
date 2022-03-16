# shellcheck shell=bash

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"
# shellcheck disable=SC1090
. "$(dirname "$0")/../vm_utils.sh"

CREATE_VM_SCRIPT="$(pwd)/create-vm.sh"

setup_vbmc() {
  if [ ! -d "$(pwd)/virtualbmc.venv" ]; then
    NEEDED_PKGS="python3-venv python3-dev libvirt-dev gcc"
    for pkg in ${NEEDED_PKGS}; do
      if ! dpkg -l "${pkg}"; then
        echo "[E] ${pkg} is not installed."
	exit 5
      fi
    done
    python3 -m venv virtualbmc.venv
  fi
  # shellcheck source=/dev/null
  source virtualbmc.venv/bin/activate
  pip install -U pip
  pip install virtualbmc
  vbmcd
}

create_vm() {
  name="${1}"
  "${CREATE_VM_SCRIPT}" --vm-name "${name}"
}

get_tester_ip() {
  sleep 30
  IP_TESTER=$(virsh domifaddr "${TESTER}" | grep ipv4 | xargs | cut -d ' ' -f4 | cut -d '/' -f1)
}

setup_tester() {
  # TODO: remove fence-agents once the fence_ipmilan is added to the -base package
  run_command_in_node "${IP_TESTER}" "sudo apt-get update && \
	  sudo apt-get install -y ipmitool fence-agents"
}

oneTimeSetUp() {
  readonly TESTER="ipmi-tester"
  readonly SIMULATOR="ipmi-simulator"
  readonly PORT=6230
  readonly USER="admin"
  readonly PASSWD="password"

  setup_vbmc
  create_vm "${SIMULATOR}"
  vbmc add "${SIMULATOR}" --port "${PORT}"
  vbmc start "${SIMULATOR}"

  create_vm "${TESTER}"
  get_tester_ip
  setup_tester

  # shellcheck disable=SC2086,SC2116
  PREFIX=$(echo ${IP_TESTER%.*})
  readonly IP_HOST="${PREFIX}.1"
}

oneTimeTearDown() {
  vbmc stop "${SIMULATOR}"
  vbmc delete "${SIMULATOR}"
  pkill vbmcd
  deactivate

  for vm in "${SIMULATOR}" "${TESTER}"; do
    virsh destroy "${vm}"
    virsh undefine --remove-all-storage "${vm}"
  done
}

run_fence_ipmi() {
  action="${1}"
  run_command_in_node "${IP_TESTER}" "fence_ipmilan --ip=${IP_HOST} --ipport=${PORT} \
	  --username=${USER} --password=${PASSWD} --lanplus --verbose --action=${action}"
}

test_simulator_is_running() {
  status=$(run_fence_ipmi status)
  [[ "${status}" == *"ON"* ]]
  assertTrue $?

  running_vms=$(virsh list --state-running --name)
  echo "${running_vms}" | grep "${SIMULATOR}"
  assertTrue $?
}

test_simulator_is_rebooted() {
  status=$(run_fence_ipmi reboot)
  echo "${status}"
  [[ "${status}" == *"Rebooted"* ]]
  assertTrue $?
  [[ "${status}" == *"Success"* ]]
  assertTrue $?
}

test_turn_simulator_on_and_off() {
  status=$(run_fence_ipmi off)
  echo "${status}"
  [[ "${status}" == *"OFF"* ]]
  assertTrue $?
  [[ "${status}" == *"Success"* ]]
  assertTrue $?

  status=$(run_fence_ipmi on)
  echo "${status}"
  [[ "${status}" == *"ON"* ]]
  assertTrue $?
  [[ "${status}" == *"Success"* ]]
  assertTrue $?
}

load_shunit2
