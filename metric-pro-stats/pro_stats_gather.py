#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Copyright © 2022 Christian Ehrhardt <christian.ehrhardt@canonical.com>
# License:
# GPLv2 (or later), see /usr/share/common-licenses/GPL
"""Derive some stats from anonymyzed ESM access logs to better serve more users

This will fetch access logs and create statistics on their usage
to help further decisions, like what to support next or which package
to fix first.

It is expected that the swift access information is provided in environment
variables, see this for more swift details:
https://docs.openstack.org/python-swiftclient/latest/service-api.html
"""

# Requirements (Ubuntu Packages):
# - python3 >= 3.9
# - python3-debian
# - python3-distro-info
# - python3-dotenv
# - python3-filelock
# - python3-pandas
# - python3-swiftclient
# - devscripts
# Optional (speedup)
# - madison-lite and if present fully set for fast local execution

# test via pytest-3
#   pytest-3 esm-stats.py
# and if failing try to have a look with
#   pytest-3 --log-cli-level debug esm-stats.py

import argparse
import concurrent.futures as ccf
import gzip
import json
import logging
import multiprocessing as mp
import os
import re
import subprocess
import sys
import tempfile

from contextlib import nullcontext
from datetime import datetime, timedelta
from shutil import which, copyfileobj
from urllib.parse import unquote

import pandas as pd

from debian.debian_support import Version
from distro_info import UbuntuDistroInfo
from dotenv import dotenv_values
from filelock import FileLock
from swiftclient.service import SwiftService
from swiftclient.service import SwiftError

# basic fallback
LOGGER = logging.getLogger(__name__)
CONTAINER = "production"

MADISON_CMD = 'madison-lite'
if which(MADISON_CMD) is None:
    MADISON_CMD = 'rmadison'
    if which(MADISON_CMD) is None:
        print("Error, either madison-lite or rmadison need to be available")
        sys.exit(1)

ESM_RELEASES = UbuntuDistroInfo().supported_esm()
RELEASE_POCKETS = ["", "-security", "-updates"]
ESM_RELEASES_C = ""
for suffix in RELEASE_POCKETS:
    for rel in ESM_RELEASES:
        ESM_RELEASES_C += rel+suffix+","
ESM_RELEASES_R = "|".join(ESM_RELEASES)
VERSION_PATTERNS = [
    # esm backports: 2021e-0ubuntu0.14.04+esm1
    # ros: 0.4.23+18.04.4-0 / 1.8.5~18.04.1
    ('version', re.compile(r'[a-zA-Z0-9~+\-\.]*(?:ubuntu\d+\.|\+|~){1}'
                           r'([1-3][24680]\.04)?')),
    # esm backports: 3.5.2-0ubuntu4.1.18.04.1~esm1
    ('version', re.compile(r'[a-zA-Z0-9~+\-\.]*(?:ubuntu){1}(?:\d\.)*'
                           r'([1-3][24680]\.04)?')),
    # tilde directly on ubuntu in backports: 1.2.6-0ubuntu1~16.04.6+esm2
    ('version', re.compile(r'[a-zA-Z0-9~+\-\.]*ubuntu\d~([1-3][24680]\.04)?')),
    # fips 7.9p1-10~ubuntu18.04.fips.0.2
    ('version', re.compile(r'[a-zA-Z0-9+\-\.]*(?:~ubuntu){1}'
                           r'([1-3][24680]\.04)?')),
    # cc & cis: 1.0.16.04.1 / 18.04.18 / 20.04.4.3
    ('version', re.compile(r'(?:\d\.)*([1-3][24680]\.04)?.*')),
    # s: linux-meta-hwe v: 4.15.0.143.139 b: linux-headers-generic-hwe-16.04
    ('binary', re.compile(r'.*-([1-3][24680]\.04)?(?:-edge)?$')),
]
NAME_PATTERNS = [
    # s: linux-meta-lts-xenial
    ('source', re.compile(rf'[a-z0-9\-]*-({ESM_RELEASES_R})$')),
]

MAP_XXYY_TO_REL = {
   '12.04': "precise",
   '14.04': "trusty",
   '16.04': "xenial",
   '18.04': "bionic",
   '20.04': "focal",
   '22.04': "jammy",
}
# Some PKG build binaries with entriely different versions, checking those
# is slower and hence considered a special case for those in this list.
BPKG_KNOWN_TO_DIFFER_FROM_SRC = ["comerr-dev"]

