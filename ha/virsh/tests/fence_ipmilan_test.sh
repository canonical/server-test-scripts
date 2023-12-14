# shellcheck shell=bash

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"
# shellcheck disable=SC1090
. "$(dirname "$0")/../vm_utils.sh"

CREATE_VM_SCRIPT="$(pwd)/create-vm.sh"

setup_vbmc() {
  # Drop this if we upgrade to 24.04 or backport python3-virtualbmc.
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

  # Make sure there's no lingering vbmcd process
  pkill vbmcd 2>/dev/null || true
  kill_vbmcd() {
    if (pkill -0 vbmcd); then
      return 1
    else
      return 0
    fi
  }
  backoff kill_vbmcd

  vbmcd
}

create_vm() {
  name="${1}"
  "${CREATE_VM_SCRIPT}" --vm-name "${name}" --network-name "${HA_NETWORK}"
}

get_tester_ip() {
  IP_TESTER=$(virsh domifaddr "${TESTER}" | grep ipv4 | xargs | cut -d ' ' -f4 | cut -d '/' -f1)
  if grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}' <<< ${IP_TESTER}; then
    return 0
  fi
  return 1
}

setup_tester() {
  run_command_in_node "${IP_TESTER}" "sudo apt-get update && \
	  sudo apt-get install -y ipmitool fence-agents-base"
}

oneTimeSetUp() {
  readonly TESTER="ha-agent-virsh-${UBUNTU_SERIES::1}-${AGENT}-tester"
  readonly SIMULATOR="ha-agent-virsh-${UBUNTU_SERIES::1}-${AGENT}-simulator"
  readonly PORT=6230
  readonly USER="admin"
  readonly PASSWD="password"

  setup_vbmc
  create_vm "${SIMULATOR}"
  vbmc add "${SIMULATOR}" --port "${PORT}"
  vbmc start "${SIMULATOR}"

  create_vm "${TESTER}"
  backoff get_tester_ip
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
