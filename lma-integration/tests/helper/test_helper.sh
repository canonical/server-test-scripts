export PATH="$(dirname $0)/..:$PATH"
export ROOTDIR="$(dirname $0)/.."

load_shunit2() {
  if [ -e /usr/share/shunit2/shunit2 ]; then
    . /usr/share/shunit2/shunit2
  else
    . shunit2
  fi
}

. $(dirname $0)/globals.sh
