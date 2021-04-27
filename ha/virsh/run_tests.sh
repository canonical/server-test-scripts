#!/bin/bash

./delete-cluster.sh || exit 1
./setup-cluster.sh

test_failed=0
for file in tests/*_test.sh; do
  if ! bash "$file"; then
    test_failed=1
  fi
done

./delete-cluster.sh

if [ $test_failed -eq 1 ]; then
  exit 3
fi