PKG_DATA_FIELDS = ['Service',
                   'Release',
                   'Source',
                   'Version',
                   'Binary']


class VerToRelCache:
    """Provides fast src/version->release mappings.

    The http logs do not contain releases, mapping that from just src/version
    turned out to be rather expensive. Caching that even across multiple runs
    is beneficial."""
    cache_file_name = None
    map = {}
    lock = nullcontext

    @classmethod
    def set_cache_file(cls, cache_file_name):
        """Sets the cache file name and loads from it if valid."""
        if cache_file_name is None:
            return
        cls.cache_file_name = cache_file_name
        if cache_file_name:
            cls.lock = FileLock(cache_file_name + ".lock")

    @classmethod
    def __load(cls):
        """Loads cache file from disk and returns dict."""
        with open(cls.cache_file_name, "r", encoding='utf-8') as cachefile:
            try:
                return json.load(cachefile)
            except json.decoder.JSONDecodeError:
                print('Errror: could not load from %s', cls.cache_file_name)
                sys.exit(1)

    @classmethod
    def __key(cls, source, version):
        return f'{source}@{version}'

    @classmethod
    def load_cache(cls):
        """Load cache (if file is known) into memory."""
        if not cls.cache_file_name:
            return
        if os.path.exists(cls.cache_file_name):
            with cls.lock:
                cls.map = cls.__load()
            LOGGER.info("Initialized %d cache entries", len(cls.map))

    @classmethod
    def combine_and_serialize(cls):
        """Combine cache with file and store it."""
        if not cls.cache_file_name:
            return

        with cls.lock:
            ondisk = {}
            if os.path.exists(cls.cache_file_name):
                ondisk = cls.__load()
            combined = cls.map | ondisk
            LOGGER.info('map %d | %d => %d entries back to the cache',
                        len(ondisk), len(cls.map), len(combined))
            with open(cls.cache_file_name, "w", encoding='utf-8') as cachefile:
                json.dump(combined, cachefile)
            LOGGER.info("Saved %d cache entries", len(combined))

    @classmethod
    def contains(cls, source, version):
        """Returns true if a src/version key is already cached."""
        return cls.__key(source, version) in cls.map

    @classmethod
    def get_release(cls, source, version):
        """Returns entry for the src/version key."""
        return cls.map[cls.__key(source, version)]

    @classmethod
    def cache_release(cls, source, version, release):
        """Stores the release in the cache and returns the release."""
        cls.map[cls.__key(source, version)] = release
        return release


def is_accesslog(obj, pattern):
    """Check if the object is an access log that we want to process."""
    return bool(pattern.match(obj["name"]))


def get_logs_per_connection(ctime, dirname):
    """Gets the logs from swift storage for each configured connection.

    If no connection has been given it is done once for the environment
    the tool was called with. If given we will run once per connection and
    accumulate the data."""
    if ARGS.connectionenv:
        # Clean potential old conflicts in opts and env
        for envvar in ['OS_USERNAME', 'OS_TENANT_NAME', 'OS_PASSWORD',
                       'OS_AUTH_URL', 'OS_REGION_NAME', 'OS_PROJECT_NAME',
                       'OS_PROJECT_DOMAIN_NAME', 'OS_USER_DOMAIN_NAME',
                       'OS_IDENTITY_API_VERSION', 'OS_INTERFACE',
                       'OS_STORAGE_URL']:
            os.environ.pop(envvar, None)
        data = []
        for conn in ARGS.connectionenv:
            LOGGER.info('Load env from %s', conn)
            opts = {}
            swift_env = dotenv_values(conn)
            for envkey, envval in swift_env.items():
                opts[envkey.lower()] = envval
            data.extend(get_logs_from_swift(ctime, dirname, opts))
        return data

    # Just once with whatever is present in the environment when called
    return get_logs_from_swift(ctime, dirname, {})


