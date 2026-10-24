# Grievance service on Kubernetes

The OAN Grievance Service (`oan_grievance_service`, with `oan_auth_service` in the same
bench) is a Frappe app. This guide installs it in dev, and the same way on your own
machine. The steps are the same in both places, and so are the values files:
`environments/dev/values/`. Only the clusters, the certificate and how the hostname
resolves differ.

Read section 1 once, then follow section 2 (dev) or section 3 (local).

## 1. How it fits together

One central APISIX gateway serves every OAN app. It runs in its own cluster, and each
app runs in a cluster of its own (grievance today, A2C later):

```
client -> DNS (dev) or /etc/hosts (local): grievance-backend-dev.oanstaging.com -> gateway node
       -> gateway cluster: APISIX, ports 80/443 (hostPort)   TLS, routes, CORS, rate limits
            picks the app by Host; rate-limit counters in Valkey next to it
       -> grievance cluster: node ports 30800 (gunicorn) and 30900 (socket.io), private network
       -> Frappe Pods, MariaDB, Valkey, ClamAV
```

There is no nginx anywhere on this path. APISIX terminates TLS and proxies straight to
gunicorn and socket.io. The routes cannot name a Service in another cluster, so the
gateway chart sets `web.externalHost` and `socket.externalHost` to the grievance node's
private address, and the grievance chart opens node ports for them (`gatewayAccess`).
The hop between the clusters is plain HTTP: it must stay on a private network, and the
node ports must accept only the gateway cluster's addresses.

| Cluster | Release | Chart | Namespace | Values |
| --- | --- | --- | --- | --- |
| both | `local-path-shared` | `rancher/local-path-provisioner` v0.0.37 (from a Git checkout) | `local-path-shared` | [local-path-shared.yaml](../environments/dev/values/local-path-shared.yaml) |
| gateway | `apisix` | `apisix/apisix` 2.18.2 | `apisix` | [apisix.yaml](../environments/dev/values/apisix.yaml) |
| gateway | `apisix-valkey` | `valkey/valkey` 0.11.0 | `apisix` | [valkey-gateway.yaml](../environments/dev/values/valkey-gateway.yaml) |
| grievance | `grievance` | [charts/oan-grievance-service](../charts/oan-grievance-service) | `develop` | [oan-grievance-service.yaml](../environments/dev/values/oan-grievance-service.yaml) |
| gateway | `oan-grievance-gateway` | `apisix/k8s` in the oan_grievance_service repository | `grievance` | [oan-grievance-gateway.yaml](../environments/dev/values/oan-grievance-gateway.yaml) |

Install them in that order: storage, gateway, app, routes. A2C adds its own app cluster
and one more release in the gateway cluster, `oan-a2c-gateway` in namespace `a2c`; see
[apisix-gateway.md](apisix-gateway.md), section 8.

### Storage

Every Frappe Pod mounts the sites volume, so it must be ReadWriteMany (RWX). The
`local-path-shared` StorageClass provides RWX on a single node: each volume is a
directory under `/opt/local-path-shared` on the node. MariaDB, and etcd in the gateway
cluster, use the same class. Its reclaim policy is `Retain`, so deleting a release or namespace keeps the
data; delete the PersistentVolumes yourself to remove it. Before the cluster gets a
second node, move to a real shared filesystem (NFS or EFS).

### What the grievance chart adds to the upstream Frappe chart

The chart depends on the upstream `frappe/helm` chart `erpnext` 8.0.89, aliased
`frappe`. Upstream provides gunicorn, socket.io, the scheduler, the default, short and
long workers, MariaDB (`mariadb-sts`), Valkey cache and queue, and the create-site job.
Its values sit under the `frappe:` key. The chart adds what upstream cannot do:

- **Grievance queue workers.** Upstream workers listen only on `default`, `short` and
  `long`. `queueWorkers` adds one Deployment each for `grievance_routing`,
  `grievance_sla`, `grievance_scan` and `grievance_notifications`.
