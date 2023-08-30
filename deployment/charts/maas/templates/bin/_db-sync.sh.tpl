#!/bin/bash

set -ex

rm -f /var/run/rsyslogd.pid
service rsyslog restart

maas-region dbupgrade
