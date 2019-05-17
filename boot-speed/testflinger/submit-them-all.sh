#!/bin/bash

set -eu
shopt -s nullglob

echo

for f in *.full.yaml; do
    echo "# Submitting $f"
    testflinger-cli submit "$f"
    echo
done
