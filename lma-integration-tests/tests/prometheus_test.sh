. $(dirname $0)/helper/test_helper.sh

test_web_interface_is_up() {
  # when requesting to / it redirects to /graph
  status_code=$(curl --write-out '%{http_code}' --silent --output /dev/null "$prometheus_url")
  assertEquals 302 "$status_code"

  status_code=$(curl --write-out '%{http_code}' --silent --output /dev/null "$prometheus_url"/graph)
  assertEquals 200 "$status_code"
}

test_configuration_is_loaded() {
  curl --silent "$prometheus_url"/flags | grep -A1 "config.file" | grep "/etc/prometheus/prometheus.yml" > /dev/null
  assertTrue $?
  
  curl --silent "$prometheus_url"/status | grep -A1 "Configuration reload" | grep "Successful" > /dev/null
  assertTrue $?
}

test_targets() {
  response=$(curl --silent "$prometheus_url"/targets) 

  echo $response | grep prometheus | grep up > /dev/null
  assertTrue $?

  echo $response | grep node-exporter | grep up > /dev/null
  assertTrue $?

  echo $response | grep telegraf | grep up > /dev/null
  assertTrue $?
}

test_alertmanager() {
  curl --silent "$prometheus_url"/status | grep "$alertmanager_url" > /dev/null
  assertTrue $?
}

test_registered_alerts() {
  response=$(curl --silent "$prometheus_url"/alerts) 

  echo $response | grep HighLoad | grep active > /dev/null
  assertTrue $?

  echo $response | grep InstanceDown | grep active > /dev/null
  assertTrue $?
}

load_shunit2
