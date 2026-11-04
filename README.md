# A minimal example of Headscale in Hetzner with Cilium

This example installs and configures Headscale on Kubernetes hosted in Hetzner. The end result is a self-hosted Tailscale-style VPN. This implementation attempts to remain minimal while using real-world infrastructure for rapid deployments.

The example uses:
- Cilium for CNI, ingress, and egress.
- cert-manager for external and internal TLS using dns01 challenge,
- AWS Route53 to facilitate the _dn01_ ACME challenge, used by cert-manager issuers.
- Gateway API.
- A Tailnet, the Tailscale network, exposed with Headscale, a self-hosted Tailnet VPN.

## Tools

To perform tasks described below, the following tools are necessary:

- a patched hetzner-k3s version, described below,
- Helm, kubectl, yq, bash.

## Install hetzner-k3s

This minimal example uses a Kubernetes cluster with a single control plane node and three workers.  
The upstream _hetzner-k3_ tool contains two bugs preventing it from happening, but the maintainer does not agree these are bugs, apparently.  
The two problems:

1. Cilium Helm installer requires a minimum of three nodes to roll Cilium out. The default _hetzner-k3s_ tool, for my configuration, will deploy a single control plane, and attempt installing Cilium on that single control plane node BEFORE starting workers. But Cilium will never roll out. The patched version changes this behavior, it proceeds to install the software only when the control plane and workers are up.
2. Even though autoscaler is off, the tool insists on autoscaler autoscaling.

So, a custom version is necessary. You can build and install it directly to `~/.local/bin` using:

```sh
"$(pwd)/tools/hetzner-k3s.sh"
```

I'm sure the default hetzner-k3s tool would work fine for a cluster with three control plane nodes but that's no longer a minimal example, and it has a significant cost to it.

## Helm repositories

This adds Cilium and cert-manager Helm repositories to your Helm and performs `helm repo update` on both of them.

```sh
"$(pwd)/tools/helm-repos.sh"
```

## Cilium image versions

For Cilium to install corectly, the Helm chart requires correct Envoy and Cilium operator image versions. You can use the following method to find out which container image versions are used by which version of the Cilium Helm chart.

```sh
# get Cilium version from the cluster definition:
CILIUM_VERSION=$("$(pwd)/installer.sh" --cluster-file "$(pwd)/bootstrap/cluster.yaml" --show-cilium-version)
# Identify images in the Helm chart:
"$(pwd)/tools/cilium-images.sh "${CILIUM_VERSION}"
```

Update `bootstrap/cilium-values.yaml` file with all images for the selected Cilium version.

The second task is to look for which Gateway API CRDs are needed by the Cilium version to be installed on the cluster. [This information is here](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/). For previous versions, switch to the Cilium version documentation and search for _Gateway API Support_. Those have to be included directly in the _installer.sh_.

## Create the cluster and install Cilium CNI

This step creates the cluster in Hetzner using the _hetzner-k3s_ tool.  
The tool installs Cilium. The tool uses _helm install_.

```sh
"$(pwd)/installer.sh" \
  --cluster-file "$(pwd)/bootstrap/cluster.yaml" \
  --cilium-values-file "$(pwd)/bootstrap/cilium-values.yaml" \
  --hcloud-token-file "${HOME}/.hetzner/token/svcssh" \
  --cluster-launch
```

The HCloud token is a read/write Hetzner project API key for a project in which the infrastrcuture is to be created. Create one and place it in the `--hcloud-token-file` file.

Once the above command completes successfully, there's a Kubernetes cluster with CNI and Heztner components required for load balancers and PVCs handling.   
On Hetzner side, there are following resources created:

- Machines on which the cluster has been created.
- The network for the machines.
- A firewall.
- A load balancer.

There is no cert-manager yet, there are no certificates.

## Route53 configuration

The infrastructure uses Let's Encrypt for TLS. The _dn01_ challenge must be somehow handled automatically without the need for human intervention. Cert-manager provides a number of built-in ACME challenge solvers. This example uses Route53 but you can use any DNS provider with an API.

Create an IAM user called `svcssh-cert-manager-head-in` with no policies selected. Once created, attach an inline policy named `svcssh-cert-manager-head-in`, and the following content:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
        "Effect": "Allow",
        "Action": "route53:GetChange",
        "Resource": "arn:aws:route53:::change/*"
    },
    {
        "Effect": "Allow",
        "Action": [
            "route53:ChangeResourceRecordSets",
            "route53:ListResourceRecordSets"
        ],
        "Resource": "arn:aws:route53:::hostedzone/ZONE-ID",
        "Condition": {
            "ForAllValues:StringEquals": {
                "route53:ChangeResourceRecordSetsRecordTypes": ["TXT"]
            }
        }
    }
  ]
}
```

Replace `ZONE-ID` with your hosted zone ID from Route53.

Create the user.

Next, go to security credentials, Access keys, create an access key. Write the access key to the `~/.hetzner/aws/svcssh-cert-manager-head-in` file as env file format (lowercase variable names):

```
access_key_id=AKIA...
secret_access_key=71+9...
```

This file will be picked up by the bootstrap part of the installer and used to create the _route53-dns01-credential-secret_ secret required by the cert-manager Route53 solver.

For your own cluster, modify issuers in `headscale/cert-manager.*.yaml` files. Set the email, the region, and hosted zone ID to match your configuration. Alternatively, configure your own solvers.

## Bootstrap everything else

```sh
"$(pwd)/installer.sh" \
    --cluster-file "$(pwd)/bootstrap/cluster.yaml" \
    --cert-manager-values-file "$(pwd)/bootstrap/cert-manager-values.yaml" \
    --route53-dns01-credential-file "${HOME}/.hetzner/aws/svcssh-cert-manager-head-in" \
    --cluster-bootstrap
