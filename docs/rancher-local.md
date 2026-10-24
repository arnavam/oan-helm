# Rancher on a local machine

A local Rancher Manager that manages the local OAN cluster the way a central Rancher
manages the dev clusters: Rancher runs on its own cluster, and every other cluster is
imported into it. This is a learning setup. It does not use the dev Rancher's chart
version or values, which are not recorded in this repository.

```
k3d cluster "rancher" (k3s v1.35.5)   Rancher 2.15.2 + cert-manager v1.21.2
   ▲ cattle-cluster-agent dials out over HTTPS
OrbStack cluster                      gateway + grievance (grievance-service.md, section 3)
```

Rancher needs its own cluster because the cluster it runs on becomes its management
cluster (`local` in the UI); the clusters it manages only run an agent. Tested on
OrbStack, where Rancher and its cluster need about 2.5 GB of memory on top of the
grievance stack.

Rancher Desktop is a different product: a local Kubernetes and container engine, with a
single-cluster view. It cannot import or manage other clusters. Do not run it next to
OrbStack.

## 1. Pick versions

The Rancher chart version is the Rancher version (chart `2.15.2` installs `v2.15.2`).
Each Rancher release accepts a range of Kubernetes versions, both for the cluster it runs
on and for clusters it imports:

```sh
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo add jetstack https://charts.jetstack.io
helm repo update rancher-stable jetstack
helm search repo rancher-stable/rancher --versions | head -3
helm show chart rancher-stable/rancher --version 2.15.2 | grep kubeVersion   # < 1.37.0-0
kubectl --context orbstack version | tail -1                                 # v1.36.5: importable
```

Once the dev Rancher's version is known (its UI shows it under the user menu, About),
use that chart version here instead.

## 2. Create the Rancher cluster

```sh
brew install k3d
k3d cluster create rancher --image rancher/k3s:v1.35.5-k3s1 --servers 1 --agents 0 \
  --kubeconfig-update-default --kubeconfig-switch-context=false --wait
kubectl --context k3d-rancher get nodes -o wide     # note INTERNAL-IP, e.g. 192.168.107.2
```

`--kubeconfig-switch-context=false` keeps your current context on the OrbStack cluster.

## 3. Choose the Rancher hostname

Both your browser and the agent Pods in the OrbStack cluster must reach Rancher by its
hostname, and see Rancher's own certificate: the agent pins Rancher's CA. Use the node IP
with sslip.io, a public DNS name that resolves to the IP inside it:

```sh
R=192.168.107.2.sslip.io        # your node IP from step 2
dscacheutil -q host -a name $R  # macOS: resolves to the node IP
```

Do not use the container's `*.orb.local` name. OrbStack answers HTTPS for those names
with its own certificate, so the agent would reject Rancher. If the k3d container gets a
new IP after a restart, the hostname changes; re-run step 4 with the new one.

## 4. Install cert-manager and Rancher

```sh
helm --kube-context k3d-rancher upgrade --install cert-manager jetstack/cert-manager \
  --version v1.21.2 -n cert-manager --create-namespace --set crds.enabled=true --wait
helm --kube-context k3d-rancher upgrade --install rancher rancher-stable/rancher \
  --version 2.15.2 -n cattle-system --create-namespace \
  --set hostname=$R --set replicas=1 --wait --timeout 15m
kubectl --context k3d-rancher -n cattle-system rollout status deploy/rancher
curl -sk https://$R/ping                             # pong
```

cert-manager issues Rancher's certificate from a CA that Rancher generates. Rancher
publishes that CA, and each agent checks it. `replicas=1` because the cluster has one
node.

## 5. First login

```sh
kubectl --context k3d-rancher -n cattle-system get secret bootstrap-secret \
  -o go-template='{{.data.bootstrapPassword|base64decode}}' | pbcopy
```

The login page prints the same command without `--context`. Run that way, it reads your
current context (the OrbStack cluster), which has no Rancher, and the login fails with
"Invalid username or password".

Open `https://$R` and accept the browser warning (the CA is Rancher's own). Paste the
bootstrap password, set the admin password, and keep the **Server URL** as
`https://$R`. Every agent connects to that URL.

## 6. Import the OrbStack cluster

1. **Cluster Management → Import Existing → Generic**. Name it `orbstack`, then
   **Create**.
2. Rancher shows a `kubectl apply -f https://$R/v3/import/<token>.yaml` command. Use the
   variant with `curl --insecure`, because your machine does not trust Rancher's CA,
   and run it against the OrbStack cluster:

   ```sh
   curl --insecure -sfL https://$R/v3/import/<token>.yaml | kubectl --context orbstack apply -f -
   ```

3. Watch the agent connect:

   ```sh
   kubectl --context orbstack -n cattle-system get pods            # cattle-cluster-agent: Running
   kubectl --context orbstack -n cattle-system logs deploy/cattle-cluster-agent | tail
   ```

   The cluster turns **Active** in Rancher within a few minutes.

In Rancher, open the `orbstack` cluster:

- **Apps → Installed Apps** lists the Helm releases (`apisix`, `apisix-valkey`,
  `grievance`, `oan-grievance-gateway`, `local-path-shared`), because Rancher reads
  Helm's release records.
- **Workloads**, **Service Discovery** and **Storage** show the Pods, node ports and
  volumes from grievance-service.md.
- **Projects/Namespaces**: put `develop` in its own project to control who can see the
  release values, which include the MariaDB root password.

Importing changes nothing in the cluster except adding the agent (namespace
`cattle-system`, plus `cattle-fleet-system` for Fleet).

## 7. Remove

```sh
# In Rancher: Cluster Management → orbstack → Delete. It removes the agent.
k3d cluster delete rancher
```

If Rancher is gone before you delete the cluster in it, remove the agent from the
OrbStack cluster by hand: delete the namespaces `cattle-system`, `cattle-fleet-system`
and `cattle-impersonation-system`.
