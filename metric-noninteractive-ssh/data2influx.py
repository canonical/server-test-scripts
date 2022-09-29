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

    timestamp = re.search(r"results-([0-9]+).json", fname).group(1)

    with open(fname, "r", encoding="utf-8") as rawdataf:
        rawdata = json.load(rawdataf)

    rawdata = rawdata["results"][0]

    data = []

    point = {
        "time": timestamp,
        "measurement": "ssh_noninteractive",
        "fields": {
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
