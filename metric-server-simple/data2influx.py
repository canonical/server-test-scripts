#!/usr/bin/env python3
"""Parse various metrics of spec US013 and populate the InfluxDB."""

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
    rstr = (r"results-[a-z]*-(\w+)-(\w+)-(\w+)-(\w+)-(\w+)-(.+)"
            r"-(\w+)\.(txt|json)")
    fname_tokens = re.search(rstr, fname)
    tokens = {
            "machineid": fname_tokens.group(1),
            "release": fname_tokens.group(2),
            "what": fname_tokens.group(3),
            "cpu": int(fname_tokens.group(4)[1:]),
            "mem": int(fname_tokens.group(5)[1:]),
            "timestamp": fname_tokens.group(6),
            "stage": fname_tokens.group(7)
            }
    return tokens


def parse_processcount_measurement(fname, point):
    """Parse raw data of processcount and extract measurement."""

    count = {"kworker": 0,
             "scsi_": 0,
             "systemd": 0,
             "rcu_": 0,
             "ext4lazyinit": 0}
    count_others = 0

    with open(fname, "r", encoding="utf-8") as processlist:
        lines = processlist.readlines()
        for line in lines:
            counted = False
            for prefix in count:
                try:
                    if line.split()[3].startswith(prefix):
                        count[prefix] += 1
                        counted = True
                        break
                except IndexError:
                    break
            if not counted:
                count_others += 1

    point["fields"] = {}
    for prefix, prefixcount in count.items():
        point["fields"][prefix] = prefixcount
    point["fields"]["proccount"] = count_others


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


def parse_cpustat_measurement(fname, point):
    """Parse raw data of vmstat output and extract measurement."""

    with open(fname, "r", encoding="utf-8") as rawdataf:
        vmstat_lines = rawdataf.readlines()
        vmstat_boot = vmstat_lines[2].split()
        vmstat_avg = vmstat_lines[3].split()

    if len(vmstat_lines) != 4:
        print("WARNING: vmstat file does not have expected lines!")
        return

    point["fields"] = {
            "user":  int(vmstat_avg[12]),
            "sys":   int(vmstat_avg[13]),
            "idle":  int(vmstat_avg[14]),
            "wait":  int(vmstat_avg[15]),
            "steal": int(vmstat_avg[16]),
            "boot_usr":   int(vmstat_boot[12]),
            "boot_sys":   int(vmstat_boot[13]),
            "boot_idle":  int(vmstat_boot[14]),
            "boot_wait":  int(vmstat_boot[15]),
            "boot_steal": int(vmstat_boot[16]),
    }


def parse_disk_measurement(fname, point):
    """Parse raw data of vmstat output and extract measurement."""

    with open(fname, "r", encoding="utf-8") as rawdataf:
        disk_lines = rawdataf.readlines()
        disk_entry = disk_lines[1].split()

    if len(disk_entry) != 6:
        print("WARNING: df output in unexpected format!")
        return

    point["fields"] = {
            "usedmb": int(disk_entry[2]),
    }


def parse_ports_measurement(fname, point):
    """Parse raw port data of ss output and extract measurement."""

    with open(fname, "r", encoding="utf-8") as portlist:
        # minus header
        count = len(portlist.readlines()) - 1

    point["fields"] = {"portcount": int(count)}


def parse_meminfo_measurement(fname, point):
    """Parse raw data of meminfo output and extract measurement."""

    meminfo = {}
    with open(fname, "r", encoding="utf-8") as rawdataf:
        meminfo_lines = rawdataf.readlines()
        for line in meminfo_lines:
            lineinfo = line.split()
            meminfo[lineinfo[0]] = lineinfo[1]

    point["fields"] = {
        # Track these
        "MemFree": int(meminfo["MemFree:"]),
        "MemAvailable": int(meminfo["MemAvailable:"]),
        "Mlocked": int(meminfo["Mlocked:"]),
        # For quick sanity checks
        "AnonPages": int(meminfo["AnonPages:"]),
        "Mapped": int(meminfo["Mapped:"]),
        "Shmem": int(meminfo["Shmem:"]),
        "MemTotal": int(meminfo["MemTotal:"]),
        "SwapTotal": int(meminfo["SwapTotal:"]),
        "SwapFree": int(meminfo["SwapFree:"]),
        "Dirty": int(meminfo["Dirty:"]),
        "Buffers": int(meminfo["Buffers:"]),
        "Cached": int(meminfo["Cached:"]),
        "KReclaimable": int(meminfo["KReclaimable:"]),
    }


def main(fname, metrictype, dryrun):
    """Take raw measurement, parse it, feed it to InfluxDB."""

    data = []
    tokens = filename_to_tokens(fname)
    point = {
        "time": tokens["timestamp"],
        "measurement": metrictype,
        "tags": {
            "release": tokens["release"],
            "what": tokens["what"],
            "cpu": tokens["cpu"],
            "mem": tokens["mem"],
        }
    }

    # all tests might have stages, ssh_noninteractive was created before
    # the need to express those in tags and we need to keep the databse
    # format stable.
    # ssh_noninteractive has stages (first & warm) but maps both results
    # into one data point, all others get the stage as a tag to filter
    # later (anything before the filename suffix will be the stage).
    # That allows adding arbitrary stages later without changing the format
    # or the parsing.
    if metrictype != "ssh_noninteractive":
        point["tags"]["stage"] = tokens["stage"]
        point["tags"]["machineid"] = tokens["machineid"]

    if metrictype == "ssh_noninteractive":
        parse_ssh_measurement(fname, point)
    elif metrictype == "metric_processcount":
        parse_processcount_measurement(fname, point)
    elif metrictype == "metric_cpustat":
        parse_cpustat_measurement(fname, point)
    elif metrictype == "metric_meminfo":
        parse_meminfo_measurement(fname, point)
    elif metrictype == "metric_ports":
        parse_ports_measurement(fname, point)
    elif metrictype == "metric_disk":
        parse_disk_measurement(fname, point)
    else:
        data = None
        print(f"WARNING: unknown metric type {metrictype}!")

    if "fields" in point:
        data.append(point)
        print(data)

        if not dryrun:
            client = influx_connect()
            client.write_points(data)

    else:
        print(f"WARNING: no measurements found in {fname} => {point}!")


if __name__ == "__main__":
    PARSER = argparse.ArgumentParser()
    PARSER.add_argument("--dryrun", action="store_true")
    PARSER.add_argument("-f", "--fname", help="Input file name", required=True)
    PARSER.add_argument("-t", "--metrictype", help="Metric type to parse",
                        required=True)
    ARGS = PARSER.parse_args()
    main(ARGS.fname, ARGS.metrictype, ARGS.dryrun)
