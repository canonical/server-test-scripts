#!/usr/bin/env python3
"""
Measure the boot speed of cloud instances.

Copyright 2019 Canonical Ltd.
Paride Legovini <paride.legovini@canonical.com>
"""

import argparse
import datetime as dt
import glob
import json
import logging
import tarfile
import os
import paramiko
import pycloudlib
import sys

from pathlib import Path


known_clouds = ['ec2', 'gce']


def create_sftp_client(host, user, port=22, password=None, keyfilepath=None):
    """
    create_sftp_client(host, port, user, password, keyfilepath) -> SFTPClient
    """
    sftp = None
    key = None
    transport = None
    try:
        if keyfilepath is not None:
            # Get private key used to authenticate user.
            key = paramiko.RSAKey.from_private_key_file(keyfilepath)

        # Create Transport object using supplied method of authentication.
        transport = paramiko.Transport((host, port))
        transport.connect(None, user, password, key)

        sftp = paramiko.SFTPClient.from_transport(transport)

        return sftp
    except Exception as e:
        print('An creating SFTP client: %s: %s' % (e.__class__, e))
        if sftp is not None:
            sftp.close()
        if transport is not None:
            transport.close()
        pass


def cloudid2serial(id):
    stream = pycloudlib.streams.Streams(
        mirror_url='https://cloud-images.ubuntu.com/daily',
        keyring_path='/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg'
    )
    filters = ['id=%s' % id]
    res = stream.query(filters)
    id = res[0]['id']
    return id


def measure_instance(instance, datadir, reboots=1):
    print("Measuring instance", instance.id)

    # Use the same command (and hence format) used when measuring devices
    os.system("date --utc --rfc-3339=ns > " +
              str(Path(datadir, "job-start-timestamp")))

    # Do not refresh the snaps for the moment.
    # Regular Ubuntu Server images do not auto-reboot on snap refreshes as Core
    # does, but we want to keep the measurement scripts as similar as possible.

    instance.execute(
        'sudo snap set system refresh.hold='
        '"$(date --date=tomorrow +%Y-%m-%dT%H:%M:%S%:z)"')

    instance.execute(
        "wget https://raw.githubusercontent.com/paride/"
        "server-test-scripts/bootspeed/boot-speed/testflinger/bootspeed.sh")
    # instance.execute(
    #     "wget https://raw.githubusercontent.com/CanonicalLtd/"
    #     "server-test-scripts/master/boot-speed/testflinger/bootspeed.sh")
    instance.execute("chmod +x bootspeed.sh")
    bootid = instance.execute("cat /proc/sys/kernel/random/boot_id")
    print("boot_id:", bootid)

    instance.execute("rm -rf artifacts")
    outstr = instance.execute("./bootspeed.sh 2>&1")
    print(outstr)

    # Test for the existence of the file bootspeed.sh creates if it reached to
    # the end of the measurement with no errors.
    print(instance.execute("find artifacts"))
    outstr = instance.execute("test -f artifacts/measurement-successful"
                              "&& echo ok")
    print("'" + outstr + "'")
    if outstr != "ok":
        print("measurement failed (missing measurement-successful)!")
        sys.exit(1)

    instance.execute("mv artifacts boot_0")
    instance.execute("tar czf boot_0.tar.gz boot_0")

    sftpclient = create_sftp_client(
        instance.ip, 'ubuntu', keyfilepath=instance.key_pair.private_key_path)
    sftpclient.get("boot_0.tar.gz", "boot_0.tar.gz")
    sftpclient.close()

    instance.execute("sudo snap refresh")

    for nboot in range(1, reboots+1):
        bootdir = "boot_" + str(nboot)
        instance.restart()
        new_bootid = instance.execute("cat /proc/sys/kernel/random/boot_id")
        if new_bootid == bootid:
            print("Cloud instance did not reboot!")
            sys.exit(1)
        bootid = new_bootid
        instance.execute("rm -rf artifacts")
        outstr = instance.execute("./bootspeed.sh 2>&1")
        print(outstr)
        instance.execute("mv artifacts " + bootdir)
        instance.execute("tar czf " + bootdir + ".tar.gz " + bootdir)

        sftpclient = create_sftp_client(
            instance.ip, 'ubuntu',
            keyfilepath=instance.key_pair.private_key_path)
        sftpclient.get(bootdir + ".tar.gz", bootdir + ".tar.gz")
        sftpclient.close()

    for tarball in glob.glob('boot_*.tar.gz'):
        with tarfile.open(tarball, "r:gz") as tar:
            tar.extractall(path=datadir)
        os.unlink(tarball)


