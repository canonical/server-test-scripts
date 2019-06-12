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
import shutil
import sys

from pathlib import Path


known_clouds = ['ec2', 'gce']


class EC2Instspec:
    def __init__(self, *, release, inst_type, region, ec2_subnetid, ec2_sgid):
        # Defaults. They can't be set as keyword argument defaults because
        # we're always passing all the arguments to __init__, even if they
        # are None. And they can't be set as the argparse default values,
        # as different coulds need different defaults.
        self.region = "us-east-1"
        self.inst_type = "t2.micro"
        self.subnetid = ""
        self.sgid = []

        # User-specified settings
        self.release = release

        if inst_type:
            self.inst_type = inst_type
        if region:
            self.region = region
        if ec2_subnetid:
            self.subnetid = ec2_subnetid
        if ec2_sgid:
            self.sgid = [ec2_sgid]

    def measure(self, datadir, instances=1, reboots=1):
        """
        Measure Amazon AWS EC2.
        Returns the measurement metadata as a dictionary
        """
        print('Perforforming measurement on Amazon EC2')

        ec2 = pycloudlib.EC2(tag='bootspeed', region=self.region)

        if self.inst_type.split('.')[0] == 'a1':
            daily = ec2.daily_image(release=self.release, arch='arm64')
        else:
            daily = ec2.daily_image(release=self.release)

        print("Daily image for", self.release, "is", daily)

        metadata = gen_metadata(
            "ec2", self.region, self.inst_type, self.release, daily)

        for ninstance in range(instances):
            instance_data = Path(datadir, "instance_" + str(ninstance))
            instance_data.mkdir()

            # This tag name will be inherited by the launched instance.
            # We want it to be unique and to contain an easily parsable
            # timestamp (UTC seconds since epoch), which we will use to
            # detemine if an instance is stale and should be terminated.
            tag = "bootspeed-" + str(int(dt.datetime.utcnow().timestamp()))
            ec2.tag = tag

            print("Launching instance", ninstance+1,
                  "of", instances, "tag:", ec2.tag)
            instance = ec2.launch(
                daily,
                instance_type=self.inst_type,
                SubnetId=self.subnetid,
                SecurityGroupIds=self.sgid
            )
            print("Instance launched.")

            try:
                measure_instance(instance, instance_data, reboots)
            finally:
                print("Deleting the instance.")
                instance.delete(wait=False)

        return metadata


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
        "wget https://raw.githubusercontent.com/CanonicalLtd/"
        "server-test-scripts/master/boot-speed/bootspeed.sh")
    instance.execute("chmod +x bootspeed.sh")
    bootid = instance.execute("cat /proc/sys/kernel/random/boot_id")
    print("boot_id:", bootid)

    instance.execute("rm -rf artifacts")
    outstr = instance.execute("./bootspeed.sh 2>&1")
    print(outstr)
    outstr = instance.execute("find artifacts")
    print(outstr)

    # Test for the existence of the file bootspeed.sh creates if it reached to
    # the end of the measurement with no errors.
    outstr = instance.execute("test -f artifacts/measurement-successful"
                              "&& echo ok")
    if outstr != "ok":
        print("Measurement failed (missing measurement-successful)!")
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
            tar.extractall(path=str(datadir))
        os.unlink(tarball)


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


def gen_archivename(metadata):
    """ Generate a standardized measurement directory (and tarball) name """
    yyyymmdd = metadata['date']
    cloud = metadata['instance']['cloud']
    inst_type = metadata['instance']['instance_type']
    release = metadata['instance']['release']

    datadir = cloud + "-" + inst_type + "-" + release + "_" + yyyymmdd
    return datadir


def main():
    args = parse_args()

    if args.cloud not in known_clouds:
        print('Unknown cloud provider:', args.cloud)
        sys.exit(1)

    if args.cloud == 'ec2':
        instspec = EC2Instspec(
            release=args.release, inst_type=args.inst_type, region=args.region,
            ec2_subnetid=args.ec2_subnetid, ec2_sgid=args.ec2_sgid)
    else:
        raise NotImplementedError

    tmp_datadir = Path("data")
    tmp_datadir.mkdir()

    logging.basicConfig(level=logging.DEBUG)
    metadata = instspec.measure(tmp_datadir, args.instances, args.reboots)

    # str() needed for compatibility with Python <= 3.5
    with open(str(Path(tmp_datadir, "metadata.json")), 'w') as mdfile:
        json.dump(metadata, mdfile)

    archivename = gen_archivename(metadata)
    with tarfile.open((archivename + ".tar.gz"), "w:gz") as tar:
        tar.add(str(tmp_datadir), arcname=archivename)

    shutil.rmtree(str(tmp_datadir))


def parse_args():
    PARSER = argparse.ArgumentParser()
    PARSER.add_argument('-c', '--cloud', help='Cloud to measure',
                        choices=known_clouds, required=True)
    PARSER.add_argument('-t', '--inst-type', help='Instance type')
    PARSER.add_argument('-r', '--release',
                        help='Ubuntu release to measure', required=True)
    PARSER.add_argument('--reboots', help='Number of reboots',
                        default=1, type=int)
    PARSER.add_argument('--instances', help='Number of instances',
                        default=1, type=int)
    PARSER.add_argument('--ec2-subnetid', help='AWS EC2 SubnetId')
    PARSER.add_argument('--ec2-sgid', help='AWS EC2 SecurityGroupId')
    PARSER.add_argument('--region', help='Cloud region')
    ARGS = PARSER.parse_args()
    return ARGS


if __name__ == '__main__':
    main()
