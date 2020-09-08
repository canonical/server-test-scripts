. $(dirname $0)/helper/test_helper.sh

test_datasource() {
  response=$(curl --silent "$grafana_url"/api/datasources) 

  echo $response | grep name | grep prometheus-cortex-lma > /dev/null
  assertTrue $?
}

test_dashboard() {
  response=$(curl --silent "$grafana_url"/api/dashboards/uid/lma-integration-tests-dashboard) 

  echo $response | grep title | grep "LMA integration tests" > /dev/null
  assertTrue $?
}

load_shunit2
