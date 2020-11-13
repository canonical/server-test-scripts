. $(dirname $0)/helper/test_helper.sh

test_web_interface_is_up() {
  status_code=$(curl --write-out '%{http_code}' --silent --output /dev/null "$alertmanager_url")
  assertEquals 200 "$status_code"
}

test_fire_an_alert() {
  data=$(cat <<EOF
{
  "status": "firing",
  "labels": {
    "alertname": "my_testing_alert",
    "service": "test_service",
    "severity": "warning",
    "instance": "fake_instance"
  },
  "annotations": {
    "summary": "This is the summary",
    "description": "This is the description."
  },
  "generatorURL": "https://fake_instance.example/metrics",
  "startsAt": "2020-08-11T16:00:00+00:00"
}
EOF
)

  response=$(curl --silent --request POST "$alertmanager_url"/api/v1/alerts --data "[$data]")
  echo $response | grep success > /dev/null
  assertTrue $?
}

test_web_hook_call() {
  # the webhook is configured to send a request to localhost port 5001
  response=$(timeout 20s nc -l 0.0.0.0 5001)

  echo $response | grep User-Agent | grep Alertmanager > /dev/null
  assertTrue $?

  echo $response | grep status | grep firing > /dev/null
  assertTrue $?

  # check for my_testing_alert created in the previous test
  echo $response | grep alertname | grep my_testing_alert > /dev/null
  assertTrue $?
}

load_shunit2
