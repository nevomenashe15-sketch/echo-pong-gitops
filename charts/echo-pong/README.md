# echo-pong Helm chart

Deploys the echo-pong Go HTTP service to EKS: a ClusterIP Service fronted by an
AWS ALB, with its bearer token synced from AWS Secrets Manager by the External
Secrets Operator and mounted as a read-only file.

```
helm template echo-pong . -f values.yaml -f values-prod.yaml
```

`values.yaml` is never applied alone. Exactly one environment overlay is layered
on top of it, last file wins:

| File | Purpose |
|---|---|
| `values.yaml` | shared baseline, no environment specifics |
| `values-dev.yaml` | dev, auto-synced |
| `values-staging.yaml` | staging, auto-synced |
| `values-prod.yaml` | production, manual-sync only |
| `values-kind.yaml` | **local smoke test only** — not an environment, never referenced by Argo CD |

## Objects rendered

| Kind | Notes |
|---|---|
| `Deployment` | probes, security context, preStop, spread, soft arm64 affinity |
| `Service` | ClusterIP; **not** a data-path hop, see below |
| `ServiceAccount` | no AWS annotation — the app needs no AWS identity |
| `Ingress` | ALB annotations; only when `ingress.enabled` |
| `NetworkPolicy` | default-deny both directions, narrow allowances |
| `PodDisruptionBudget` | voluntary-disruption guard |
| `HorizontalPodAutoscaler` | CPU target; only when `autoscaling.enabled` |
| `ExternalSecret` | ESO; references the remote secret by name only |
| `SecretStore` | optional, off by default |

No `Namespace` object: Argo CD creates it via `CreateNamespace=true` +
`managedNamespaceMetadata` (which also applies the Pod Security Admission
`restricted` labels). That is what lets the AppProject keep
`clusterResourceWhitelist: []`.

**No `Secret` object, ever.** The chart contains no secret value and no field
that could carry one.

---

## Shutdown behaviour — the most important caveat in this chart

**The application has no SIGTERM handling.** `main()` ends at
`log.Fatal(srv.ListenAndServe())`. There is no `signal.NotifyContext`, no
`srv.Shutdown()`, no drain phase. When SIGTERM is delivered the process dies
immediately and anything in flight is cut.

Nothing in this chart changes that, and no document in this repository should
describe the deployment as "gracefully draining".

What the chart does instead is delay the signal:

```yaml
lifecycle:
  preStop:
    enabled: true
    type: sleep        # native sleep action, not exec
    seconds: 5
terminationGracePeriodSeconds: 15
```

Pod deletion runs these concurrently:

1. the pod is removed from the Service `EndpointSlice`, and the AWS Load
   Balancer Controller begins deregistering the Pod IP from the target group
   (`deregistration_delay.timeout_seconds=10`);
2. the `preStop` hook sleeps 5s — SIGTERM is **not** sent during this window.

By the time SIGTERM lands, the pod should no longer be receiving *new*
requests. This **reduces** dropped requests. It does **not** eliminate them:

- a request still executing when the sleep ends is still killed mid-response;
- a request slower than the remaining window is still cut;
- if deregistration is slower than the preStop sleep, the ALB may still send a
  request to a pod that is about to die.

The real fix belongs in the application (`signal.NotifyContext` +
`srv.Shutdown(ctx)`). Until that ships, the mitigation above is the honest
ceiling, and the residual error rate during rollouts and node churn is real.

### Why `type: sleep` and not an `exec` hook

The image is `gcr.io/distroless/static-debian12:nonroot`. It has **no shell and
no `sleep` binary**, so the conventional
`exec: ["/bin/sh","-c","sleep 5"]` hook cannot execute at all — it would fail
silently and SIGTERM would arrive immediately. The native `sleep` lifecycle
action (KEP-3960, beta and on by default in Kubernetes 1.30, GA in 1.32) is the
only option that works with this image. Verified accepted by a live API server
(see the smoke-test notes in the repository README).

---

## Startup and probes

The app **sleeps 10 seconds before opening its listener**. During that window
the port is not merely slow — it refuses connections outright.

| Probe | Path | Timing | Why |
|---|---|---|---|
| `startupProbe` | `/health` | `initialDelay 0`, `period 2s`, `failureThreshold 30` | 60s budget for a 10s sleep — 6x headroom for a cold Karpenter node, a slow pull, or CPU throttling, while still failing a genuinely broken container inside a minute |
| `readinessProbe` | `/health` | `period 5s`, `failureThreshold 3` | gates ALB target registration; fails fast (~15s) because removing a pod from the load balancer is cheap |
| `livenessProbe` | `/health` | `period 10s`, `failureThreshold 3` | deliberately slacker — restarting a pod is far more destructive than removing it from the LB, so it needs more evidence |

