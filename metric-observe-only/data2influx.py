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


def filename_to_tokens(fname):
    """Converts a filename following an agreed pattern to tokens"""
    rstr = r"results-[a-z]*-(\w+)-(\w+)-(\w+)-(\w+)-(.+)(?:-warm\.json|.txt)"
    fname_tokens = re.search(rstr, fname)
    tokens = {
            "release": fname_tokens.group(1),
            "what": fname_tokens.group(2),
            "cpu": int(fname_tokens.group(3)[1:]),
            "mem": int(fname_tokens.group(4)[1:]),
            "timestamp": fname_tokens.group(5),
            }
    return tokens


def parse_processcount_measurement(fname):
    """Parse raw data of processcount and extract measurement."""
    tokens = filename_to_tokens(fname)

    with open(fname, "r", encoding="utf-8") as processlist:
        count = len(processlist.readlines())

    data = []

    point = {
        "time": tokens["timestamp"],
        "measurement": "processcount",
        "tags": {
            "release": tokens["release"],
            "what": tokens["what"],
            "cpu": tokens["cpu"],
            "mem": tokens["mem"],
        },
        "fields": {
            "count": count,
        },
    }

    data.append(point)
    return data


def parse_ssh_measurement(fname):
    """Parse raw data of ssh login speed and extract measurement."""
    tokens = filename_to_tokens(fname)

    with open(fname, "r", encoding="utf-8") as rawdataf:
        rawdata = json.load(rawdataf)

    fname_first = fname.replace("warm", "first")
    with open(fname_first, "r", encoding="utf-8") as rawdataf:
        rawdata_first = json.load(rawdataf)

    rawdata = rawdata["results"][0]
    rawdata_first = rawdata_first["results"][0]

    data = []

    point = {
        "time": tokens["timestamp"],
        "measurement": "ssh_noninteractive",
        "tags": {
            "release": tokens["release"],
            "what": tokens["what"],
            "cpu": tokens["cpu"],
            "mem": tokens["mem"],
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


def main(fname, metrictype, dryrun):
    """Take raw measurement, parse it, feed it to InfluxDB."""

    if metrictype == "ssh_noninteractive":
        data = parse_ssh_measurement(fname)
    elif metrictype == "processcount":
        data = parse_processcount_measurement(fname)
    else:
        data = None
        print(f"WARNING: unknown metric type {metrictype}!")

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
    PARSER.add_argument("-t", "--metrictype", help="Metric type to parse",
                        required=True)
    ARGS = PARSER.parse_args()
    main(ARGS.fname, ARGS.metrictype, ARGS.dryrun)
