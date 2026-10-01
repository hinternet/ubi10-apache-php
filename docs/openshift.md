# OpenShift deploy

Example YAML: [`../examples/openshift/`](../examples/openshift/). Live cluster
apply is not required to use this image; the examples match `restricted-v2`.

## SCC

Use **restricted-v2** (or a stricter profile).

- **Do not** set `runAsUser` (OpenShift assigns the UID).
- **Do not** set `fsGroup: 0`.
- Drop `ALL` capabilities, `allowPrivilegeEscalation: false`,
  `runAsNonRoot: true`, `seccompProfile.type: RuntimeDefault`.
- `readOnlyRootFilesystem: true` is supported when the mounts below are present.

## Ports and Route

The pod listens on **8080/http** only. Service port 8080. Route TLS
**edge** (or reencrypt **to 8080** — the pod still speaks HTTP). There is no
8443 and no TLS in Apache.

## Probes

Always **exec** the image healthcheck (FPM ping via loopback):

```yaml
startupProbe:
  exec:
    command: ["/opt/drupal/scripts/healthcheck.sh"]
  periodSeconds: 2
  timeoutSeconds: 5
  failureThreshold: 30
livenessProbe:
  exec:
    command: ["/opt/drupal/scripts/healthcheck.sh"]
  periodSeconds: 30
  timeoutSeconds: 5
  failureThreshold: 3
readinessProbe:
  exec:
    command: ["/opt/drupal/scripts/healthcheck.sh"]
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
```

`timeoutSeconds` must be **≥ 5**. The Docker `HEALTHCHECK` is the same script
(`--timeout=5s`) against `http://127.0.0.1:8080/healthz`; body must be `pong`.

Do not probe `/healthz` through the public Route: after RemoteIP a public
client is denied. httpGet from the kubelet may work on RFC1918 node IPs; exec
is the supported path. Link-local (`169.254.0.0/16`) is **not** in the healthz
allow list.

## Writable paths

Entrypoint creates these if the parent is writable. On a read-only root they
must be mounts:

| Mount | Typical volume | Required to start |
|---|---|---|
| `/tmp` | emptyDir or tmpfs | yes (sessions, nss_wrapper, PHP temp) |
| `/run/httpd` | emptyDir or tmpfs | yes (pid/mutex/scoreboard) |
| `/run/php-fpm` | emptyDir or tmpfs | yes (pid + unix socket) |
| `/var/www/html/web/sites/default/files` | emptyDir or PVC | Drupal public files |
| `/var/www/html/files-private` | emptyDir or PVC | Drupal private files |

Mode on image dirs is `g=u` (not `0777`).

## ConfigMaps

Optional drop-ins (same paths as [extending.md](extending.md)):

- `/etc/drupal/php.d/zz-*.ini`
- `/opt/httpd/conf.d/*.conf`

See `examples/openshift/configmap.yaml`. The Deployment mounts it
`optional: true`, so a first apply works without the ConfigMap.

## Resources

The example requests 512Mi / 250m and limits 2Gi / 2 CPU. FPM
`pm.max_children = 10` plus opcache 256M and APCu 128M need that headroom.
Tune `zz-*.ini` and the FPM pool together with the limit.

## NetworkPolicy, PDB, service account

Examples include a NetworkPolicy (ingress TCP 8080, egress allow-all) and a
PodDisruptionBudget (`maxUnavailable: 1`). The pod sets
`automountServiceAccountToken: false`.

## Sessions and replicas

The example uses `replicas: 1` and file sessions (`/tmp/php-sessions` on
emptyDir `/tmp`). Scale-out or a reschedule drops sessions. Point Drupal at
Redis or Memcached in `settings.php` before raising replicas. Redis/Memcached
PHP extensions are loaded in the image with **no default host**.

## Apply

```bash
oc apply -k examples/openshift
```

Set `images.newName` in `examples/openshift/kustomization.yaml` to the tag you
pushed. For persistent public/private files:

```bash
oc apply -k examples/openshift/overlays/with-pvc
```

Set `storageClassName` on the PVCs first.

## Drupal settings

Required in the application (not in the base image):

```php
$settings['reverse_proxy'] = TRUE;
$settings['reverse_proxy_addresses'] = [
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
  '127.0.0.0/8',
];
$settings['trusted_host_patterns'] = [
  '^example\.apps\.example\.com$',
];
```

Replace CIDRs/host with the cluster’s pod/service networks and Route name.
Apache already sets `HTTPS=on` from `X-Forwarded-Proto`.

## Image

Build locally (`make build test`), then `make push` to Docker Hub
(`docker.io/<hub-user>/ubi10-apache-php:1.0.0` — see the root README). Set
`images.newName` in `examples/openshift/kustomization.yaml` to that repository
(or `oc set image`). Prefer the version tag (`:1.0.0`) or a digest. Do not
deploy `:latest` with `imagePullPolicy: IfNotPresent`.

Record `make versions` (`rpm -qa`) next to a release tag if you need to know
which Remi NVRs were in that build. Module packages are not pinned at NVR
(php:remi-8.4 floats patch releases).
