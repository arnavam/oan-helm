# A2C on Kubernetes

OAN Access to Credit (`oan_a2c`, with `oan_auth_service` in the same bench) is a Frappe
app. It runs in an app cluster of its own and is reached through the central APISIX
gateway, the same way as the grievance service. Read
[grievance-service.md](grievance-service.md), section 1, first: the layout, the storage
class, the node-port hop and the Secrets are the same. This guide covers only what is
different for A2C.

## 1. What differs from grievance

| | Grievance | A2C |
|---|---|---|
| Chart | [charts/oan-grievance-service](../charts/oan-grievance-service) | [charts/oan-a2c](../charts/oan-a2c) |
| Release / namespace | `grievance` / `develop` | `a2c` / `a2c-develop` |
| Frappe site | `develop.grievance.test` | `develop.a2c.test` |
| Public host | `grievance-backend-dev.oanstaging.com` | `a2c-backend-dev.oanstaging.com` (confirm) |
| Node port in the app cluster | 30800 (web), 30900 (socket.io) | 30810 (web) |
| Image | `oan-frappe` | `oan/a2c` (ECR repository of the A2C Jenkinsfile) |
| Extra workloads | ClamAV, four queue workers | none: A2C uses only the default, short and long queues |
| Gateway routes | `oan-grievance-gateway`, namespace `grievance` | `oan-a2c-gateway`, namespace `a2c` |
| Values | [oan-grievance-service.yaml](../environments/dev/values/oan-grievance-service.yaml) | [oan-a2c.yaml](../environments/dev/values/oan-a2c.yaml), [oan-a2c-gateway.yaml](../environments/dev/values/oan-a2c-gateway.yaml) |

APISIX tells the two apart by hostname: every route lists its app's `hosts`, and both
apps serve `/v1/auth/*`, so the host is the only separator. An unknown host gets
`404 Route Not Found`.

The A2C chart is the grievance chart without the grievance parts. It depends on the same
upstream chart (`erpnext` 8.0.89, alias `frappe`). Its site-config job waits for the site,
writes `siteConfig` and the JWT key, adds the OpenG2P credentials when their Secret
exists, and runs `bench migrate`.

## 2. Secrets

Created by hand, never in values files.

| Secret | Cluster | Namespace | Keys | Used for |
|---|---|---|---|---|
| `oan-a2c-db` | A2C | `a2c-develop` | `password` | MariaDB root password |
| `oan-a2c-admin` | A2C | `a2c-develop` | `password` | Frappe `Administrator` password |
| `oan-a2c-jwt` | A2C | `a2c-develop` | `jwt_v1.pem` | RS256 signing key for `oan_auth_service` |
| `oan-a2c-openg2p` | A2C | `a2c-develop` | `username`, `password` | Optional: OpenG2P portal agent login |
| `oan-a2c-sentry` | A2C | `a2c-develop` | `dsn` | Optional: Sentry DSN |
| `oan-a2c-tls` | gateway | `a2c` | `tls.crt`, `tls.key` | Certificate APISIX serves for the host |
| `a2c-openg2p-consent-webhook`, `a2c-telco-ivr-lead-gateway`, `a2c-oan-dashboards` | gateway | `a2c` | `key` | Partner and dashboard API keys, one Secret per consumer |
| `a2c-frappe-service-credential` | gateway | `apisix` | `authorization` | `token <api_key>:<api_secret>` of the login-disabled Frappe service user. The partner routes put it in `Authorization`. |

The service user is a Frappe user on the A2C site with an API key and secret. Create it
once the site exists, and store the credential in the secret manager.

## 3. Install

Same order as grievance. The A2C cluster:

