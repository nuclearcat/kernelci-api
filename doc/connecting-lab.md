---
title: "Connecting LAVA Lab to the pipeline instance"
date: 2024-02-19
description: "Connecting a LAVA lab to the KernelCI pipeline"
weight: 2
---

As we are moving towards the new KernelCI API and pipeline, we need to make sure
all the existing LAVA labs are connected to the new pipeline instance.  This
document explains how to do this.

## Token setup

The first step is to generate a token for the lab.  This is done by the lab admin,
and the token is used to submit jobs from pipeline to the lab, and to authenticate
LAVA lab callbacks to the pipeline.
Requirements for the token:
- Description: a string matching the regular expression `[a-zA-Z0-9\-]+`, for example "kernelci-new-api-callback"
- Value: arbitrary, kept secret

## Pipeline configuration

### Secrets (toml) file

The next step is to add the token to the pipeline services configuration files.
Secrets are stored in the `kernelci.secrets` section of the `kernelci.toml` file,
and added manually by the KernelCI system administrators.  For example, the token
can be added to the `runtime.lava-labname` section of the `services.toml` file:

```toml
[runtime.lava-labname]
runtime_token="TOKEN-VALUE"
```

### docker-compose file

You need to add lab name to the scheduler-lava service in the `docker-compose.yml` file.

### yaml pull request

The final step is to submit a pull request to the `kernelci-pipeline` repository
to add the lab configuration to the yaml file.
For example, see the following [pull request](https://github.com/kernelci/kernelci-pipeline/pull/426).

In details the pull request should add a new entry to the `runtimes` section of the configuration file:

```yaml

  lava-broonie:
    lab_type: lava
    url: 'https://lava.sirena.org.uk/'
    priority_min: 10
    priority_max: 40
    notify:
      callback:
        token: kernelci-new-api-callback
        url: https://staging.kernelci.org:9100

```
Where `lava-broonie` is the name of the lab, `lava` is the type of the lab, `url` is the URL of the lab, `priority_min` and `priority_max` are the priority range allowed to jobs, assigned by lab owner, and `notify` is the notification configuration for the lab.  The `callback` section contains the token and the URL of the pipeline instance LAVA callback endpoint.

### Jobs and devices specific to the lab

For testing it is better to add separate job and device type specific to the lab.  For example, the following yaml file adds a job and a device type for the `lava-broonie` lab:

```yaml
jobs:
  baseline-arm64-broonie: *baseline-job

device_types:

  sun50i-h5-libretech-all-h3-cc:
    <<: *arm64-device
    mach: allwinner
    dtb: dtbs/allwinner/sun50i-h5-libretech-all-h3-cc.dtb

scheduler:

  - job: baseline-arm64-broonie
    event:
      channel: node
      name: kbuild-gcc-10-arm64
      result: pass
    runtime:
      type: lava
      name: lava-broonie
    platforms:
      - sun50i-h5-libretech-all-h3-cc
```

## Conclusion

This document explains how to connect a LAVA lab to the KernelCI pipeline.  The
process involves generating a token for the lab, adding the token to the pipeline
configuration, modifying docker-compose configuration,
and submitting a pull request to the `kernelci-pipeline` repository
to add the lab configuration to the yaml file.  It also explains how to add jobs
and device types specific to the lab for testing purposes.



