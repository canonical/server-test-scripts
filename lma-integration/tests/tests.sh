#!/bin/bash

. $(dirname $0)/globals.sh

wait_for_services ()
{
    local urls=( $prometheus_url
		 $alertmanager_url
		 $telegraf_url
		 $cortex_url
		 $grafana_url )

    echo "Waiting for all the services to be online..."
    for url in ${urls[@]}; do
	while ! curl --silent --output /dev/null $url; do
	    sleep 1
	done
    done
}

# We must wait until all services are available.
wait_for_services

# run tests
failed=0
for file in /tests/*_test.sh; do
  rc=0
  echo "$file"
  mispipe "sh $file" "sed -e 's/ASSERT:/FAILED:/; s/^/  /'" || rc=$?
  if [ $rc -ne 0 ]; then
    failed=1
  fi
done

exit $failed
