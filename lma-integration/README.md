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

First of all, a microk8s instance needs to be running with the dns and storage addons enabled.

Currently, the defined cluster contains the following pods:

* postgres-deployment: It contains one postgres and one telegraf container.
* prometheus-deployment: It contains one prometheus and one alertmanager container.
* postgres-deployment: It contains one grafana container.

Creating the configMaps needed:

$ k8s/create_configmaps.sh

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