```

Following components become available:

- GatewayAPI with experimental TLS route support.
- The default Cilium `GatewayClass`, this cannot be installed by Cilium Helm installer because the feature depends on the existence of the GatewayAPI CRDs.
- cert-manager.
- Headscale:
  - outside and inside cert-manager issuers, with certificates,
  - the gateway with its TLS route,
  - the deployment with its config map and a PVC, Headscale is currently configured with HA and sqlite as a backend,
  - the LoadBalancer service with Hetzner load balancer annotations,
    - no GatewayAPI for this endpoint because Hetzner cloud controller requires a service to update the load balancer,

## When things go wrong

### Accessing headscale PVC

```sh
kubectl scale deployment/headscale -n headscale --replicas 0
```

Then:

```sh
kubectl apply -f "$(pwd)/headscale/headscale-shell.yaml"
```

Now it's possible to `kubectl exec` into the bash pod and look at all files:

```sh
POD_NAME=$(kubectl get pods \
  -l headscale/component=shell \
  -n headscale \
  --output jsonpath='{.items[0].metadata.name}')
kubectl exec -ti "${POD_NAME}" -n headscale -- ls -la /opt/headscale
```

#### Make a backup

```sh
kubectl cp "headscale/${POD_NAME}:/opt/headscale/db.sqlite" \
  "$(pwd)/backups/headscale/db.sqlite"
```

The database is the most important one.

Once you're done:

```sh
kubectl scale deployment/headscale-shell -n headscale --replicas 0
kubectl scale deployment/headscale -n headscale --replicas 1
```

#### Restore from a backup

Scale Headscale down to 0. Start the shell deployment, then execute:

```sh
kubectl cp "$(pwd)/backups/headscale/db.sqlite" \
  "headscale/${POD_NAME}:/opt/headscale/db.sqlite"
```

followed by scaling the shell don to 0, and scaling Headscale back to 1. Your Tailnet is now restored and devices can access with new preauth keys. You will have to issue new preauth keys.

### Hubble relay certificates

When Hubble Relay uses Cilium CA.  
If the ones from the command below aren't expired (there should be cilium-ca only in there):

```sh
kubectl -n kube-system get secret hubble-server-certs \
  -o jsonpath='{.data.ca\.crt}' |
  base64 -d |
  openssl x509 -noout -subject -dates -fingerprint -sha256
```

Delete the following two secrets and upgrade Cilium via Helm because that triggers new certificate being generated:

```sh
kubectl -n kube-system delete secret \
  hubble-server-certs hubble-relay-client-certs
helm upgrade cilium <same-chart-reference> \
  -n kube-system \
  --reuse-values \
  --version <installed-chart-version>
```

This will fix failing Hubble Relay.

### Enable request logging in Cilium

```sh
kubectl apply -f - <<EOF
---
apiVersion: cilium.io/v2alpha1
kind: CiliumGatewayClassConfig
metadata:
  name: headscale-logs
  namespace: kube-system
spec:
  telemetry:
    accessLogs:
      - format: JSON
        json:
          gateway: "%CILIUM_GATEWAY_NAMESPACE%/%CILIUM_GATEWAY_NAME%"
          start_time: "%START_TIME%"
          method: "%REQUEST_HEADER(:METHOD)%"
          path: "%REQUEST_HEADER(X-ENVOY-ORIGINAL-PATH?:PATH)%"
          protocol: "%PROTOCOL%"
          response_code: "%RESPONSE_CODE%"
          response_code_details: "%RESPONSE_CODE_DETAILS%"
          response_flags: "%RESPONSE_FLAGS%"
          upstream_host: "%UPSTREAM_HOST%"
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller
  parametersRef:
    group: cilium.io
    kind: CiliumGatewayClassConfig
    name: headscale-logs
    namespace: kube-system
EOF
```

To disable:

```sh
kubectl apply -f - <<EOF
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller
EOF
```

### Looking at tailscale client logs on the macOS

```sh
tailscale debug daemon-logs
```

When logs show something similar to:

```
control: LoginInteractive -> regen=true
control: doLogin(regen=true, hasUrl=false)
control: control server key from https://head.svcs.sh: ts2021=[4WFVF], legacy=
control: Generating a new nodekey.
control: RegisterReq: onode= node=[TXsyr] fup=false nks=false
control: controlhttp: forcing port 443 dial due to recent noise dial
Received error: register request: Post "https://head.svcs.sh/machine/register": all connection attempts failed (HTTP: TLS forced: no port 80 dialed, HTTPS: unexpected HTTP response: 403 Forbidden)
```

This means that Cilium is terminating the TLS and the connection is failing due to WebSocket transport issues.

```sh
kubectl logs --follow -l k8s-app=cilium-envoy -n kube-system
```

```
{"gateway":"headscale/headscale-gtw","method":"POST","path":"/ts2021","protocol":"HTTP/1.1","response_code":403,"response_code_details":"upgrade_failed","response_flags":"-","start_time":"2026-11-02T08:01:56.010Z","upstream_host":null}
```

The reason why this happens is that Headscale requires the following in `CiliumEndpointConfig` but it's not possible to do this in Cilium, it reverts back to `websocket`.

```yaml
typed_config:
  "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
  upgrade_configs:
    - upgrade_type: tailscale-control-protocol
```

The only way to make this work is to set up TLS passthrough, as this example does.