def get_logs_from_swift(ctime, dirname, swift_opts):
    """Gets the logs for a given time from swift storage.

    Returns a list of pairs filenames + name which represent the logs
    downloaded to the given directory."""
    downloaded_logs = []
    SWIFT_SEMA.acquire()
    LOGGER.info('Entered Swift transfer context')
    with SwiftService(options=swift_opts) as swift:
        try:
            list_parts_gen = swift.list(container=CONTAINER)
        except SwiftError as error:
            LOGGER.error('Failed to access swift: %s', error.value)
            sys.exit(1)

        day_count = (ctime['end'] - ctime['start']).days + 1
        dates_logformat = []
        for ldate in (ctime['start'] + timedelta(n) for n in range(day_count)):
            dates_logformat.append(ldate.strftime("%Y%m%d"))
        pattern = re.compile(r'.*/esm\.ubuntu\.com-access\.log-('
                             rf'{"|".join(dates_logformat)})\.anon\.gz')
        LOGGER.info('Get logs for %s from swift (%s)', ctime['name'], pattern)

        for page in list_parts_gen:
            # by default max 10.000 answers per page
            if page["success"]:
                objects = [
                        obj["name"]
                        for obj
                        in page["listing"] if is_accesslog(obj, pattern)
                ]
                LOGGER.info('%s of %s objects in %s represent logs for %s',
                            len(objects), len(page["listing"]),
                            swift_opts['os_region_name'],
                            ctime['name'])
                for down_res in swift.download(
                            container=CONTAINER,
                            objects=objects,
                            options={"out_directory": dirname}):
                    if down_res['success']:
                        LOGGER.info('%s downloaded', down_res["object"])
                    else:
                        LOGGER.error('%s download failed', down_res["object"])
                        sys.exit(1)
                downloaded_logs.extend(objects)
            else:
                raise page["error"]

    SWIFT_SEMA.release()
    LOGGER.info('Left Swift transfer context')
    return downloaded_logs


def get_release_pattern(needle):
    """Gets the release name derived from binary/version using patterns."""
    LOGGER.debug("get_release_pattern: %s", needle)
    # Check and map numerical LTS versions
    found_version = False
    for target, pattern in VERSION_PATTERNS:
        LOGGER.debug('VTest pattern "%s"', pattern.pattern)
        versionmatch = pattern.match(needle[target])
        if versionmatch and versionmatch.group(1) is not None:
            LOGGER.debug('VFound "%s"', versionmatch.group(1))
            found_version = versionmatch.group(1)
            break
    if found_version in MAP_XXYY_TO_REL:
        try:
            release = MAP_XXYY_TO_REL[found_version]
        except KeyError:
            # Fall back to the number we found to analyze later
            release = found_version
        LOGGER.debug('VMapped "%s"', release)
        return release

    # Check for release names
    for target, pattern in NAME_PATTERNS:
        LOGGER.debug('NTest pattern "%s"', pattern.pattern)
        namematch = pattern.match(needle[target])
        if namematch and namematch.group(1) is not None:
            LOGGER.debug('NFound "%s"', namematch.group(1))
            return namematch.group(1)

    LOGGER.debug('No Match found')
    return False


def get_release_rmadison(source, binary, version, service, checkbinary=False):
    """Gets the release name derived from source/version from rmadison.

    This is the last stage (as it is slow) and if not found will
    return unknown as the last resort string to use."""
    release = 'unknown'
    LOGGER.debug('Ask madison s: %s b: %s v: %s srv: %s, cb: %s',
                 source, binary, version, service, checkbinary)
    try:
        if binary in BPKG_KNOWN_TO_DIFFER_FROM_SRC or checkbinary:
            cmd = [MADISON_CMD, binary, f'--suite={ESM_RELEASES_C}']
        else:
            cmd = [MADISON_CMD, source, f'--suite={ESM_RELEASES_C}',
                   '--architecture=source']
        LOGGER.debug('Probe %s', cmd)
        rma = subprocess.check_output(cmd,
                                      stderr=subprocess.STDOUT,
                                      encoding='utf-8')
        rma_info = []
        for rma_line in rma.split('\n'):
            rma_elements = rma_line.split('|')
            if len(rma_elements) == 4:
                rma_release = rma_elements[2].strip().removesuffix('/universe')
                for pocket in RELEASE_POCKETS:
                    rma_release = rma_release.removesuffix(pocket)
                # might have epoch prefix not present in pkg file name
                rma_version = re.sub(r'^\d+:', '', rma_elements[1].strip())
                rma_version = Version(rma_version)
                rma_info.append({'release': rma_release,
                                 'v': rma_version})
        LOGGER.debug('Got madison info %s', rma_info)

        # Not in rmadison, not matching a pattern - there is nothing we can do
        if len(rma_info) == 0:
            raise KeyError

        key_version = Version(version)
        sorted_rma_info = sorted(rma_info, key=lambda d: d['v'])
        # If key_version is below the smallest it is pre-trusty => precise
        # This is a special case and no more covered in rmadison
        if key_version < sorted_rma_info[0]['v']:
            return VerToRelCache.cache_release(source, version, 'precise')

        # loop rmadison info and pick the release which is closest
        for release_info in sorted_rma_info:
            if release_info['v'] < key_version:
                release = release_info['release']

    except (subprocess.CalledProcessError, KeyError):
        # Can happen for e.g. ros or some fips which are't in any release
        LOGGER.debug("Rmadison can't find %s", source)
        release = 'unknown'

    if release == 'unknown' and source.startswith('linux-'):
        LOGGER.debug("Fallback to kernel edge cases for %s", source)
        # Fall back to a more complex edge case handling if yet unknown at
        # this point.
        # Try without known special suffixes e.g. linux-tools-5.4.0-1089-aws
        # is in madison while linux-tools-5.4.0-1089-aws-fips is not.
        if binary.endswith(service):
            release = get_release_rmadison(source,
                                           binary.removesuffix(f'-{service}'),
                                           version, service, checkbinary=True)
        # In general kernels are hard to map flag them with an own value
        if release == 'unknown':
            release = 'k-unknown'

    return release


