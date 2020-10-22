. $(dirname $0)/helper/test_helper.sh

test_prometheus_output() {
  response=$(curl --silent "$telegraf_url"/metrics)

  echo $response | grep go_gc_duration > /dev/null
  assertTrue $?

  echo $response | grep go_memstats > /dev/null
  assertTrue $?
}

test_http_output() {
  # the http output is configured to send the data to localhost port 8080
  response=$(timeout 20s nc -l 0.0.0.0 8080)

  echo $response | grep diskio > /dev/null
  assertTrue $?

  echo $response | grep inodes > /dev/null
  assertTrue $?

  echo $response | grep cpu > /dev/null
  assertTrue $?
}

load_shunit2
