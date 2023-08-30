#!/bin/bash

set -ex

maas-region apikey --username=${ADMIN_USERNAME} || exit 1
