#!/bin/bash

set -ex

function check_boot_images {
	if maas local boot-resources is-importing | grep -q 'true'; then
		echo -e '\nBoot resources currently importing\n'
		return 1
	else
		synced_imgs=$(maas local boot-resources read | tr -d '\n' | grep -oE '{[^}]+}' | grep ubuntu | grep -c Synced)
		if [[ $synced_imgs -gt 0 ]]; then
			echo 'Boot resources have completed importing'
			return 0
		else
			return 1
		fi
	fi
}

function check_rack_controllers {
	rack_cnt=$(maas local rack-controllers read | grep -c hostname)
	if [[ $rack_cnt -gt 0 ]]; then
		echo "Found $rack_cnt rack controllers."
		return 0
	else
		return 1
	fi
}

function check_admin_api {
	if maas local version read; then
		echo 'Admin API is responding'
		return 0
	else
		return 1
	fi
}

function establish_session {
	{{- if .Values.conf.maas.tls.enabled }}
	maas login --cacerts /usr/local/share/ca-certificates/maas-ca.crt local ${MAAS_URL} ${MAAS_API_KEY}
	{{- else }}
	maas login local ${MAAS_URL} ${MAAS_API_KEY}
	{{- end }}
	return $?
}

establish_session

if [[ $? -ne 0 ]]; then
	echo "MAAS API login FAILED!"
	exit 1
fi

check_boot_images

if [[ $? -eq 1 ]]; then
	echo "Image import test FAILED!"
	exit 1
fi

check_rack_controllers

if [[ $? -eq 1 ]]; then
	echo "Rack controller query FAILED!"
	exit 1
fi

check_admin_api

if [[ $? -eq 1 ]]; then
	echo "Admin API response FAILED!"
	exit 1
fi

echo "MAAS Validation SUCCESS!"
exit 0