All three hit the same single `/health` endpoint, because that is the only
health endpoint the app has. There is no `/health/live` + `/health/ready`
split. The differentiation is therefore entirely in the **timing**, not in the
endpoint.

**No `initialDelaySeconds` on liveness or readiness, on purpose.** While a
`startupProbe` is configured and has not yet succeeded, the kubelet does not
evaluate readiness or liveness at all. That built-in gating already covers the
10s sleep; adding a manual delay would double-count it and slow every restart.

`/health` is public and unauthenticated, which is what makes it usable as the
ALB health-check path — an ALB cannot present a bearer token.

---

## Ingress, the ALB, and what is actually in the data path

Two different diagrams are true at the same time and must not be conflated.

**Logical (Kubernetes) view — what the objects reference:**

```
Ingress  ->  ClusterIP Service  ->  Pods
```

**Effective AWS data path — where packets actually go:**

```
CloudFront (WAF)  ->  ALB  ->  Pod IP
```

The `Ingress` is **declarative configuration** consumed by the AWS Load
Balancer Controller, not a runtime proxy. With `target-type: ip` the controller
registers Pod IPs directly into the target group, so traffic goes ALB ENI ->
Pod ENI. The Service is how the controller *discovers* which pods to register;
no request is proxied through its ClusterIP. There is no in-cluster ingress
controller pod and no second proxy hop.

### Origin protection (not implemented here, by design)

CloudFront injects a secret origin-verification header, and a **regional WAFv2
Web ACL on the ALB** blocks requests that lack it. This is enforced entirely at
the AWS layer. **Nothing in this chart implements or checks that header**, and
it must not — the app's own authentication is the `Authorization` bearer token,
which is a different control at a different layer.

The Web ACL is *defined* by the sibling Terraform repo. It is *associated* here,
via `alb.ingress.kubernetes.io/wafv2-acl-arn`, because the ALB does not exist
until this Ingress is reconciled. Exactly one owner for the association —
Terraform must not also try to attach it.

---

## What the NetworkPolicy can and cannot do

Read this before tightening or trusting it.

### What it genuinely does

- **Default-deny in both directions.** Selecting the pod and listing both
  `policyTypes` means anything not explicitly allowed is dropped.
- **East-West is properly restricted.** No other pod in the cluster can open a
  connection to echo-pong unless it matches `networkPolicy.extraIngressFrom`.
  This is the real blast-radius benefit: a compromised workload elsewhere in
  the cluster cannot reach the app.
- **Egress is near-zero.** See below.

### What it cannot do

- **It does not gate the ALB.** With `target-type: ip` the ALB connects to Pod
  IPs from its own ENIs in the VPC. That source **is not a pod**, so
  `podSelector` and `namespaceSelector` can never match it. The only
  expressible allowance is an `ipBlock`, and the practical CIDR is the ALB
  subnets:

  ```yaml
  networkPolicy:
    albSourceCidrs:
      - 10.30.0.0/20
      - 10.30.16.0/20
  ```

  That is **coarse**. It permits anything in those subnets to reach `:8080` —
  it does not prove the caller is the ALB. This is structurally different from
  an in-cluster ingress controller, where the source *is* a pod and a
  `podSelector` would be exact.

  What actually gates who may call the API is the bearer token (in the app) and
  the CloudFront origin header enforced by WAF (in AWS). The NetworkPolicy is a
  blast-radius control, not the front door. Do not present it as one.

- **It is inert without a policy engine.** Plain VPC CNI does not enforce
  NetworkPolicy unless the network policy agent is enabled; the alternative is
  Calico or Cilium. Without one, the API server accepts these objects and
  nothing happens. This was confirmed empirically on Kind (see repository
  README): with kindnetd, even an explicit deny-all-ingress policy had **no
  effect** — traffic still flowed.

### Egress: why it is almost empty

echo-pong makes **zero outbound connections**. No database, no upstream API, no
AWS SDK call. Specifically:

- the bearer token arrives as a **mounted file** written by ESO — the AWS
  Secrets Manager call is made by the *ESO controller's* pod, not this one;
- image pulls are performed by the **kubelet on the node** and are not subject
  to pod NetworkPolicy at all.

So there is genuinely nothing to allow. DNS (`53/udp`, `53/tcp` to
`kube-system`) is the single allowance, kept on because it costs nothing and a
silent DNS blackhole is a disproportionately confusing failure mode if anything
is ever added. Set `networkPolicy.egress.dns: false` for a strict zero-egress
posture — the app itself will not notice.

There is deliberately **no** speculative "443 to the world" rule.

---

## Secret delivery