- **ClamAV** for attachment scanning, as a Deployment and Service.
- **The site-config job.** It runs on every install and upgrade. It waits until
  `oan_grievance_service` is installed on the site, then:
  1. copies the JWT key from its Secret to `sites/<site>/keys/jwt_v1.pem`, because
     upstream Pods cannot mount extra volumes
  2. writes `siteConfig` and the ClamAV address into `site_config.json`
  3. writes the `workers` queue declaration into `common_site_config.json`
     (`frappe.enqueue` rejects undeclared queues)
  4. runs `bench migrate`

Upstream details that shaped the chart:

- Upstream jobs are not Helm hooks. Each upgrade creates new ones, with a timestamp in
  the name, and they all start at once. Upstream's migrate job fails on a first install
  because the site does not exist yet, so it stays disabled and the site-config job
  migrates instead. The create-site job treats "already exists" as success.
- Upstream reads the MariaDB root password only from the plain value
  `frappe.mariadb-sts.rootPassword`. It is passed at install with `--set-string`, from
  the Secret, never written in a file.
- The site name is set twice, as `siteName` and `frappe.jobs.createSite.siteName`,
  because a subchart cannot read its parent's values. A mismatch stops the render.
- Upstream always renders an nginx Deployment. Its replicas are 0, so nothing runs.
- Resource names come from the alias. Release `grievance` gives the Services
  `grievance-frappe-gunicorn` and `grievance-frappe-socketio`. The gateway values reuse
  these names for their ApisixUpstreams.
- Upstream Services are ClusterIP only, with no fixed node port. `gatewayAccess` adds
  `grievance-gateway-web` (node port 30800) and `grievance-gateway-socket` (30900), which
  select the same Pods.

### Buffering

A slow client cannot hold a gunicorn worker for a whole transfer. APISIX's proxy
location keeps the nginx defaults `proxy_buffering on` and `proxy_request_buffering on`.
Only its `@disable_proxy_buffering` location, used by streaming plugins, turns them
off. Large responses spill to a temp file and still free the worker. Request bodies, up
to each route's 15 MB `client-control` limit, are read in full before gunicorn sees
them. Do not turn buffering off on a grievance route unless it streams.

### Client address and rate limits

Clients connect to APISIX directly, so `$remote_addr` is the client, and no
`X-Real-IP` header is trusted (a client cannot fake one to escape a limit). This needs
the gateway node to keep the source address of hostPort traffic. On OrbStack it does
not: every request shows the Pod gateway address, so all local clients share one
rate-limit bucket. Confirm on dev in section 2, step 10.

The counters live in the gateway cluster's own Valkey (`apisix-valkey`), so a limit
check never crosses clusters. Frappe sees the gateway node as the client; APISIX passes
the client in `X-Forwarded-For`.

### Logs and errors

- Every Frappe container sets `FRAPPE_STREAM_LOGGING=1`, so `frappe.logger()` writes to
  stdout for the cluster log collector, not to files. Outside the dev server Frappe
  logs only `ERROR` and above.
- Sentry turns on when the Secret `oan-grievance-sentry` (key `dsn`) exists. Errors
  recorded with `frappe.log_error`, which includes every 5xx in the API wrapper, reach
  Sentry from web and worker Pods.
- Frappe attaches the request body to Sentry events. On the self-hosted Sentry project,
  add a server-side scrubbing rule that removes `contexts."JSON Body"` and
  `contexts."Form Data"` before you create the Secret. Otherwise passwords, OTPs,
  mobile numbers and grievance text can be stored with an error.

### Secrets

Created by hand in the release namespace, never in values files. Keep a copy of each
dev value in the team's secret manager.

| Secret | Cluster | Namespace | Keys | Used for |
| --- | --- | --- | --- | --- |
| `apisix-admin-credentials` | gateway | `apisix` | `admin`, `viewer` | APISIX Admin API keys |
| `oan-grievance-tls` | gateway | `grievance` | `tls.crt`, `tls.key` | Certificate APISIX serves for the host |
| `oan-grievance-db` | grievance | `develop` | `password` | MariaDB root password |
| `oan-grievance-admin` | grievance | `develop` | `password` | Frappe `Administrator` password |
| `oan-grievance-jwt` | grievance | `develop` | `jwt_v1.pem` | RS256 signing key for `oan_auth_service` |
| `oan-grievance-sentry` | grievance | `develop` | `dsn` | Optional: Sentry DSN |

