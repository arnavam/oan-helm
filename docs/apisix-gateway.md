# APISIX gateway

The OAN API gateway is Apache APISIX, configured through the APISIX Ingress Controller.
This document is the design and the DevOps runbook for the development clusters.

**Status:** nothing here has been run against a cluster yet. Where a step depends on
something we could not confirm, it says **Confirm** and tells you how to check.

One central gateway serves every OAN app. It runs alone in its own cluster (the gateway
cluster). Each app runs in its own cluster: grievance on RKE2 (`13.233.56.204`), A2C in
a cluster not provisioned yet. All are separate from the OpenG2P dev cluster (`server`
in `environments/dev/endpoints.yaml`, `13.201.58.55`). The values sit with the other dev
values in `environments/dev/values/`, and each file names its target cluster in its
header. **Never install them into the OpenG2P cluster.**

## 1. Design

### What lives where

| Part                              | Source                                                                                                                                                                                                                                   | Values                                                                                         |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| APISIX and the Ingress Controller | Upstream chart `apisix/apisix` 2.18.2 (bundles `apisix-ingress-controller`) from `https://apache.github.io/apisix-helm-chart`. It is not vendored, repackaged or added to `releases/`                                                    | [dev/values/apisix.yaml](../environments/dev/values/apisix.yaml)                               |
| Rate-limit counters               | Upstream chart `valkey/valkey` 0.11.0 from `https://valkey.io/valkey-helm/`, release `apisix-valkey` next to APISIX                                                                                                                     | [dev/values/valkey-gateway.yaml](../environments/dev/values/valkey-gateway.yaml)               |
| Grievance routes                  | Chart `oan-grievance-gateway` in [oan_grievance_service/apisix/k8s](https://github.com/Centre-for-Open-Societal-Systems/oan_grievance_service/tree/develop/apisix/k8s), generated from the service's OpenAPI spec. It is not copied here | [dev/values/oan-grievance-gateway.yaml](../environments/dev/values/oan-grievance-gateway.yaml) |
| A2C routes                        | Chart `oan-a2c-gateway` in [oan_a2c/apisix/k8s](https://github.com/Centre-for-Open-Societal-Systems/oan_a2c/tree/develop/apisix/k8s), generated from the A2C OpenAPI spec                                                                | [dev/values/oan-a2c-gateway.yaml](../environments/dev/values/oan-a2c-gateway.yaml)             |

This repository holds only the values. Each app's route chart lives with the app, because
the routes come from the app's OpenAPI spec and must change in the same PR as the code.
The grievance service will get its own chart repository and releases later; until then,
install its chart from a checkout of the service repository at the deployed commit.

All of these install into the gateway cluster: APISIX and Valkey in namespace `apisix`,
each app's routes in a namespace named after the app (`grievance`, `a2c`).

oan_auth_service is a library installed into each app's bench, not a service of its own,
so it has no chart or values. Its endpoints (`/v1/auth/*`, `/v1/admin/*`,
`/v1/notifications/*`) are part of each app's chart, pointed at that app's Frappe.

Do not also run `adc sync` against this gateway. ADC and the Ingress Controller each
overwrite the other's routes.

### Traffic path

```
browser -> DNS grievance-backend-dev.oanstaging.com -> gateway node
        -> APISIX, hostPorts 80 and 443 on the node      TLS, routes, rate limits, CORS, metrics
        -> grievance node, private address               node ports 30800 (gunicorn), 30900 (socket.io)
```

APISIX is the edge. It binds the gateway node's ports 80 and 443 and terminates TLS with
the certificate each app's `ApisixTls` names. No nginx or ingress controller sits in
front of it, so clients connect directly and rate limits see their own address.

APISIX picks the app by the request's host: the TLS handshake (SNI) picks the
certificate, and each route matches its app's `hosts` and paths. Apps share paths such
as `/v1/auth/*` (oan_auth_service runs in each bench), so every app's chart must set
`hosts`. An empty list matches any host.

The Ingress Controller resolves only Services in its own cluster. An app chart therefore
points its ApisixUpstreams at the app cluster's private address (`web.externalHost`,
`socket.externalHost`): the upstream lists that address as its only node, and the routes
reference the upstream by name. Without `externalHost` the same chart targets an
in-cluster Service, for a gateway in the app's own cluster. The app cluster exposes
Frappe on node ports that accept only the gateway cluster's addresses. That hop is plain
HTTP, so it must stay on a private network (one VPC, or peering).

The Frappe app itself is installed by `charts/oan-grievance-service`; its runbook is
[grievance-service.md](grievance-service.md), which installs this gateway as one of its
steps.

### Gateway-wide plugins

`request-id` (`X-Request-Id`, echoed in the response) and `prometheus` are global rules,
set as `gatewayProxy.plugins` in `apisix.yaml`, so they apply to every app's routes. Metrics
are served on port 9091 at `/apisix/prometheus/metrics`; enable
`metrics.serviceMonitor` once a Prometheus Operator scrapes the cluster. Per-app plugins
(CORS, body size, rate limits, authentication) stay in each app's chart.

## 2. Prerequisites

Run these from a machine with `kubectl` and `helm` (3.x) pointed at the gateway cluster.

```sh
kubectl config current-context        # must be the gateway cluster, not OpenG2P or an app cluster
kubectl get nodes -o wide             # expect the gateway node
helm version --short
```

Collect these facts first. They are the values the install needs.

| Fact                                                                                                             | How to get it                                                                         | Goes in                                         |
| ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ----------------------------------------------- |
| What holds ports 80 and 443 on the node today (APISIX needs them) | `kubectl get pods -A -o wide \| grep -i -E 'ingress\|nginx\|traefik'` | section 4 |
| Private address of each app node, reachable from the gateway cluster | the cloud console | `--set-string web.externalHost=...` (section 5) |
| Browser origins of the grievance UI | ask the UI team | `corsOriginRegexes`, `realtimeAllowedOrigins` |

The upstream names, node ports and the Valkey for rate-limit counters are already in
`oan-grievance-gateway.yaml`. The node ports belong to `gatewayAccess` of the
`grievance` release of `charts/oan-grievance-service`.

Confirm that the cluster has no APISIX CRDs from another install:

```sh
kubectl get crd | grep apisix.apache.org || echo "none (expected on a fresh cluster)"
kubectl get ingressclass
```

## 3. Secrets and values

Create the secrets outside Git. Use random values (for example `openssl rand -hex 16`).

```sh
kubectl create namespace apisix
kubectl -n apisix create secret generic apisix-admin-credentials \
  --from-literal=admin="$(openssl rand -hex 16)" \
  --from-literal=viewer="$(openssl rand -hex 16)"
```

Keep the `admin` value in the team's secret manager. It is the gateway's Admin API key.

Then edit the values, in a branch of this repo, and get the change reviewed:

- `environments/dev/values/oan-grievance-gateway.yaml`: the origin lists. `siteName`,
  `hosts`, the upstream names and ports, `redis.host` and `tls.secretName` are already
  set. A missing required value stops `helm install` with "`<name>` is required".
- The certificate: Secret `oan-grievance-tls` in `grievance` (see
  [grievance-service.md](grievance-service.md), section 2, step 9).

## 4. Install the gateway

```sh
helm repo add apisix https://apache.github.io/apisix-helm-chart && helm repo update

# Read the plan first.
helm template apisix apisix/apisix --version 2.18.2 -n apisix \
  -f environments/dev/values/apisix.yaml | less

helm upgrade --install apisix apisix/apisix --version 2.18.2 -n apisix \
  -f environments/dev/values/apisix.yaml --wait --timeout 10m

helm repo add valkey https://valkey.io/valkey-helm/ && helm repo update valkey
helm upgrade --install apisix-valkey valkey/valkey --version 0.11.0 -n apisix \
  -f environments/dev/values/valkey-gateway.yaml --wait
```

The release name must be `apisix`: the Ingress Controller values point at the Service
`apisix-admin` that this name produces.

`apisix.yaml` binds the node's ports 80 and 443 (hostPort). While another Pod holds
them, the APISIX Pod stays `Pending`: turn off `rke2-ingress-nginx` first
([grievance-service.md](grievance-service.md), section 2, step 2).

Check:

```sh
kubectl -n apisix get pods                       # apisix, etcd, apisix-ingress-controller, apisix-valkey: Running
kubectl -n apisix get svc                        # apisix-gateway, apisix-admin, apisix-prometheus-metrics
kubectl get ingressclass apisix
kubectl -n apisix get gatewayproxy               # apisix-config
kubectl get crd | grep apisix.apache.org         # apisixroutes, apisixupstreams, apisixconsumers ...
kubectl get crd apisixroutes.apisix.apache.org -o jsonpath='{.spec.versions[*].name}'   # includes v2
kubectl -n apisix logs deploy/apisix-ingress-controller | tail -20   # no "unauthorized" or "connection refused"
```

If the controller cannot reach the Admin API, check that `apisix-admin-credentials`
exists and that `allow.ipList` plus `ingressControllerExtraIpList` (the private address
ranges) admit the controller Pod.

## 5. Install the grievance routes

Use the chart from the `oan_grievance_service` checkout at the **commit that is deployed**
(`git log -1` on the deployed branch), so routes match the running code.

```sh
CHART=<path to oan_grievance_service>/apisix/k8s
VALUES=environments/dev/values/oan-grievance-gateway.yaml

APP_HOST=<grievance node private IP>
SET="--set-string web.externalHost=$APP_HOST --set-string socket.externalHost=$APP_HOST"

helm lint "$CHART" -f "$VALUES" $SET
helm template oan-grievance-gateway "$CHART" -n grievance -f "$VALUES" $SET | less   # read it

helm upgrade --install oan-grievance-gateway "$CHART" -n grievance -f "$VALUES" $SET --atomic --wait
```

Check that the controller synced the routes:

```sh
kubectl -n grievance get apisixroute,apisixupstream
kubectl -n grievance describe apisixroute oan-grievance-service-v1 | tail -20   # status Accepted/Synced, no errors
kubectl -n apisix logs deploy/apisix-ingress-controller | grep -i -E 'error|fail' | tail
```

### Test through the gateway

Reach the gateway Service directly with a port-forward, so the tests do not depend on
DNS or the certificate. The `Host` header must be the public host.

```sh
kubectl -n apisix port-forward svc/apisix-gateway 9080:80 &
H='Host: grievance-backend-dev.oanstaging.com'

# 1. Health: 200, with an X-Request-Id header.
curl -si -H "$H" http://localhost:9080/v1/grievances/health | head -20

# 2. A route that does not exist: 404 from the gateway, not Frappe.
curl -si -H "$H" http://localhost:9080/v1/does-not-exist | head -5

# 3. CORS preflight from an allowed origin: 200/204 with access-control-allow-origin.
curl -si -X OPTIONS -H "$H" -H 'Origin: http://localhost:3000' \
  -H 'Access-Control-Request-Method: GET' http://localhost:9080/v1/grievances | head -12

# 4. Rate limit: public-read tier is 120/min per client address; expect 429 after that.
for i in $(seq 1 130); do curl -s -o /dev/null -w '%{http_code}\n' -H "$H" \
  http://localhost:9080/v1/auth/health; done | sort | uniq -c

# 5. Auth through the gateway (oan_auth_service endpoints are in this chart).
curl -si -H "$H" -H 'Content-Type: application/json' \
  -d '{"identifier":"<test user>","password":"<password>"}' http://localhost:9080/v1/auth/login | head -5

# 6. Metrics.
kubectl -n apisix port-forward svc/apisix-prometheus-metrics 9091:9091 &
curl -s http://localhost:9091/apisix/prometheus/metrics | grep -c apisix_http_status
```

Also test socket.io from a browser or `wscat` with a valid session (see Known open items).
If any test fails, stop here and fix it before using the public host.

## 6. Public traffic

Dev is built fresh, so there is no traffic to move: once APISIX holds ports 80 and 443,
the grievance host is served by it. Run the checks from section 5 against
`https://grievance-backend-dev.oanstaging.com`, using `/v1/grievances/health` for health,
not `/api/method/ping` (see Known open items). Watch for a few minutes:
`kubectl -n apisix logs deploy/apisix -f`, and the `apisix_http_status` metrics (look
for 5xx and 429).

## 7. After every later merge

The routes are generated from the service's OpenAPI spec, so they change whenever an
endpoint or tier changes. The order matters.

1. Merge the app PR. Its "OpenAPI and APISIX in sync" check guarantees `apisix/k8s` matches the code.
2. Deploy the new app image (Jenkins).
3. Run `helm upgrade` for `oan-grievance-gateway` in the gateway cluster, from the checkout
   at the deployed commit (section 5), with `--atomic --wait`.
4. Run the smoke checks from section 5 (health plus one route that changed).
5. On failure: `helm -n grievance rollback oan-grievance-gateway`.

Changes to the values in this repo (hosts, Service names, origins) need only step 3 and
the checks. Changes to `apisix.yaml` need `helm upgrade apisix ...` first.

## 8. A2C

A2C runs in an app cluster of its own and uses this gateway. Its install, secrets and
local setup are in [a2c.md](a2c.md). Its routes install into the gateway cluster,
namespace `a2c`, from the `oan_a2c` checkout at the deployed commit:

```sh
helm upgrade --install oan-a2c-gateway <oan_a2c>/apisix/k8s -n a2c --create-namespace \
  -f environments/dev/values/oan-a2c-gateway.yaml \
  --set-string web.externalHost=<A2C node private IP> --atomic --wait
```

`hosts` is set in `oan-a2c-gateway.yaml` (confirm the real name): routes of both apps
share paths such as `/v1/auth/*`, and an empty `hosts` would match any host. Expose A2C's
Frappe web Service on node port 30810 to the gateway cluster only, and point the A2C
host's DNS at the gateway node.

A2C needs secrets that grievance does not, all provisioned outside Git:

- One Secret per partner and dashboard consumer in namespace `a2c`, named after the
  consumer, with key `key`: `a2c-openg2p-consent-webhook`, `a2c-telco-ivr-lead-gateway`,
  `a2c-oan-dashboards`.
- `A2C_FRAPPE_SERVICE_AUTHORIZATION` (`token <api_key>:<api_secret>` of the Frappe service
  user) in the APISIX pods' environment, in the gateway cluster. Partner routes reference it as
  `$env://A2C_FRAPPE_SERVICE_AUTHORIZATION`. `apisix.yaml` reads it from the optional Secret
  `a2c-frappe-service-credential` (key `authorization`) in namespace `apisix`.

## 9. Known open items

- **Values to fill:** the UI origins for CORS and socket.io cookies (still the
  localhost defaults). For A2C: public host, site name, its node's private address and
  port, and partner egress CIDRs.
- **Gateway cluster.** Not provisioned yet: its public IP (DNS for every app host), and
  a private network shared with each app cluster. The hop to the app node ports is plain
  HTTP; without a private network it needs a VPN or TLS on that hop.
- **One node per app.** `web.externalHost` is one address. An app cluster with several
  nodes needs an internal load balancer in front of its node ports
  (`gatewayAccess.type: LoadBalancer`), and its address in `externalHost`.
- **socket.io `Origin`.** The socket routes set `Origin: http://<siteName>:8000`. The socket.io
  server calls Frappe back at that address, and Frappe also requires `Origin` and `Host` to
  name the same host. `develop.grievance.test` probably does not resolve inside the cluster,
  so socket authentication may fail. Test a socket connection in section 5. If it fails, the
  fix is to make the origin a chart value (`frappeWebOrigin`) and make that host resolvable
  from the socket.io Pod (for example `hostAliases` or a CoreDNS entry). Not done yet.
- **`/api/...` paths.** Clients use `/v1/...`, which the gateway rewrites to `/api/v1/...`.
  `/api/...` is intentionally not routed, so Jenkins' verify URL (`/api/method/ping`) would
  return 404 through the gateway. Use `/v1/grievances/health`, or keep a separate path to Frappe
  for ops checks.
- **Frappe `Host` handling.** The gateway rewrites `Host` to the site name
  (`develop.grievance.test`). Confirm Frappe answers for that site through the gateway
  (section 5, check 1).
- **Real client IP.** Rate limits are per client address, taken from the connection
  (no proxy in front, no `X-Real-IP` trusted). This holds only if the gateway node keeps
  the source address of hostPort traffic. Check the APISIX access log on the first requests. On a
  local OrbStack cluster it does not hold: every request shows the Pod gateway.
- **HTTP to HTTPS redirect.** Port 80 still serves the routes over plain HTTP. Once the
  first certificate is issued, add a `redirect` global rule (`http_to_https: true`) in
  `apisix.yaml`. Before the first issuance it would break the HTTP-01 challenge, since
  APISIX has no certificate to answer HTTPS with yet.
- **ADC and APISIX 3.19.** The Ingress Controller uses ADC internally, and ADC's documented
  support stops at APISIX 3.17. Watch the controller logs on the first sync.
- **etcd.** The bundled etcd is for development. Use `externalEtcd` before production.
- **Global plugins.** Confirm `request-id` and `prometheus` take effect: `X-Request-Id` in
  responses and the `apisix_http_status` metric.