```
Terraform (sibling repo)      creates Secrets Manager secret METADATA, the IAM
                              read policy, and ESO's EKS Pod Identity association
                              — never the value
        |
        v
External Secrets Operator     reads the value with its OWN identity
        |
        v
Kubernetes Secret             echo-pong-token, key: token
        |
        v
echo-pong pod                 mounts it read-only at /etc/echo-pong/secret
        |
        v
SECRET_FILE_PATH=/etc/echo-pong/secret/token
```

- The pod's ServiceAccount has **no AWS annotation and needs none**.
- The value is never an env var, never a Helm value, never in Git.
- `SECRET_FILE_PATH` is computed from `secret.mountPath` + `secret.key` by a
  template helper, so the env var and the volume mount cannot drift apart.
- `deletionPolicy: Retain` — pruning the ExternalSecret does not immediately
  delete the live Secret, so a mis-sync cannot instantly break every pod.
- The `ExternalSecret` uses a plain `data:` mapping rather than a `template:`
  block, specifically so no Go-template expression referencing the secret value
  ever appears in a rendered manifest.

The app reads the file **once at startup**. A rotated secret therefore does
**not** take effect until the pods restart, even though ESO refreshes the
Kubernetes Secret every `refreshInterval`. Rotation requires a rollout. This is
an application limitation, not a chart one — see the repository README risks
section.

### `defaultMode: 0440`

Secret volume files are owned `root:<fsGroup>`. With `fsGroup: 65532` set, the
kubelet widens the group bits to mirror the owner's read bit, so `0400` and
`0440` both land as `-r--r-----` and both are readable by UID 65532 — verified
on a live cluster, not assumed. `0440` is written explicitly because it states
the effective result rather than depending on that widening, and it stays
correct if `fsGroup` is ever removed.

---

## Security context

| Setting | Value | Reason |
|---|---|---|
| `runAsNonRoot` / `runAsUser` / `runAsGroup` | `true` / `65532` / `65532` | matches the distroless `static-debian12:nonroot` UID; restating it makes the API server enforce it rather than inheriting it |
| `fsGroup` | `65532` | makes the mounted Secret readable (see above) |
| `seccompProfile` | `RuntimeDefault` | required by PSA `restricted` |
| `allowPrivilegeEscalation` | `false` | |
| `capabilities.drop` | `[ALL]` | static binary, needs none |
| `readOnlyRootFilesystem` | `true` | see below |
| `automountServiceAccountToken` | `false` | the app never calls the Kubernetes API, so it should not hold a token for it |

### Does it need a writable `/tmp`?

**No, and `tmpVolume` is off by default.** Checked against the source rather
than added defensively: the binary is static (`CGO_ENABLED=0`), logs to stdout,
reads the token once, and serves fixed JSON/HTML from memory. There is no
`ParseMultipartForm` (which is the usual reason a Go HTTP server touches
`os.TempDir()`), no `os.CreateTemp`, and no cache directory.

`tmpVolume.enabled: true` adds an `emptyDir` at `/tmp` if a future code change
needs it. That is the fix — not relaxing `readOnlyRootFilesystem`.

---

## Scheduling

### Soft arm64 preference — and why it must stay soft

```yaml
nodeAffinity:
  preferArm64: true
  arm64Weight: 90
```

Rendered as `preferredDuringSchedulingIgnoredDuringExecution`, never
`requiredDuringScheduling` and never a `nodeSelector`.

The image is a multi-arch manifest list (`linux/amd64` + `linux/arm64`), so an
amd64 node is a fully correct fallback. A hard requirement would convert a
*transient* Graviton capacity shortage — a spot reclaim, an AZ-level
`InsufficientInstanceCapacity` — into **unschedulable pods**, trading an
availability outage for a cost optimisation. The soft preference produces
identical placement in the normal case and degrades to "runs on amd64, costs a
little more" in the bad case.

This only means something because a **matching amd64 Karpenter NodePool
exists** (`platform/karpenter/*/nodepool-amd64-fallback.yaml`, lower `weight`).
A pod preference cannot create nodes. With an arm64-only NodePool the soft
preference would be decorative — the scheduler would have nowhere else to put
the pod and Karpenter no pool able to build one.

### Topology spread — both axes

| Axis | dev | staging | prod |
|---|---|---|---|
| `topology.kubernetes.io/zone` | `ScheduleAnyway` | `DoNotSchedule` | `DoNotSchedule` |
| `kubernetes.io/hostname` | `ScheduleAnyway` | `ScheduleAnyway` | `DoNotSchedule` |

Production is strict on both. Losing an AZ must not be able to take the service
with it, and without a hostname constraint Karpenter will happily consolidate
every replica onto one large node — at which point a single spot reclaim or
node replacement is a full outage. A `Pending` pod is a louder and safer failure
than silent concentration, and Karpenter provisions the extra node on demand.