def get_release(source, version, binary, service):
    """Gets the release name derived from source/version.

    This is tricky, there are many special cases - the versioning used
    for ros, cc, cis differs from backports which differs from normal
    versions found in rmadison. Versions can also be superseded or removed."""
    if VerToRelCache.contains(source, version):
        return VerToRelCache.get_release(source, version)

    # Those have precedence before rmadison for most of them being a wrong
    # match if sorting into rmadison version lists
    release = get_release_pattern({'source': source,
                                   'version': version,
                                   'binary': binary})
    if release:
        return VerToRelCache.cache_release(source, version, release)

    return VerToRelCache.cache_release(source, version,
                                       get_release_rmadison(source,
                                                            binary,
                                                            version,
                                                            service))


def pkg_to_data(pkg, datestr, tname):
    """Map the info we got to a per pkg data structure."""
    data = [datestr, tname]
    service = pkg.group(1) if pkg.group(1) else ('infra')
    source = pkg.group(2)
    version = pkg.group(4)
    binary = pkg.group(3)
    # Arch was available when we provided user-configurable fields, but
    # right now isn't used for the regular imports
    # arch = pkg.group(5)
    release = get_release(source, version, binary, service)
    # used to be dynamic, but simplified for automatic execution
    data.append(service)
    data.append(release)
    data.append(source)
    data.append(version)
    data.append(binary)
    return data


def log_to_data(logfile, directory, datestr, tname):
    """Extracts the gzipped log and returns triples per get request."""

    pkgmatch = re.compile(r'/?([\w\-]*)?/ubuntu/pool/main/\w*/'  # 1 service
                          r'([A-Za-z0-9\.\-\+]*)/'               # 2 source
                          r'([a-zA-Z0-9\.\-\+]*)\_'              # 3 binary
                          r'([a-zA-Z0-9~+\-\.]*)\_'              # 4 version
                          r'([a-z0-9]*)\.deb')                   # 5 arch
    mp.current_process().name = f'LOG-{tname}-{os.getpid()}'
    LOGGER.info('Reading logfile %s', logfile)
    VerToRelCache.load_cache()
    with gzip.open(os.path.join(directory, logfile), 'rt',
                   encoding='utf-8') as unzipped_logfile:
        pkglist = []
        linecount = 0
        for line in unzipped_logfile:
            logfields = line.split()
            httpstatus = logfields[7]
            if httpstatus != "200":
                continue
            getcmd = unquote(logfields[5])
            pkg = pkgmatch.match(getcmd)
            if pkg:
                pkgdata = pkg_to_data(pkg, datestr, tname)
                LOGGER.debug('matched %s from %s', pkgdata, line)
                pkglist.append(pkgdata)
            else:
                LOGGER.debug('no match on %s', line)
            linecount += 1
            if linecount % 1000 == 0:
                LOGGER.info('%d lines processed, %d entries so far',
                            linecount, len(pkglist))

        LOGGER.info('Completed logfile %s: found %s entries overall',
                    logfile, len(pkglist))

    VerToRelCache.combine_and_serialize()
    return pkglist


def process_extracted_data(pkg_list, date_csv_file):
    """Generates statistics for the package entries passed."""
    print('Group and count logged package access data')
    pdata = pd.DataFrame(pkg_list, columns=PKG_DATA_COLNAMES)
    sums = pdata.groupby(PKG_DATA_COLNAMES)['Version'].count()

    sums.to_csv(date_csv_file, header=False)
    LOGGER.info('Temporary results written to %s', date_csv_file)
    return len(sums)


