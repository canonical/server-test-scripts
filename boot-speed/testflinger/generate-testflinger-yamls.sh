#!/bin/bash

set -eu
shopt -s nullglob

yaml_tail="test_data.yaml"

for f in *.provision.yaml; do
    basename=$(echo "$f" | cut -d. -f1)
    outf="$basename.full.yaml"
    echo Generating $outf
    cat "$f" "$yaml_tail" > "$outf"
done
