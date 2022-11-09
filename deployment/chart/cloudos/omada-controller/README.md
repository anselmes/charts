# omada-controller

Omada is a SDN tool for TP-Link Omada hardware

## Requirements

Kubernetes: `>=1.16.0-0`

## Installing the Chart

To install the chart with the release name `omada-controller`

```console
helm repo add pkg-helm-local https://anselmes.jfrog.io/artifactory/api/helm/pkg-helm-local
helm repo update
helm install omada-controller pkg-helm-local/omada-controller
```

## Uninstall

To uninstall the `omada-controller` deployment

```console
helm uninstall omada-controller
```

## Configuration

### Helm

#### Available Settings

Read through the values.yaml file. It has several commented out suggested values.
Other values may be used from the [values.yaml]() from the [common library]().

#### Configure using the command line

Specify each parameter using the `--set key=value[,key=value]` argument to `helm install`.

```console
helm install omada-controller \
  --set env.TZ="America/New York" \
    pkg-helm-local/omada-controller
```

#### Configure using a yaml file

Alternatively, a YAML file that specifies the values for the above parameters can be provided while installing the chart.

```console
helm install omada-controller pkg-helm-local/omada-controller -f values.yaml
```
