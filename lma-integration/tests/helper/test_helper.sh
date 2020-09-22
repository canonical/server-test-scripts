export PATH="$(dirname $0)/..:$PATH"
export ROOTDIR="$(dirname $0)/.."

load_shunit2() {
  if [ -e /usr/share/shunit2/shunit2 ]; then
    . /usr/share/shunit2/shunit2
  else
    . shunit2
  fi
}

# export some global variables
export prometheus_url="http://127.0.0.1:9090"
export alertmanager_url="http://127.0.0.1:9093"
export telegraf_url="http://127.0.0.1:9273"
export cortex_url="http://127.0.0.1:9009"
# Grafana requires credentials which is user admin and password admin
export grafana_url="http://admin:admin@127.0.0.1:3000"
