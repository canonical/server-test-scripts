#!/usr/bin/env python3
"""Parse the ssh noninteractive login time data and populate the InfluxDB."""

import argparse
import json
import os
import re
import sys

from influxdb import InfluxDBClient


def influx_connect():
    """Connect to an InfluxDB instance."""
    try:
        hostname = os.environ["INFLUXDB_HOSTNAME"]
        port = os.environ["INFLUXDB_PORT"]
        username = os.environ["INFLUXDB_USERNAME"]
        password = os.environ["INFLUXDB_PASSWORD"]
        database = os.environ["INFLUXDB_DATABASE"]
    except KeyError:
        print("error: please source influx credentials before running")
        sys.exit(1)

    return InfluxDBClient(hostname, port, username, password, database)


def parse_measurement(fname):
    """Parse raw data and extract measurement."""

    fname_tokens = re.search(r"results-(\w+)-(\w+)-(\w+)-(\w+)-(.+)\.json", fname)
    release = fname_tokens.group(1)
    what = fname_tokens.group(2)
    cpu = int(fname_tokens.group(3)[1:])
    mem = int(fname_tokens.group(4)[1:])
    timestamp = fname_tokens.group(5)

    with open(fname, "r", encoding="utf-8") as rawdataf:
        rawdata = json.load(rawdataf)

    with open(fname.replace(".json", "-first.json"), "r", encoding="utf-8") as rawdataf:
        rawdata_first = json.load(rawdataf)

    rawdata = rawdata["results"][0]
    rawdata_first = rawdata_first["results"][0]

    data = []

    point = {
        "time": timestamp,
        "measurement": "ssh_noninteractive",
        "tags": {
            "release": release,
            "what": what,
            "cpu": cpu,
            "mem": mem,
        },
        "fields": {
            "first": rawdata_first["times"][0],
            "mean": rawdata["mean"],
            "stddev": rawdata["stddev"],
            "median": rawdata["median"],
            "min": rawdata["min"],
            "max": rawdata["max"],
        },
    }

    data.append(point)

    return data


def main(fname, dryrun):
    """Take raw measurement, parse it, feed it to InfluxDB."""

    data = parse_measurement(fname)

    if len(data) > 0:
        print(data)

        if not dryrun:
            client = influx_connect()
            client.write_points(data)

    else:
        print(f"WARNING: no measurements found in {fname}!")


if __name__ == "__main__":
    PARSER = argparse.ArgumentParser()
    PARSER.add_argument("--dryrun", action="store_true")
    PARSER.add_argument("-f", "--fname", help="Input file name", required=True)
    ARGS = PARSER.parse_args()
    main(ARGS.fname, ARGS.dryrun)
