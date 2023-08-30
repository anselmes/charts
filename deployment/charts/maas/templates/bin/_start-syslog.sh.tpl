#!/bin/bash

set -x

RSYSLOG_BIN=${RSYSLOG_BIN:-"/usr/sbin/rsyslogd"}
RSYSLOG_CONFFILE=${RSYSLOG_CONFFILE:-"/etc/rsyslog.conf"}
LOGFILE=${LOGFILE:-"/var/log/maas/nodeboot.log"}

if [ ! -f "$LOGFILE" ]; then
  touch "$LOGFILE"
fi

$RSYSLOG_BIN -f "$RSYSLOG_CONFFILE"

# Handle race waiting for rsyslogd to start logging
while true
do
  tail -f "$LOGFILE"
  echo "Waiting for log file to exist."
  sleep 10
done