def measure_ec2(
        release, datadir, *, inst_type="t2.micro", region="us-east-1",
        instances=1, reboots=1):
    """
    Measure Amazon AWS EC2.
    Returns the measurement metadata as a dictionary
    """
    print('Perforforming measurement on Amazon EC2')

    logging.basicConfig(level=logging.DEBUG)
    ec2 = pycloudlib.EC2(tag='bootspeed', region=region)

    daily = ec2.daily_image(release=release)
    print("Daily image for", release, "is", daily)

    metadata = gen_metadata("ec2", region, inst_type, release, daily)

    for ninstance in range(instances):
        instance_data = Path(datadir, "instance_" + str(ninstance))
        instance_data.mkdir()

        print("Launching instance", ninstance+1, "of", instances)
        instance = ec2.launch(
            daily,
            instance_type=inst_type,
            SecurityGroupIds=['sg-03a824e4cbba1718c']
        )
        print("Instance launched.")

        try:
            measure_instance(instance, instance_data, reboots)
        finally:
            instance.delete()

    return metadata


def gen_metadata(cloud, region, inst_type, release, cloudid):
    """ Returns the instance metadata as a dictionary """
    yyyymmdd = dt.datetime.utcnow().strftime('%Y%m%d')
    isodate = dt.datetime.utcnow().isoformat()

    serial = cloudid2serial(cloudid)

    metadata = {}
    metadata['date'] = yyyymmdd
    metadata['date-rfc3339'] = isodate
    metadata['type'] = "cloud"
    metadata['instance'] = {
        'cloud': cloud,
        'region': region,
        'instance_type': inst_type,
        'release': release,
        'cloudimage_id': cloudid,
        'image_serial': serial,
    }

    return metadata


def gen_datadirname(metadata):
    """ Generate a standardized measurement directory (and tarball) name """
    yyyymmdd = metadata['date']
    cloud = metadata['instance']['cloud']
    release = metadata['instance']['release']

    datadir = Path(cloud + "-" + release + "_" + yyyymmdd)
    return datadir


def main(cloud, release, instances, reboots):
    if cloud not in known_clouds:
        print('Unknown cloud provider:', cloud)
        sys.exit(1)

    tmp_datadir = Path("data")
    tmp_datadir.mkdir()

    if cloud == 'ec2':
        metadata = measure_ec2(release, tmp_datadir)
    else:
        raise NotImplementedError

    with open(Path(tmp_datadir, "metadata.json"), 'w') as mdfile:
        json.dump(metadata, mdfile)

    datadir = gen_datadirname(metadata)
    with tarfile.open(datadir.with_suffix(".tar.gz"), "w:gz") as tar:
        tar.add("data", arcname=datadir)


if __name__ == '__main__':
    PARSER = argparse.ArgumentParser()
    PARSER.add_argument('-c', '--cloud', help='Cloud to measure',
                        choices=known_clouds, required=True)
    PARSER.add_argument('-r', '--release',
                        help='Ubuntu release to measure', required=True)
    PARSER.add_argument('--reboots', help='Number of reboots',
                        default=1, type=int)
    PARSER.add_argument('--instances', help='Number of instances',
                        default=1, type=int)
    ARGS = PARSER.parse_args()
    main(ARGS.cloud, ARGS.release, ARGS.instances, ARGS.reboots)
