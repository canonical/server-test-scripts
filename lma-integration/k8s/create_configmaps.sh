#!/bin/sh

# Telegraf config
microk8s kubectl create configmap telegraf-config \
	--from-file=telegraf=k8s/config/telegraf/telegraf.conf

# Alertmanager config
microk8s kubectl create configmap alertmanager-config \
	--from-file=alertmanager=k8s/config/prometheus-alertmanager/alertmanager.yml

# Prometheus config
microk8s kubectl create configmap prometheus-config \
	--from-file=prometheus=k8s/config/prometheus/prometheus.yml \
	--from-file=prometheus-alerts=k8s/config/prometheus/alerts.yml

# Grafana config
microk8s kubectl create configmap grafana-config \
	--from-file=grafana-datasource=k8s/config/grafana/provisioning/datasources/datasource.yml \
	--from-file=grafana-dashboard=k8s/config/grafana/provisioning/system-stats-dashboard.json
