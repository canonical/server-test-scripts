. $(dirname $0)/helper/test_helper.sh

test_api_is_up() {
  status_code=$(curl --write-out '%{http_code}' --silent --output /dev/null "$cortex_url")
  assertEquals 200 "$status_code"
}

test_services_status() {
  response=$(curl --silent "$cortex_url"/services) 

  echo $response | grep -A1 memberlist-kv | grep Running > /dev/null
  assertTrue $?
  echo $response | grep -A1 server | grep Running > /dev/null
  assertTrue $?
  echo $response | grep -A1 store | grep Running > /dev/null
  assertTrue $?
  echo $response | grep -A1 runtime-config | grep Running > /dev/null
  assertTrue $?
  echo $response | grep -A1 table-manager | grep Running > /dev/null
  assertTrue $?
  echo $response | grep -A1 query-frontend | grep Running > /dev/null
  assertTrue $?
  echo $response | grep -A1 distributor | grep Running > /dev/null
  assertTrue $?
  echo $response | grep -A1 ingester | grep Running > /dev/null
  assertTrue $?
  echo $response | grep -A1 ring | grep Running > /dev/null
  assertTrue $?
  echo $response | grep -A1 querier | grep Running > /dev/null
  assertTrue $?
}

load_shunit2
