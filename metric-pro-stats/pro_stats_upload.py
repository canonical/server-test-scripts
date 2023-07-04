#!/usr/bin/python3
# -*- coding: utf-8 -*-
# Copyright © 2022 Christian Ehrhardt <christian.ehrhardt@canonical.com>
# License:
# GPLv2 (or later), see /usr/share/common-licenses/GPL
"""Derive some stats from anonymyzed ESM access logs to better serve more users

This will read stats from CSV and upload to Google spreadsheets

This needs Google API, Google Drive API and Google Sheet API enabled.
See https://docs.gspread.org/en/latest/oauth2.html#for-end-users-using-oauth-client-id
"""

# Requirements (Ubuntu Packages):
# - python3-pandas
# PIP only code
# - gspread

import argparse
import logging

import gspread
import pandas as pd

# basic fallback
LOGGER = logging.getLogger(__name__)
CONTAINER = "production"


def setup_parser():
    '''Set up the argument parser for this program.'''

    parser = argparse.ArgumentParser()

    parser.add_argument('-l',
                        '--loglevel',
                        default='warning',
                        help='Provide logging level. Example '
                             '--loglevel debug, default=warning')

    parser.add_argument(
        "--csvfile",
        nargs="+",
        help="Read results from this CSV file (can be given multiple times).")

    parser.add_argument(
        "--resultsheet",
        help="Write results to this google spreadsheet using gspread.")

    parser.add_argument(
        "--authfile",
        help="Use this file for authentication to google services. "
        "This needs Google API, Google Drive API and Google Sheet API enabled."
        " See https://docs.gspread.org/en/latest/oauth2.html#for-end-users-"
        "using-oauth-client-id ")

    parser.add_argument(
        "--append",
        default=False,
        action='store_true',
        help="Append results to the existing file or sheet"
             " (otherwise the sheet will be replaced).")

    args = parser.parse_args()

    return args


# TODO - make this centrally defined
PKG_RESULT_LABELS = ['Date',
                     'TName',
                     'Service',
                     'Release',
                     'Source',
                     'Version',
                     'Binary',
                     'AccessCount']


def main():
    """Read CVS and write/append to Spreadsheet."""
    google_account = gspread.service_account(filename=ARGS.authfile)
    spreadsheet = google_account.open(ARGS.resultsheet)
    worksheet = spreadsheet.sheet1
    end_col_char = chr(ord('A')+len(PKG_RESULT_LABELS)-1)

    if not ARGS.append:
        LOGGER.info("Clear Sheet and set header")
        worksheet.clear()
        worksheet.resize(rows=1, cols=len(PKG_RESULT_LABELS))
        worksheet.update(f'A1:{end_col_char}1', [PKG_RESULT_LABELS])

    LOGGER.info("Push to Google spreadsheet '%s'", ARGS.resultsheet)
    for csv_name in ARGS.csvfile:
        LOGGER.info("Add data of %s", csv_name)
        entries = pd.read_csv(csv_name)
        entries = entries.values.tolist()
        # Default cell format is "auto" which works fine for our date and
        # we need it to not just be text. Set the rest (all but col A) to
        # text to avoid accidential conversions.
        #
        # Sheets can not format a column, only existing cells
        # So we need to add empty rows, format them as needed
        # and then update with the content to get formatting
        # to types like date in column 1 (instead of just using
        # append_rows.
        #
        # Due to https://github.com/burnash/gspread/issues/545 we can
        # not use the simple worksheet.row_count as properties won't
        # update after initially being set.
        new_range_start_row = google_account.open(ARGS.resultsheet).sheet1.row_count + 1
        worksheet.append_rows([['']]*len(entries))
        worksheet.format(f'B{new_range_start_row}:{end_col_char}',
                         {"numberFormat": {"type": "TEXT"}})
        worksheet.update(f'A{new_range_start_row}:{end_col_char}',
                         entries,
                         value_input_option="USER_ENTERED")
        LOGGER.info("Data Pushed")
    LOGGER.info("Push to Google spreadsheet done for all CSV File(s)")


if __name__ == '__main__':
    # setting up the few gobals we have to then call main
    ARGS = setup_parser()

    logging.getLogger("requests").setLevel(logging.CRITICAL)
    logging.basicConfig(level=ARGS.loglevel.upper(),
                        format='[(%(asctime)s.%(msecs)03d '
                               '%levelname)s/%(processName)s] '
                               '%(message)s',
                        datefmt='%H:%M:%S')

    main()
