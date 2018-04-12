#!/bin/sh
set -e
lit make .
rsync --progress kubos-communication-service hamilton:
ssh hamilton -t -C "EXPOSE_PORTS=4040 ./kubos-communication-service nsl-serial /dev/ttyUSB0 38400"
