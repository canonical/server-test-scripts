#!/bin/sh

set -ex

export LC_ALL="C.UTF-8"

echo
echo "### Running $0 on the provisioned system"
echo

# The rpi3bplus-core{16,18} doesn't get reprovisioned before running a new job,
# so we have to clean up what we left from the previous runs. This is not a
# problem when doing the full provisioning (as we plan to do for the boot time
# measurements), but using the pre-provisioned devices is useful for testing,
# as it is much faster.
#
# <plars> paride: yeah, that particular device doesn't get reprovisioned
# <plars> paride: so it will still have whatever you left behind on it.
#         there's a bug with cloud init on core18 with rpi3bplus
rm -rfv artifacts

mkdir -v artifacts
cd artifacts

# Wait for `cloud-init status --wait` to exit (with a timeout)
if ! timeout 20m cloud-init status --wait; then
    touch CLOUDINIT-DID-NOT-FINISH-IN-TIME
    exit 1
fi

# Wait for systemd-analyze to exit with status 0 (success)
# https://github.com/systemd/systemd/blob/1cae151/src/analyze/analyze.c#L279
if timeout 10m sh -c "until systemd-analyze time; do sleep 10; done"; then
    # Gather the actual data
    systemd-analyze time > systemd-analyze_time
    systemd-analyze blame > systemd-analyze_blame
    systemd-analyze critical-chain > systemd-analyze_critical-chain
    systemd-analyze plot > systemd-analyze_plot.svg
else
    touch SYSTEM-DID-NOT-BOOT-IN-TIME
    exit 1
fi

date --utc --rfc-3339=ns > date-rfc-3339
hostname > hostname
arch > arch
uname -a > uname-a
id > id
w > w
pwd > pwd
ip addr > ip-addr
free -m > free-m
mount > mount
df -h > df-h

#sh -x -c "date --utc --rfc-3339=ns ; \
#          hostname ; \
#          arch ; \
#          uname -a ; \
#          id ; \
#          w ; \
#          pwd ; \
#          ip addr ; \
#          free -m ; \
#          mount ; \
#          df -h" > system-info 2>&1

cp -v /proc/cpuinfo .
cp -v /etc/os-release .

# There should be no jobs running once boot is finished.
# This is mostly useful to debug boot timeouts.
systemctl list-jobs > systemctl_list-jobs

# Gather additional data
cp -v /etc/fstab .

. /etc/os-release

if [ "$NAME" != "Ubuntu Core" ]; then
    cp -v /var/log/cloud-init.log .
    sudo apt -y install pciutils usbutils
    dpkg-query --list > dpkg-query.out 2>&1 || true
    sudo lspci -vvv > lspci.out 2>&1 || true
    sudo lsusb -v > lsusb.out 2>&1 || true
fi

snap list > snap_list
ls -l > directory-listing

echo
echo "### End of $0"
echo