Frappe also generates an `encryption_key` when it creates the site. It is stored in
`sites/develop.grievance.test/site_config.json` on the sites volume. Back it up with the
database: without it, encrypted fields cannot be read.

## 2. Dev

Dev is built fresh with these steps. Nothing from the earlier hand-made setup (the
`backend` Deployment and its database) is kept or migrated.

Run these from a machine with `kubectl` and `helm` 3.x, in a checkout of this
repository, with a checkout of `oan_grievance_service` at the deployed commit. You need
a kubeconfig context for each cluster; below they are `gateway` and `grievance`. Check
the context before every step.

Collect first:

| Fact | Used in |
| --- | --- |
| Gateway node public IP (DNS for every app host points here) | steps 5, 10 |
| Gateway cluster's address as the grievance node sees it (its private IP or NAT address) | step 8 |
| Grievance node private IP, reachable from the gateway cluster | step 9 |

The two clusters must share a private network (one VPC, or peering). Without one, the
hop between them crosses the internet in plain HTTP: add a VPN or TLS before going on.

**Gateway cluster**

1. **Point at the gateway cluster.**

   ```sh
   kubectl config use-context gateway
   kubectl get nodes -o wide         # the gateway node, never OpenG2P or grievance
   ```

2. **Turn off RKE2's ingress-nginx.** APISIX binds the node's ports 80 and 443, and
   RKE2 starts `rke2-ingress-nginx` on them by default. On the node, add this to
   `/etc/rancher/rke2/config.yaml`, then run `systemctl restart rke2-server`:

   ```yaml
   disable:
     - rke2-ingress-nginx
   ```

   Check that nothing holds the ports any more:

   ```sh
   kubectl get pods -A -o wide | grep -i -E 'ingress|nginx|traefik'   # no output
   ```

