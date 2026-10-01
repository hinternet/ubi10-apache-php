# OpenShift example manifests

Restricted-v2 compatible examples for the Drupal 11 runtime base.

| File | Resource |
|---|---|
| `kustomization.yaml` | Apply the directory (`oc apply -k examples/openshift`) |
| `deployment.yaml` | Deployment, port 8080, exec probes, RO rootfs, resources, optional ConfigMap |
| `service.yaml` | Service `8080` → container `http` |
| `route.yaml` | Route, **edge** TLS to 8080 (HTTP in the pod) |
| `configmap.yaml` | Optional `/etc/drupal/php.d/zz-openshift.ini` (`max_input_vars = 10000`) |
| `networkpolicy.yaml` | Ingress 8080, egress allow-all (tighten later) |
| `pdb.yaml` | `maxUnavailable: 1` (does not block drains at replicas: 1) |
| `overlays/with-pvc/` | PVCs for public/private files |

After `make build test` and `make push`:

```bash
# Point images.newName at Docker Hub or the integrated registry:
#   docker.io/<hub-user>/ubi10-apache-php
#   image-registry.openshift-image-registry.svc:5000/<project>/ubi10-apache-php
oc apply -k examples/openshift
```

First smoke uses **emptyDir** for files. For a real Drupal site:

```bash
# Set storageClassName on overlays/with-pvc/pvc.yaml, then:
oc apply -k examples/openshift/overlays/with-pvc
```

Do **not** add `runAsUser` or `fsGroup: 0`. Do **not** add port 8443.
Do **not** deploy `:latest` with `imagePullPolicy: IfNotPresent`.

File sessions on emptyDir will not survive reschedule or scale-out. Use Redis
or Memcached from the app (`settings.php`) before `replicas > 1`.

See [docs/openshift.md](../../docs/openshift.md) for probes, mounts, and
`$settings['reverse_proxy']`.
