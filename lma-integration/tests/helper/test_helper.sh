export PATH="$(dirname $0)/..:$PATH"
export ROOTDIR="$(dirname $0)/.."

load_shunit2() {
  if [ -e /usr/share/shunit2/shunit2 ]; then
    . /usr/share/shunit2/shunit2
  else
    . shunit2
  fi
}

stop_container_sync() {
    local id=${1}
    local timeout=10
    max=$timeout
    docker container stop ${id} &>/dev/null
    while docker container ls | grep -q "${id}"; do
        sleep 1
        timeout=$(($timeout-1))
        if [ "$timeout" -le 0 ]; then
            echo "ERROR, failed to stop container ${id} in ${max} seconds"
            return 1
        fi
    done
}

# $1: container id
# $2: last message to look for in logs
wait_container_ready() {
    local id="${1}"
    local msg="${2}"
	local timeout=10
    local logs

	max=${timeout}
    echo -n "Waiting for container to be ready "
    logs=$(docker logs ${id} 2>&1 | tail -n 1)
    while ! echo "${logs}" | grep -q "${msg}"; do
        echo -n "."
        sleep 1
		timeout=$(($timeout-1))
        if [ "${timeout}" -le 0 ]; then
            echo "ERROR, failed to start container ${id} in ${max} seconds"
            return 1
        fi
        logs=$(docker logs ${id} 2>&1 | tail -n 1)
    done
    echo
}


# export some global variables
export prometheus_url="http://127.0.0.1:9090"
export alertmanager_url="http://127.0.0.1:9093"
export telegraf_url="http://127.0.0.1:9273"
export cortex_url="http://127.0.0.1:9009"
# Grafana requires credentials which is user admin and password admin
export grafana_url="http://admin:admin@127.0.0.1:3000"
