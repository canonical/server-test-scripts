# shellcheck shell=bash

PATH="$(dirname "$0")/..:$PATH"
ROOTDIR="$(dirname "$0")/.."
export PATH ROOTDIR

load_shunit2() {
  if [ -e /usr/share/shunit2/shunit2 ]; then
    # shellcheck disable=SC1091
    . /usr/share/shunit2/shunit2
  else
    # shellcheck disable=SC1091
    . shunit2
  fi
}