```sh
kubectl create namespace a2c-develop
kubectl -n a2c-develop create secret generic oan-a2c-db --from-literal=password="$(openssl rand -hex 16)"
kubectl -n a2c-develop create secret generic oan-a2c-admin --from-literal=password="$(openssl rand -hex 12)"
openssl genrsa -out jwt_v1.pem 2048
kubectl -n a2c-develop create secret generic oan-a2c-jwt --from-file=jwt_v1.pem=jwt_v1.pem
rm jwt_v1.pem

helm dependency build charts/oan-a2c
helm upgrade --install a2c charts/oan-a2c -n a2c-develop \
  -f environments/dev/values/oan-a2c.yaml \
  --set-string frappe.image.tag=<develop-build> \
  --set-string "frappe.mariadb-sts.rootPassword=$(kubectl -n a2c-develop get secret oan-a2c-db -o jsonpath='{.data.password}' | base64 -d)" \
  --wait --wait-for-jobs --timeout 25m
kubectl -n a2c-develop get svc a2c-gateway-web          # NodePort 30810
```

In the A2C node's security group, allow TCP 30810 from the gateway cluster's address
only.

The gateway cluster: create namespace `a2c`, the certificate Secret and the four key
Secrets of section 2. APISIX reads the service credential from its environment, so create
`a2c-frappe-service-credential` in `apisix` first (the Pod starts without it, but the
partner routes then send an invalid credential). Then, with the chart from the `oan_a2c`
checkout at the deployed commit:

```sh
helm upgrade --install oan-a2c-gateway <oan_a2c>/apisix/k8s -n a2c \
  -f environments/dev/values/oan-a2c-gateway.yaml \
  --set-string web.externalHost=<A2C node private IP> --wait
```

Point DNS for the A2C host at the gateway node.

## 4. Check

```sh
H=https://a2c-backend-dev.oanstaging.com
curl -si -X POST $H/v1/auth/login -H 'Content-Type: application/json' -d '{}' | head -3   # 400: reached A2C, no health route exists
curl -si -X POST $H/v1/webhooks/consent-data | head -3    # 401: no partner key
```

`Administrator` cannot call `/v1/auth/me` on A2C: it holds the `A2C Development Agent`
role, and A2C makes Development Agents sign in through SSO. The error log says
"Development Agents must sign in through SSO". To test authenticated calls, register a
user with a self-registerable role and log in as that user:

```sh
curl -s $H/v1/auth/register -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","password":"<12+ chars>","full_name":"You","role":"A2C Farmer"}'
curl -s $H/v1/auth/login -H 'Content-Type: application/json' -d '{"usr":"you@example.com","pwd":"<password>"}'
```

## 5. Local

Same releases and values on the one local cluster, as in
[grievance-service.md](grievance-service.md), section 3. Differences:

1. **Build the image under the ECR name**, from an `apps.json` with `oan_auth_service`
   and `oan_a2c`. The gateway routes are generated from the A2C branch that moves auth
   to `oan_auth_service`, so build that branch:

   ```json
   [
     {"url": "https://github.com/Centre-for-Open-Societal-Systems/oan_auth_service", "branch": "develop"},
     {"url": "https://github.com/arnavam/oan_a2c", "branch": "feat/migrate-auth-to-oan-auth-service"}
   ]
   ```

   Tag it `379220350808.dkr.ecr.ap-south-1.amazonaws.com/oan/a2c:develop` and install with
   `frappe.image.tag=develop`.
2. **Certificate:** sign a second certificate for `a2c-backend-dev.oanstaging.com` with the
   same local CA, and create `oan-a2c-tls` in namespace `a2c`.
3. **Routes:** `--set-string web.externalHost=<node IP>` (for example `192.168.139.2`).
4. **`/etc/hosts`:** a line for the A2C host next to the grievance one.
5. **Memory:** grievance and A2C together, with Rancher, overload an 8 GB Docker VM
   (load average above 30). Probes then time out, and a first install fails with
   "Connection refused" to `a2c-valkey-cache:6379`. Stop the k3d Rancher cluster
   (`k3d cluster stop rancher`) and scale `grievance-clamav` to 0 while installing, or
   give OrbStack more memory (`orb config set memory_mib 12288`).
6. **A failed first install cannot be resumed:** the create-site job treats an existing
   site as done, so a half-installed site never gets its apps. Uninstall the release,
   delete the PVCs in the namespace and the Released volumes, and install again.
