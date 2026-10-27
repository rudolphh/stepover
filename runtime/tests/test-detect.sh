#!/bin/bash
# latest-crossover.sh and addon-versions.sh, against saved copies of CodeWeavers' page and Wine's addons.c.

assert_eq "26.10.0" "$(runtime/latest-crossover.sh runtime/tests/fixtures/codeweavers-source.html)" "newest stable wins (Review Focus 1)"
assert_eq $'MONO_VERSION=10.4.1\nGECKO_VERSION=2.47.4' "$(runtime/addon-versions.sh runtime/tests/fixtures)" "addon versions"
assert_eq "1" "$(runtime/latest-crossover.sh /dev/null >/dev/null 2>&1; echo $?)" "nothing found"
assert_eq "no CrossOver source found" "$(runtime/latest-crossover.sh /dev/null 2>&1)" "nothing found message"
assert_eq "1" "$(runtime/addon-versions.sh /nonexistent >/dev/null 2>&1; echo $?)" "missing addons.c"
