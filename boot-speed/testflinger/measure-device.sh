#!/bin/bash

set -eufx
set -o pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <device> <distro>"
    exit 1
fi

# Are the required command available? Fail early if they are not.
# We rely on the errexit (set -e) option here.
command -v testflinger-cli
command -v timeout
command -v jq

device=$1
distro=$2

yaml_head="$device-$distro.provision.yaml"
yaml_tail="test_data.yaml"
yaml_full="$device-$distro.full.yaml"

yyyymmdd=$(date --utc '+%Y%m%d')
date_rfc3339=$(date --utc --rfc-3339=ns)

echo "Target device: $device"
echo "Target distribution: $distro"

datadir="$device-${distro}_$yyyymmdd"
mkdir -v "$datadir"

image_url=$(grep "url:" "$yaml_head" | awk '{ print $2 }')
image_dirname=$(echo "$image_url" | sed 's|\(.*/\)\(.*\)|\1|')
image_basename=$(echo "$image_url" | sed 's|\(.*/\)\(.*\)|\2|')
image_serial=$(curl -s --noproxy ubuntu.com "$image_dirname/.publish_info" | grep "$image_basename" | awk '{ print $2 }') || true

regexp='^[0-9]{8}(\.[0-9]{1,2})?$'
if [[ ! "$image_serial" =~ $regexp ]]; then
    echo "Invalid or missing image serial!"
    exit 1
fi

# Generate JSON metadata file
cat > "$datadir/metadata.json" <<EOF
{
  "date": "$yyyymmdd",
  "date-rfc3339": "$date_rfc3339",
  "type": "device",
  "instance": {
    "device": "$device",
    "release": "$distro",
    "image_serial": "$image_serial"
  }
}
EOF


if [ ! -f "$yaml_head" ]; then
    echo "Missing provisioning data: $yaml_head"
    exit 1
fi

cat "$yaml_head" "$yaml_tail" > "$yaml_full"

job_id=$(testflinger-cli submit --quiet "$yaml_full")

echo "testflinger job_id: $job_id"

# Test the job_id for RFC4122 compliance
regexp="^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
if [[ ! "$job_id" =~ $regexp ]]; then
    echo "Invalid job id!"
    exit 1
fi

echo
echo "### POLLING $job_id"
echo
if ! timeout 2h testflinger-cli poll "$job_id"; then
    echo "testflinger-cli timeout"
    testflinger-cli cancel "$job_id" || true
    exit 1
fi
echo
echo "### POLLING FINISHED"
echo

sleep 5

testflinger-cli status "$job_id"
testflinger-cli results "$job_id" > testflinger-results.json

# Here we retrieve the test script exit status.
test_status=$(jq ".test_status" < testflinger-results.json)
if [ "$test_status" != 0 ]; then
    echo "Failure: test_status = $test_status. Exiting."
    exit 1
fi

testflinger-cli artifacts "$job_id"

if [ ! -f artifacts.tgz ]; then
    echo "Couldn't retrieve artifacts."
    exit 1
fi

tar xfzv artifacts.tgz

if [ ! -f artifacts/testflinger-script-ok ]; then
    # The script should actually never reach this point, as we check
    # the test script exit code.
    echo "Error while executing the testflinger script (BUG!)"
    exit 1
fi

if [ ! -f artifacts/boot_0/systemd-analyze_time ]; then
    echo "No valid measurement in artifacts file."
    exit 1
fi

mv artifacts "$datadir/instance_0"
data_tarball="$datadir.tar.gz"
tar cfzv "$data_tarball" "$datadir"
