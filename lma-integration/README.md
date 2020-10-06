# Integration tests for the LMA stack

## docker-compose

How to run tests:

$ apt-get install -y docker.io docker-compose shunit2 curl
$ ./run-tests

The tests will bind the services to the following ports:

* Prometheus: 9090
* Node-exporter: 9100
* Telegraf: 9273
* Alertmanager: 9093
* Grafana: 3000
* Cortex: 9009

## microk8s

First of all, a microk8s instance needs to be running with the dns addon enabled.

Currently, the defined cluster contains the following pods:

* postgres-deployment: It contains one postgres and one telegraf container.
* prometheus-deployment: It contains one prometheus and one alertmanager container.
* postgres-deployment: It contains one grafana container.

k8s does not support relative paths to point to volumes to be mount, so we need
to generate the deployments manifest based on the template:

$ PWD=$(pwd) envsubst < k8s/manifests/deployments.tmpl > k8s/manifests/deployments.yaml

Let's create the directories to store the persistent data:

$ mkdir -p k8s/data/prometheus
$ mkdir -p k8s/data/postgres

There is a known permission issue to bindmount a prometheus directory with its
data (https://github.com/prometheus/prometheus/issues/5976). In order to
workaround that you can run:

$ chown -R 65534:65534 k8s/data/prometheus

With all that in place, apply the manifests:

$ microk8s kubectl apply -f k8s/manifests/deployments.yaml
$ microk8s kubectl apply -f k8s/manifests/services.yaml

You can check which ports are used by the services:

$ microk8s kubectl get services

To save you some time those are the ports each service is running and they are accessible via
localhost:

* Postgres:     30100
* Telegraf:     30101
* Prometheus:   30110
* Alertmanager: 30111
* Grafana:      30120
