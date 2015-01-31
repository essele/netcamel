#!/bin/sh

TARGET="$1"

echo "TARGET TARGET TARGET: ${TARGET}"

#
# Prepare iproute2 tables
#

if [ \! -h "${TARGET}/etc/iproute2" ]; then
	rm -r ${TARGET}/etc/iproute2
	ln -s /tmp/iproute2 ${TARGET}/etc/iproute2
fi

