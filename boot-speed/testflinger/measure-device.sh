#!/bin/bash

set -eux
shopt -s nullglob

if [ $# -ne 2 ]; then
    echo "Usage: $0 <device> <distro>"
    exit 1
fi

# Are the required command available? Fail early if they are not.
# We rely on the errexit (set -e) option here.
command -v testflinger-cli
command -v timeout

device=$1
distro=$2

yaml_head="$device-$distro.provision.yaml"
yaml_tail="test_data.yaml"
yaml_full="$device-$distro.full.yaml"

yyyymmdd=$(date --utc '+%Y%m%d')

echo "Target device: $device"
echo "Target distribution: $distro"

datadir="$device-${distro}_$yyyymmdd"
mkdir -v $datadir

# Generate JSON metadata file
cat > "$datadir/metadata.json" <<EOF
{
  "date": "$yyyymmdd",
  "distro": "$distro",
  "type": "device",
  "instance": {
    "device": "$device"
  }
}
EOF


if [ ! -f "$yaml_head" ]; then
    echo "Missing provisioning data: $yaml_head"
    exit 1
fi

cat "$yaml_head" "$yaml_tail" > "$yaml_full"

#testflinger-cli submit "$yaml_full" | tee testflinger-submit-output

#if ! grep -q "^job_id:" testflinger-submit-output; then
#    echo "Failed to submit job."
#    exit 1
#fi

#job_id=$(awk '/^job_id:/{ print $2 }' testflinger-submit-output)

job_id=$(testflinger-cli submit --quiet "$yaml_full")

echo "testflinger job_id: $job_id"

# Test the job_id for RFC4122 compliance
if [[ $job_id =~ "^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$" ]]; then
    echo "Invalid job id!"
    exit 1
fi

#if ! timeout 1h sh -c "until [ \$(testflinger-cli status $job_id) = complete ]; do echo "sleeping..."; sleep 5; done"; then
#    echo "Timeout: the submitted job didn't finish in time."
#    exit 1
#fi

echo
echo "### POLLING $job_id"
echo
timeout 1h testflinger-cli poll $job_id
echo
echo "### POLLING FINISHED"
echo

sleep 10
testflinger-cli status $job_id
testflinger-cli artifacts $job_id

if [ ! -f artifacts.tgz ]; then
    echo "Couldn't retrieve artifacts."
    exit 1
fi

if ! tar tzf artifacts.tgz artifacts/boot_0/systemd-analyze_time > /dev/null; then
    print "No valid measurement in artifacts file."
    exit 1
fi

tar xfzv artifacts.tgz
mv artifacts "$datadir/instance_0"
data_tarball="$datadir.tar.gz"
tar cfzv "$data_tarball" "$datadir"