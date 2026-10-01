# ubi10-apache-php documentation

Drupal 11 runtime base: UBI 10, Apache 2.4 (`mpm_event`), PHP-FPM 8.4, unix
socket, OpenShift `restricted-v2`.

| Doc | Contents |
|---|---|
| [architecture.md](architecture.md) | Layers, PID 1, baked config, paths |
| [openshift.md](openshift.md) | SCC, probes, mounts, Route, reverse_proxy |
| [env.md](env.md) | Environment variables and defaults |
| [extending.md](extending.md) | Downstream `FROM`, Composer, drop-ins |
| [security.md](security.md) | UID/GID, files PHP, healthz, PID 1 caveat |

Example YAML: [`../examples/openshift/`](../examples/openshift/).

Build and test locally with `make lint`, `make build`, and `make test`
(see the root README). CI runs the same targets (`.github/workflows/ci.yml`).