`matchLabelKeys: [pod-template-hash]` scopes the skew calculation to a single
ReplicaSet. Without it, during a rollout the old and new revisions are counted
together and a strict `DoNotSchedule` constraint can deadlock the `maxSurge`
pod against the outgoing revision. Requires Kubernetes >= 1.27 (beta) / 1.30.

Dev and staging relax the hostname axis because they run fewer nodes, where a
strict rule would produce `Pending` pods for reasons production would never hit.

---

## Availability

```yaml
updateStrategy:
  rollingUpdate:
    maxUnavailable: 0     # never remove a serving pod before its replacement is Ready
    maxSurge: 1
```

Verified live: during a rollout `availableReplicas` never dropped below the
desired count (the Deployment surged to 3 total, then settled at 2).

| | replicas / HPA min | PDB `minAvailable` | allowed voluntary evictions at the floor |
|---|---|---|---|
| base | 2 | 1 | 1 |
| dev | 2 (HPA off) | 1 | 1 |
| staging | 2–4 | 1 | 1 |
| prod | 3–6 | **2** | 1 |

Production's HPA floor is deliberately **one above** the PDB minimum. If
`minReplicas` equalled `minAvailable`, the PDB would permit zero voluntary
evictions at the floor and node drains, cluster upgrades and Karpenter
consolidation would all deadlock. `templates/hpa.yaml` **hard-fails the render**
on that combination rather than shipping it — this actually fired during
development against the base values and is why the base default is 1, not 2.

The PDB guards *voluntary* disruption only. It does not protect against a node
dying, and it does not protect against a bad rollout — `maxUnavailable: 0`
covers that.

### HPA behaviour

- **Scale up:** no stabilisation window. A new pod already costs ~10s of
  startup sleep before it can serve; waiting first makes it worse.
- **Scale down:** 300s stabilisation, 1 pod per minute. Reacquiring a pod is
  slow (startup sleep, possibly a Karpenter node), so flapping is expensive.
- **CPU only.** Memory targeting is off: this app's memory is flat and unrelated
  to load, so a memory target would produce noise, not signal.

---

## Resources

```yaml
requests: { cpu: 50m,  memory: 64Mi }
limits:   { cpu: 200m, memory: 128Mi }
```

A single static Go binary serving fixed JSON with no dependencies; idle RSS is a
few MB and the request path allocates almost nothing. Requests are sized for
honest scheduling, limits leave ~4x CPU / 2x memory burst room.

A CPU limit is present on purpose rather than omitted: this workload has no
legitimate reason to burst past it, and an unbounded tiny service is a
noisy-neighbour risk on shared Karpenter capacity where it would also distort
the HPA's utilisation signal.

---

## Image

```yaml
image:
  repository: <account>.dkr.ecr.<region>.amazonaws.com/echo-pong
  digest: sha256:...      # always set in every committed overlay
  tag: "0.1.0"            # fallback for local rendering only
```

`{{ include "echo-pong.image" . }}` emits `repo@digest` whenever `digest` is
set, otherwise `repo:tag`. **Every committed environment overlay sets a
digest**, including dev — if dev promoted by tag, the promotion path would
differ from production's and dev would stop being a rehearsal. `:latest` appears
nowhere in this repository.

Changing `image.digest` in `values-prod.yaml` **is** the production release.
Reverting it **is** the rollback.

---

## Values reference (selected)

| Key | Default | Notes |
|---|---|---|
| `image.digest` | `""` | set per environment; wins over `tag` |
| `app.port` | `8080` | container port, `PORT` env var, probe and NetworkPolicy port |
| `secret.mountPath` / `secret.key` | `/etc/echo-pong/secret` / `token` | together form `SECRET_FILE_PATH` |
| `externalSecret.apiVersion` | `external-secrets.io/v1beta1` | templated — ESO promoted to `v1` in 0.14, so an upgrade is a values change |
| `externalSecret.remoteRef.key` | `echo-pong/token` | Secrets Manager name or ARN; **name only, never a value** |
| `lifecycle.preStop.type` | `sleep` | native action; `exec` cannot work on distroless |
| `terminationGracePeriodSeconds` | `15` | preStop sleep + slack |
| `nodeAffinity.preferArm64` | `true` | soft only |
| `networkPolicy.albSourceCidrs` | `[10.0.0.0/16]` | narrow to ALB subnets per environment |
| `networkPolicy.egress.dns` | `true` | the only egress allowance |
| `tmpVolume.enabled` | `false` | app provably needs no scratch space |

## Guard rails built into the templates

The chart fails to render — rather than producing something subtly broken — on:

- `autoscaling.minReplicas <= podDisruptionBudget.minAvailable` (drain deadlock);
- both or neither of `podDisruptionBudget.minAvailable` / `maxUnavailable`;
- `ingress.enabled` without `ingress.host`;
- `ingress.alb.httpsEnabled` without `certificateArn`;
- an ALB with neither HTTP nor HTTPS listener.