def test_release_name_mapping():
    """Test pattern matching to get the release name"""
    testcases = pd.read_csv('testdata.csv')
    for _idx, testcase in testcases.iterrows():
        assert testcase["Release"] == get_release(testcase["Source"],
                                                  testcase["Version"],
                                                  testcase["Binary"],
                                                  testcase["Service"])


def get_last_week():
    """Returns a tuple with last weeks start/end date"""
    today = datetime.now().date()
    start_date = today + timedelta(-today.weekday(), weeks=-1)
    end_date = today + timedelta(-today.weekday() - 1)

    return (start_date, end_date)


def setup_parser():
    '''Set up the argument parser for this program.'''

    epilog = "And all date format are %Y-%m-%d like in 2021-12-31. "
    parser = argparse.ArgumentParser(epilog=epilog)

    (wstart, wend) = get_last_week()
    parser.add_argument(
        "-s", "--date-start",
        default=wstart,
        help="Gather Data for a range starting at this date. "
             f"Default: start of last week ({wstart:%Y-%m-%d})")
    parser.add_argument(
        "-e", "--date-end",
        default=wend,
        help="Gather Data for a range ending at this date. "
             f"Default: end of last week ({wend:%Y-%m-%d})")

    parser.add_argument(
        "--date-format",
        default="%Y-%W",
        help="Identify time ranges by this time format. "
        "This defines how results are grouped. The default of %%Y-%%W groups "
        "per week, using %%Y-%%b would group by month, while %%Y-%%m-%%d "
        "would keep each day individual. (Default: %%Y-%%W = group weeks) "
        "For options see https://docs.python.org/3/library/datetime.html#"
        "strftime-and-strptime-format-codes")

    parser.add_argument(
        "--connectionenv",
        nargs="+",
        help="Env files to consider for swift connections. This can be given "
        "multiple times which will make the tool use each connection "
        "and sum up the results. "
        "(Default: none - use the environment being called with)")

    parser.add_argument('-l',
                        '--loglevel',
                        default='warning',
                        help='Provide logging level. Example '
                             '--loglevel debug, default=warning')

    parser.add_argument(
        "--resultfile",
        required=True,
        help="Write results as CSV to the given file.")

    parser.add_argument(
        "--cachefile",
        default=None,
        help="Read version mapping from file and eventually update that file "
        "with the new mappings. "
        "(Default: none - will neither load nor save the version mapping)")

    parser.add_argument(
        "--lconcurrency",
        type=int,
        default=8,
        help="Number of concurrent processes that will be used to process "
             "logfiles of a group. (Default: 8)")
    parser.add_argument(
        "--gconcurrency",
        type=int,
        default=4,
        help="Number of concurrent processes that iterate on groups (depends "
             "on --date-format in the given time range (Default: 4)")

    parser.add_argument(
        "--downloadstreams",
        type=int,
        default=2,
        help="Number of concurrent swift download streams. "
        "Use this to balance bandwidth to cpu power. "
        "(Default: 2)")

    args = parser.parse_args()

    return args


def get_time_range():
    """Create date range based on the cli arguments passed to us."""
    daterange = []
    startdate = ARGS.date_start
    enddate = ARGS.date_end
    while startdate <= enddate:
        daterange.append(startdate)
        startdate += timedelta(days=1)

    timerange = []
    for idx, startdate in enumerate(daterange):
        new_tname = startdate.strftime(ARGS.date_format)
        if not any(new_tname == itime['name'] for itime in timerange):
            range_end = daterange[-1]
            for enddate in daterange[idx:]:
                end_tname = enddate.strftime(ARGS.date_format)
                if end_tname != new_tname:
                    range_end = enddate - timedelta(days=1)
                    break
            new_time = {'name': new_tname,
                        'start': startdate,
                        'end': range_end}
            timerange.append(new_time)

    LOGGER.info("Time Range: %s", timerange)
    return timerange


