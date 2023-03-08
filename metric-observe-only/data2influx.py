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


def parse_processcount_measurement(fname, point):
    """Parse raw data of processcount and extract measurement."""

    with open(fname, "r", encoding="utf-8") as processlist:
        count = len(processlist.readlines())

    point["fields"] = {"count": count}


def parse_ssh_measurement(fname, point):
    """Parse raw data of ssh login speed and extract measurement."""

    with open(fname, "r", encoding="utf-8") as rawdataf:
        rawdata = json.load(rawdataf)

    fname_first = fname.replace("warm", "first")
    with open(fname_first, "r", encoding="utf-8") as rawdataf:
        rawdata_first = json.load(rawdataf)

    rawdata = rawdata["results"][0]
    rawdata_first = rawdata_first["results"][0]

    point["fields"] = {
            "first": rawdata_first["times"][0],
            "mean": rawdata["mean"],
            "stddev": rawdata["stddev"],
            "median": rawdata["median"],
            "min": rawdata["min"],
            "max": rawdata["max"],
    }


def parse_vmstat_measurement(fname, point):
    """Parse raw data of vmstat output and extract measurement."""

    with open(fname, "r", encoding="utf-8") as rawdataf:
        vmstat_lines = rawdataf.readlines()
        vmstat_boot = vmstat_lines[2].split()
        vmstat_avg = vmstat_lines[3].split()

    if len(vmstat_lines) != 4:
        print("WARNING: vmstat file does not have expected lines!")
        return

    point["fields"] = {
            "swpd":  vmstat_avg[2],
            "free":  vmstat_avg[3],
            "buff":  vmstat_avg[4],
            "cache": vmstat_avg[5],
            "user":  vmstat_avg[12],
            "sys":   vmstat_avg[13],
            "idle":  vmstat_avg[14],
            "wait":  vmstat_avg[15],
            "steal": vmstat_avg[16],
            "boot_usr":   vmstat_boot[12],
            "boot_sys":   vmstat_boot[13],
            "boot_idle":  vmstat_boot[14],
            "boot_wait":  vmstat_boot[15],
            "boot_steal": vmstat_boot[16],
    }


def main(fname, metrictype, dryrun):
    """Take raw measurement, parse it, feed it to InfluxDB."""

    data = []
    tokens = filename_to_tokens(fname)
    point = {
        "time": tokens["timestamp"],
        "measurement": "processcount",
        "tags": {
            "release": tokens["release"],
            "what": tokens["what"],
            "cpu": tokens["cpu"],
            "mem": tokens["mem"],
        }
    }

    if metrictype == "ssh_noninteractive":
        parse_ssh_measurement(fname, point)
    elif metrictype == "processcount":
        parse_processcount_measurement(fname, point)
    elif metrictype == "vmstat":
        parse_vmstat_measurement(fname, point)
    else:
        data = None
        print(f"WARNING: unknown metric type {metrictype}!")

    if "fields" in point:
        data.append(point)
    else:
        print("WARNING: point does not include fields")

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