3. **Install the storage class** (etcd keeps the gateway's configuration on it).

   ```sh
   git clone --depth 1 --branch v0.0.37 https://github.com/rancher/local-path-provisioner /tmp/lpp
   helm upgrade --install local-path-shared /tmp/lpp/deploy/chart/local-path-provisioner \
     -n local-path-shared --create-namespace \
     -f environments/dev/values/local-path-shared.yaml --wait
   kubectl get sc local-path-shared
   ```

4. **Create the Secret.**

   ```sh
   kubectl create namespace apisix
   kubectl -n apisix create secret generic apisix-admin-credentials \
     --from-literal=admin="$(openssl rand -hex 16)" --from-literal=viewer="$(openssl rand -hex 16)"
   ```

5. **Install APISIX and its Valkey.**

   ```sh
   helm repo add apisix https://apache.github.io/apisix-helm-chart && helm repo update apisix
   helm repo add valkey https://valkey.io/valkey-helm/ && helm repo update valkey
   helm upgrade --install apisix apisix/apisix --version 2.18.2 -n apisix \
     -f environments/dev/values/apisix.yaml --wait --timeout 10m
   helm upgrade --install apisix-valkey valkey/valkey --version 0.11.0 -n apisix \
     -f environments/dev/values/valkey-gateway.yaml --wait
   curl -s -o /dev/null -w '%{http_code}\n' http://<gateway node public IP>/   # 404 from APISIX: no routes yet
   ```

   If the APISIX Pod stays `Pending`, something still holds port 80 or 443 (step 2).

**Grievance cluster**

6. **Point at the grievance cluster, and install the storage class** (step 3 again).

   ```sh
   kubectl config use-context grievance
   kubectl get nodes -o wide         # expect 13.233.56.204
   ```

7. **Create the Secrets.**

   ```sh
   kubectl create namespace develop
   kubectl -n develop create secret generic oan-grievance-db --from-literal=password="$(openssl rand -hex 16)"
   kubectl -n develop create secret generic oan-grievance-admin --from-literal=password="$(openssl rand -hex 12)"
   openssl genrsa -out jwt_v1.pem 2048
   kubectl -n develop create secret generic oan-grievance-jwt --from-file=jwt_v1.pem=jwt_v1.pem
   rm jwt_v1.pem
   ```

   Save each value in the secret manager before you delete the local copy.

8. **Install the grievance service.** The image tag is the one Jenkins pushed.

   ```sh
   helm dependency build charts/oan-grievance-service
   helm upgrade --install grievance charts/oan-grievance-service -n develop \
     -f environments/dev/values/oan-grievance-service.yaml \
     --set-string frappe.image.tag=<develop-build-sha> \
     --set-string "frappe.mariadb-sts.rootPassword=$(kubectl -n develop get secret oan-grievance-db -o jsonpath='{.data.password}' | base64 -d)" \
     --wait --wait-for-jobs --timeout 20m
   kubectl -n develop get pods
   kubectl -n develop get svc grievance-gateway-web grievance-gateway-socket   # NodePort 30800, 30900
   kubectl -n develop logs job/$(kubectl -n develop get jobs -o name | grep site-config | tail -1 | cut -d/ -f2)
   ```

   The upstream workers and socket.io restart a few times on a first install while the
   site is created. That is expected.

   In the grievance node's security group, allow TCP 30800 and 30900 from the gateway
   cluster's address only. Never from `0.0.0.0/0`: these ports skip TLS, rate limits
   and CORS. Check from the gateway node:

   ```sh
   curl -s -H 'Host: develop.grievance.test' http://<grievance private IP>:30800/api/v1/grievances/health
   ```

**Gateway cluster**

9. **Install the certificate and the routes.**

   ```sh
   kubectl config use-context gateway
   kubectl create namespace grievance
   ```

   Get a certificate for `grievance-backend-dev.oanstaging.com` into Secret
   `oan-grievance-tls` in `grievance`. With cert-manager (check:
   `kubectl get crd certificates.cert-manager.io`), an HTTP-01 `Certificate` whose solver
   uses ingress class `apisix` works, because APISIX answers on port 80. Without
   cert-manager, create it from existing files:
   `kubectl -n grievance create secret tls oan-grievance-tls --cert=fullchain.pem --key=privkey.pem`.
   Then:

   ```sh
   helm upgrade --install oan-grievance-gateway <oan_grievance_service>/apisix/k8s -n grievance \
     -f environments/dev/values/oan-grievance-gateway.yaml \
     --set-string web.externalHost=<grievance private IP> \
     --set-string socket.externalHost=<grievance private IP> --wait
   kubectl -n grievance get apisixtls,apisixroute,apisixupstream
   ```

   Point DNS for `grievance-backend-dev.oanstaging.com` at the gateway node's public IP.

10. **Check.**

    ```sh
    H=https://grievance-backend-dev.oanstaging.com
    curl -si $H/v1/grievances/health | head -12        # 200, X-Request-Id header
    curl -si $H/v1/does-not-exist | head -3            # 404 from APISIX
    curl -s $H/v1/auth/keys | head -c 200              # kid v1: the JWT key loaded
    kubectl -n apisix logs deploy/apisix -c apisix --tail=3   # first field: your public IP, not 10.42.x
    kubectl -n apisix exec deploy/apisix-valkey -- valkey-cli --scan | head -3   # plugin-limit-count:... keys
    ```

    If the access log shows a `10.42.x` address, the node rewrites the source address
    of hostPort traffic, and everyone shares one rate-limit bucket. Fix that before
    leaving the host open. More checks (CORS, rate limits, metrics) are in
    [apisix-gateway.md](apisix-gateway.md), section 5.

Jenkins: its deploy stage still runs `kubectl set image` and `bench migrate`. Replace both
with step 8's `helm upgrade` against the grievance cluster, passing the new tag.
`--wait-for-jobs` makes a failed site-config job, and so a failed migrate, fail the
pipeline. Jenkins then needs a kubeconfig credential; it already has the ECR one. Route
changes (step 9) go to the gateway cluster, so Jenkins needs that kubeconfig too.

## 3. Local

The same releases and values files on one local cluster, which plays both the gateway
cluster and the grievance cluster. The routes still leave through the grievance node
ports, at the node's own address, so the path between the two clusters is exercised as
in dev. A certificate from a local CA and `/etc/hosts` replace DNS. Tested on OrbStack.
It needs about 8 GB of memory for the cluster, of which ClamAV takes 1.5 GB.

1. **Select the local cluster.** Every command below must go to it, never to dev.

   ```sh
   kubectl config use-context orbstack
   kubectl get nodes -o wide          # note the node's INTERNAL-IP, e.g. 192.168.139.2
   ```

2. **Build the image under the ECR name.** The values name
   `379220350808.dkr.ecr.ap-south-1.amazonaws.com/oan-frappe`. With `pullPolicy:
   IfNotPresent` the cluster uses a local image with that name and never contacts ECR.
   Build it the way the Jenkinsfile does, from an `apps.json` that pins both apps to a
   branch:

   ```json
   [
     {"url": "https://github.com/Centre-for-Open-Societal-Systems/oan_auth_service", "branch": "develop"},
     {"url": "https://github.com/Centre-for-Open-Societal-Systems/oan_grievance_service", "branch": "develop"}
   ]
   ```

   ```sh
   git clone --depth 1 https://github.com/frappe/frappe_docker.git && cd frappe_docker
   DOCKER_BUILDKIT=1 docker build --secret id=apps_json,src=../apps.json \
     --build-arg CACHE_BUST="$(date +%s)" \
     --build-arg FRAPPE_PATH=https://github.com/frappe/frappe --build-arg FRAPPE_BRANCH=version-16 \
     --file images/layered/Containerfile \
     -t 379220350808.dkr.ecr.ap-south-1.amazonaws.com/oan-frappe:develop .
   ```

   OrbStack and Docker Desktop clusters see local images directly. For kind or k3d,
   import the image (`kind load docker-image ...`, `k3d image import ...`).

3. **Make the dev hostname point at your node.** Add this line to `/etc/hosts`, with
   the node IP from step 1, and remove it when you need the real dev host again:

   ```
   192.168.139.2 grievance-backend-dev.oanstaging.com
   ```

   Check with `dscacheutil -q host -a name grievance-backend-dev.oanstaging.com` (macOS).
   If it shows a public address, requests go to the real dev host instead.

4. **Do dev steps 3 to 8 in the one cluster**, without the context switches, with tag
   `develop` in step 8. Skip step 2: a local cluster without an ingress controller has
   nothing on ports 80 and 443. Skip the security group: the node ports stay on your
   machine.

5. **Create a certificate from a local CA.** Let's Encrypt cannot issue for your
   machine.

   ```sh
   H=grievance-backend-dev.oanstaging.com
   kubectl create namespace grievance
   openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=OAN local dev CA" -keyout ca.key -out ca.crt
   openssl req -newkey rsa:2048 -nodes -subj "/CN=$H" -keyout tls.key -out tls.csr
   printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$H" > ext.cnf
   openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 365 -extfile ext.cnf -out tls.crt
   kubectl -n grievance create secret tls oan-grievance-tls --cert=tls.crt --key=tls.key
   ```

   Keep `ca.crt` for curl. For a browser, either trust `ca.crt` in the system keychain,
   or use `mkcert` (`mkcert -install`, then `mkcert $H`), which does both steps.

6. **Install the routes** (dev step 9, without the cert-manager part), with the node IP
   from step 1 as the external host:

   ```sh
   helm upgrade --install oan-grievance-gateway <oan_grievance_service>/apisix/k8s -n grievance \
     -f environments/dev/values/oan-grievance-gateway.yaml \
     --set-string web.externalHost=192.168.139.2 --set-string socket.externalHost=192.168.139.2 --wait
   ```

7. **Check**, as in dev step 10:

   ```sh
   curl -s --cacert ca.crt https://grievance-backend-dev.oanstaging.com/v1/grievances/health
   PW=$(kubectl -n develop get secret oan-grievance-admin -o jsonpath='{.data.password}' | base64 -d)
   curl -s --cacert ca.crt -H 'Content-Type: application/json' \
     -d "{\"usr\":\"Administrator\",\"pwd\":\"$PW\"}" \
     https://grievance-backend-dev.oanstaging.com/v1/auth/login | head -c 120
   kubectl -n apisix exec deploy/apisix-valkey -- valkey-cli --scan | head -3
   kubectl -n develop logs deploy/grievance-worker-scan --tail=5
   ```

Tear down: `helm uninstall` the five releases, delete the namespaces `grievance`,
`develop`, `apisix` and `local-path-shared`, then delete the retained volumes
(`kubectl get pv`, then `kubectl delete pv <name>`; the data is under
`/opt/local-path-shared` on the node).
