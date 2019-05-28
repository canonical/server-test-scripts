#!/bin/bash

set -ex
set -o pipefail

# Print some information about the testflinger host system
cat /etc/os-release
uname -a
id
pwd
ls -la

# Do not auto-update snaps on the provisioned device for now; we'll
# update them manually later. If changing this remember that Core
# may auto-reboot after a snap refresh.
ssh "ubuntu@$DEVICE_IP" 'sudo snap set system refresh.hold="$(date --date=tomorrow +%Y-%m-%dT%H:%M:%S%:z)"'

mkdir artifacts
cd artifacts
date --utc --rfc-3339=ns > job-start-timestamp

curl -Ss -O https://raw.githubusercontent.com/CanonicalLtd/server-test-scripts/master/boot-speed/testflinger/bootspeed.sh
chmod +x bootspeed.sh
scp -p bootspeed.sh "ubuntu@$DEVICE_IP:"

bootid=$(ssh "ubuntu@$DEVICE_IP" cat /proc/sys/kernel/random/boot_id)
ssh "ubuntu@$DEVICE_IP" rm -rfv artifacts
ssh "ubuntu@$DEVICE_IP" ./bootspeed.sh
scp -r "ubuntu@$DEVICE_IP:artifacts" boot_0

ssh "ubuntu@$DEVICE_IP" snap changes
ssh "ubuntu@$DEVICE_IP" sudo snap refresh

# This is a very delicate point, as Ubuntu Core may auto-reboot when snaps
# are updated. We wait until `snap changes` reports that all the changes are
# "Done". The command has to output at least one line to be considered valid.
timeout 40m sh -c "until ssh ubuntu@$DEVICE_IP snap changes |
                                               tee /dev/stderr |
                                               awk '{
                                                      if (NR==1 || \$0==\"\") { next }
                                                      if (\$2==\"Doing\") { exit 1 }
                                                      if (\$2==\"Error\") { system(\"ssh ubuntu@$DEVICE_IP sudo snap refresh\") }
                                                    } END { if (NR==0) { exit 1 } }'
                   do
                       echo \"[\$(date --utc)] Sleeping...\"
                       sleep 10s
                   done"

echo "Snap status is stable."

reboots=1

for rebootidx in $(seq 1 $reboots); do
    echo "[$(date --utc)] Rebooting system for reboot $rebootidx of $reboots"
    ssh "ubuntu@$DEVICE_IP" sudo systemctl reboot || true

    # Wait for the system to be back online (i.e. we can ssh to it).
    # This is basically what the testflinger agent does, e.g.
    # https://git.launchpad.net/snappy-device-agents/tree/devices/rpi3/rpi3.py
    sleep 2m
    if timeout 20m sh -c "until ssh ubuntu@$DEVICE_IP uptime; do sleep 10; done"; then
        # Did the device reboot for real?
        new_bootid=$(ssh "ubuntu@$DEVICE_IP" cat /proc/sys/kernel/random/boot_id)
        if [ "$new_bootid" = "$bootid" ]; then
            touch DEVICE-DID-NOT-REBOOT
            exit 1
        fi
        bootid=$new_bootid

        ssh "ubuntu@$DEVICE_IP" ./bootspeed.sh
        scp -r "ubuntu@$DEVICE_IP:artifacts" "boot_$rebootidx"
    else
        touch "DEVICE-DID-NOT-SURVIVE-REBOOT-$rebootidx"
        exit 1
    fi
done

ssh "ubuntu@$DEVICE_IP" touch boot-speed-measurement-taken-here
ssh "ubuntu@$DEVICE_IP" rm -rfv artifacts

# When retrieving the artifacts file we check for the existence of
# this file to tell if the measurement was fulle successful.
touch testflinger-script-ok