def get_and_extract_data(ctime, result_tmpdir):
    """Fetch, extract and store the data for a given date.

    This uses concurrency as well and on this level it helps
    to speed up processing multiple logfiles for a single group."""
    tname = ctime["name"]
    mp.current_process().name = f'GED-{tname}'
    LOGGER.info('New Process handling %s', ctime)
    pdata = []
    with tempfile.TemporaryDirectory(dir=result_tmpdir,
                                     prefix=f'{tname}.') as tmpdir:
        print(f'Getting data for {tname}')
        LOGGER.info('Fetch logs for %s from swift to %s', tname, tmpdir)
        logs = get_logs_per_connection(ctime, tmpdir)

        LOGGER.info('Extracting data from %d access logs for %s',
                    len(logs), tname)

        datestr = ctime["start"].strftime("%Y-%m-%d")
        number_of_logs = len(logs)
        with ccf.ProcessPoolExecutor(ARGS.lconcurrency) as executor:
            workers = [executor.submit(log_to_data, log, tmpdir,
                                       datestr, tname)
                       for log in logs]
            completed_logs = 0
            lines = []
            for work in ccf.as_completed(workers):
                completed_logs += 1
                lines.extend(work.result())
                print(f'Job {completed_logs} '
                      f'({completed_logs/number_of_logs*100:.2f}%) complete '
                      f'- {len(lines)} lines so far')

            pdata.extend(lines)

    date_csv_file = os.path.join(result_tmpdir, f'{tname}.csv')
    processed_entries = process_extracted_data(pdata, date_csv_file)

    print(f'Got {processed_entries} log entries for {tname}')
    return processed_entries


def schedule_data_extraction(tmpdir):
    """Iterate over days and extract summarized data to csv files.

    This maps the processing onto multiple cpus to speed it up.
    Concurrent execution on this level helps if many groups are
    created e.g. running a per-week format across a full year.
    """

    timerange = get_time_range()
    number_of_jobs = len(timerange)
    with ccf.ProcessPoolExecutor(ARGS.gconcurrency) as executor:
        workers = [executor.submit(get_and_extract_data,
                                   single_time, tmpdir)
                   for single_time in timerange]
        completed_jobs = 0
        results = 0
        for work in ccf.as_completed(workers):
            completed_jobs += 1
            results += work.result()
            print(f'Job {completed_jobs} done '
                  f'({completed_jobs/number_of_jobs*100:.2f}% complete) '
                  f'- {results} results so far')


def get_interim_results(tmpdir):
    """Gets a list of the temporary result files in date order."""
    files = sorted(os.listdir(tmpdir),
                   key=lambda x: datetime.strptime(x.replace('.csv', ''),
                                                   ARGS.date_format))
    return [os.path.join(tmpdir, file) for file in files]


def handle_results(tmpdir):
    """Combine the per day interim data into the final report"""
    if ARGS.resultfile:
        mode = 'wb'
        # loading and combining with pandas is rather memory intense, but we
        # need no logic at all, so this is much cheaper and faster
        print(f'Combine final results into {ARGS.resultfile}')
        with open(ARGS.resultfile, mode) as combined:
            header = ",".join(PKG_RESULT_LABELS) + '\n'
            combined.write(header.encode('utf-8'))
            for csv_name in get_interim_results(tmpdir):
                LOGGER.info('adding %s', csv_name)
                with open(csv_name, 'rb') as csv_fd:
                    copyfileobj(csv_fd, combined)
        LOGGER.info('Writing results to local file completed')


def main():
    """Iterate over days, extract data and eventually combine into a report."""
    with tempfile.TemporaryDirectory(prefix="logfiles.", dir=".") as tmpd:
        LOGGER.info('Storing temporary results in %s', tmpd)
        schedule_data_extraction(tmpd)
        handle_results(tmpd)


if __name__ == '__main__':
    # setting up the few gobals we have to then call main
    ARGS = setup_parser()

    PKG_DATA_COLNAMES = ["Date", "TName"] + PKG_DATA_FIELDS
    PKG_RESULT_LABELS = PKG_DATA_COLNAMES + ["AccessCount"]

    logging.getLogger("requests").setLevel(logging.CRITICAL)
    logging.getLogger("swiftclient").setLevel(logging.CRITICAL)
    logging.basicConfig(level=ARGS.loglevel.upper(),
                        format='[(%(asctime)s.%(msecs)03d '
                               '%levelname)s/%(processName)s] '
                               '%(message)s',
                        datefmt='%H:%M:%S')
    LOGGER = mp.log_to_stderr(level=ARGS.loglevel.upper())

    VerToRelCache.set_cache_file(ARGS.cachefile)

    # Too many concurrent swift transfers throttle each other
    SWIFT_SEMA = mp.Semaphore(ARGS.downloadstreams)

    main()
