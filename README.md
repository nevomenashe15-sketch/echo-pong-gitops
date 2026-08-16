# echo-pong-gitops

Kubernetes desired state for **echo-pong**, reconciled by Argo CD.

This repository owns everything in the cluster *after* Argo CD exists. A sibling
Terraform repository (`echo-pong-infrastructure`) owns everything up to and
including "Argo CD is installed and running", and never touches another
Kubernetes object after that.

> **Status: local staging copy.** Not a git repository, not pushed, never
> applied to a real cluster or AWS account. Validation was done with
> `yamllint`, `helm lint`, `helm template`, `kubeconform --strict` and a
> throwaway local Kind cluster.

---

## Layout

```
echo-pong-gitops/
├── .yamllint.yaml
├── README.md
├── charts/echo-pong/            # the application chart (see its own README)
│   ├── Chart.yaml
│   ├── README.md
│   ├── values.yaml              # shared baseline, never applied alone
│   ├── values-dev.yaml
│   ├── values-staging.yaml
│   ├── values-prod.yaml
│   ├── values-kind.yaml         # LOCAL smoke test only, not an environment
│   └── templates/
│       ├── _helpers.tpl
│       ├── NOTES.txt
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── serviceaccount.yaml
│       ├── ingress.yaml
│       ├── networkpolicy.yaml
│       ├── pdb.yaml
│       ├── hpa.yaml
│       ├── externalsecret.yaml
│       └── secretstore.yaml
├── argocd/
│   ├── root-app.yaml            # app-of-apps; the one hand-applied object
│   ├── projects/
│   │   ├── appproject-echo-pong.yaml
│   │   └── appproject-platform.yaml
│   └── apps/
│       ├── echo-pong/
│       │   ├── applicationset.yaml        # dev + staging
│       │   └── application-prod.yaml      # prod, separate and manual-sync
│       └── platform/
│           ├── aws-load-balancer-controller.yaml
│           ├── external-secrets.yaml
│           ├── karpenter.yaml
│           └── platform-resources.yaml    # ClusterSecretStore + Karpenter CRs
└── platform/
    ├── external-secrets/
    │   └── clustersecretstore.yaml
    └── karpenter/
        ├── dev/{ec2nodeclass,nodepool-arm64}.yaml
        ├── staging/{ec2nodeclass,nodepool-arm64,nodepool-amd64-fallback}.yaml
        └── prod/{ec2nodeclass,nodepool-arm64,nodepool-amd64-fallback}.yaml
```

---

## Ownership boundary

| Owned by Terraform (`echo-pong-infrastructure`) | Owned here (via Argo CD) |
|---|---|
| AWS accounts, VPC, subnets, EKS control plane, managed node group | every Kubernetes object except Argo CD itself |
| ECR repositories, KMS, Route 53, ACM, CloudFront, CloudFront WAF | the approved immutable image digest |
| Secrets Manager secret **metadata** + IAM read policy | the `ExternalSecret` that consumes it |
| IAM roles + EKS Pod Identity associations for ALB controller, ESO, Karpenter | installation and configuration of those controllers |
| Karpenter's IAM prerequisites, SQS interruption queue, discovery tags | **Karpenter `NodePool` / `EC2NodeClass`** |
| Regional WAFv2 Web ACL **definition** | Web ACL **association** (Ingress annotation) |
| Argo CD bootstrap install — the single sanctioned Terraform→K8s action | everything after that |

Two boundaries worth stating explicitly because they are easy to get wrong:

- **Karpenter CRs belong here, not in Terraform.** Terraform creates the IAM
  role `echo-pong-<env>-karpenter-node` and
  `echo-pong-<env>-karpenter-controller` (referenced by exactly those names in
  `platform/karpenter/`), the interruption queue, and the
  `karpenter.sh/discovery` tags. It creates no `NodePool` and no
  `EC2NodeClass` — those arrive post-bootstrap through GitOps.
- **The Web ACL association must happen here.** Terraform *defines* the
  regional Web ACL, but the ALB does not exist until the AWS Load Balancer
  Controller reconciles this repo's `Ingress`. So the association is the
  `alb.ingress.kubernetes.io/wafv2-acl-arn` annotation. Exactly one owner —
  Terraform must not also attach it.

---

## Argo CD structure

```
root (app-of-apps, path: argocd/, recurse)
├── wave -20  AppProject echo-pong          namespaced kinds only, clusterResourceWhitelist: []
├── wave -20  AppProject platform           enumerated cluster-scoped kinds
├── wave -10  aws-load-balancer-controller  upstream chart, pinned
├── wave -10  external-secrets              upstream chart, pinned
├── wave -10  karpenter                     upstream chart, pinned
├── wave   0  external-secrets-config       ClusterSecretStore (needs ESO CRDs)
├── wave   0  karpenter-resources           ApplicationSet: NodePool/EC2NodeClass per env
└── wave  10  echo-pong                     ApplicationSet: dev + staging
    wave  10  echo-pong-prod                separate Application, manual sync
```

Platform add-ons are **`Application`s pointing at pinned upstream charts** with
inline values, rather than a wrapper chart-of-charts. The reason: a wrapper
chart adds a version of its own that has to be bumped alongside the upstream
version, and it hides the upstream values behind another layer of templating.
With one `Application` per add-on, upgrading is a one-line `targetRevision`
change in a reviewed diff, and the values are literal upstream values.

Sync waves matter here: ESO's and Karpenter's CRDs must exist before anything
that ships a CR of theirs. Waves plus generous `retry` make a cold bootstrap
converge instead of failing once.

The root app is **self-managing** (it watches the directory it lives in), so
changing the root app is itself a reviewed Git change.

### Sync policy per environment

| Environment | `automated` | `prune` | `selfHeal` |
|---|---|---|---|
| dev | yes | yes | yes |
| staging | yes | yes | yes |
| **production** | **no — manual sync only** | — | — |
| platform add-ons | yes | yes | yes |

**Staging is auto-synced, deliberately.** Its job is to be a faithful rehearsal
of the production manifest set. If staging were manual-sync, the auto-sync
machinery — prune semantics, wave ordering, `ServerSideApply` behaviour — would
first be exercised in production, and the thing production promotes from would
be a configuration nobody watched Argo CD apply on its own. Auto-sync in the
cheap environment, gated manual sync in the expensive one.

**Production has no `automated` block at all.** Release path:

1. CI builds, scans and signs an image and opens a promotion PR changing
   exactly one line — `image.digest` in `charts/echo-pong/values-prod.yaml`.
2. The PR is reviewed and merged. Branch protection on this repository enforces
   that, not Argo CD.
3. Argo CD reports the Application `OutOfSync` and **does nothing**.
4. A human (or the `prod-syncer` AppProject role) triggers the sync.

CI is never granted `kubectl apply` access. It only opens the PR.

#### Why not `automated: {selfHeal: true, prune: false}` for production?

`selfHeal` only ever pulls from already-merged Git state, so it cannot
introduce unreviewed configuration — it is genuinely tempting. It is off anyway
for two reasons:

- During an incident the fastest safe mitigation is often `kubectl scale` or
  deleting a pod. With `selfHeal` on, an operator must remember to suspend it
  first, under pressure, or watch their mitigation get reverted within ~3
  minutes.
- `selfHeal` changes production without anyone deciding that *now* is a good
  moment. "A person chooses the moment" is precisely production's guard rail.

The cost is that genuine drift persists until someone acts. Argo CD still
reports `OutOfSync` — that is the alert, and it should be wired to one.

#### `prune` risk, stated plainly

`prune` deletes live objects absent from Git. In production that would include
anything applied out-of-band during an incident — a debug pod, a temporary
NetworkPolicy exception, a manually patched HPA. Unattended deletion of those,
potentially mid-incident, is a worse failure mode than a stale object. Pruning
still happens on a manual sync when explicitly requested.

Two prune consequences elsewhere that are **enabled** and worth knowing:

- **`karpenter-resources` prunes.** Deleting a `NodePool` from Git makes
  Karpenter drain and terminate every node it owns. Correct GitOps behaviour,
  and also a cluster-wide event.
- **The root app prunes.** Removing an `Application` from Git stops its
  reconciliation, and the `resources-finalizer` cascades to its workloads.

### Rollback

`git revert` the digest change in `values-prod.yaml`, then let Argo CD
reconcile (manual sync for prod). **That is the mechanism** — there is no
second one, on purpose. A rollback path that can restore a state which is not
in Git would make Git stop being the source of truth. Git history is the
release history.

### Sync windows — deliberately not built

Argo CD `AppProject.spec.syncWindows` could deny syncs outside a change window.
Left out: with manual-only production sync, the window is already "whenever the
approver chooses", and an unused scheduling mechanism is one more thing to
misconfigure. Worth revisiting only if production ever moves to automated sync.

---

## Environments

| | dev | staging | prod |
|---|---|---|---|
| namespace | `echo-pong-dev` | `echo-pong-staging` | `echo-pong-prod` |
| replicas | 2 (HPA off) | 2–4 | 3–6 |
| PDB `minAvailable` | 1 | 1 | **2** |
| zone spread | `ScheduleAnyway` | `DoNotSchedule` | `DoNotSchedule` |
| hostname spread | `ScheduleAnyway` | `ScheduleAnyway` | `DoNotSchedule` |
| Karpenter capacity | arm64, spot-first | arm64 + amd64 fallback, spot enabled | arm64 + amd64 fallback, **on-demand only** |
| WAF Web ACL | none | yes (count-mode tuning) | yes |
| sync | automated | automated | **manual** |

All three currently target `https://kubernetes.default.svc`. `server` is a
generator parameter in the ApplicationSets, so splitting an environment onto its
own EKS cluster is a one-line change plus an AppProject destination entry — no
template edit.

---

## Karpenter

`platform/karpenter/<env>/` holds plain YAML CRs (no Helm templating — these are
a handful of objects and indirection would only obscure them).

- **arm64 NodePool at `weight: 100`**, families `c7g/m7g/r7g/c8g/m8g`, sizes
  capped at `xlarge`, across three AZs.
- **amd64 NodePool at `weight: 10`** — this is what makes the chart's *soft*
  arm64 affinity meaningful. A pod preference cannot create nodes; without a
  pool that can build amd64 capacity, the "fallback" has nothing to fall back
  to.
- **Spot:** enabled in dev and staging, **on-demand only in production**, with
  the toggle documented inline. The reason is specific rather than generic: the
  app has no SIGTERM handling, so a spot interruption ends in an abrupt kill and
  dropped requests. Staging is where that error rate gets measured. Turning spot
  on in production is a cost-vs-error-rate decision that should follow the
  application's graceful-shutdown fix, not precede it.
- **Disruption:** `WhenEmptyOrUnderutilized` consolidation, a 10% node budget,
  and a business-hours freeze on `Underutilized`/`Drifted` disruption in
  production (involuntary replacement still proceeds).
- **`expireAfter: 336h`** with the `al2023@latest` AMI alias is how security
  patches actually reach the fleet. `terminationGracePeriod: 24h` bounds how
  long a misconfigured PDB can stall a security-driven node replacement.
- **`httpPutResponseHopLimit: 1`** keeps IMDS reachable from the node but not
  from a pod's network namespace, so a compromised container cannot steal the
  node role's credentials.

---

## Validation

All commands are read-only and local. Nothing here contacts AWS or a real
cluster.

```bash
yamllint -c .yamllint.yaml .

for env in dev staging prod kind; do
  helm lint charts/echo-pong -f charts/echo-pong/values.yaml \
                             -f charts/echo-pong/values-$env.yaml
  helm template echo-pong charts/echo-pong \
    -f charts/echo-pong/values.yaml -f charts/echo-pong/values-$env.yaml \
    --namespace echo-pong-$env > /tmp/$env.yaml
done

CRD='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
kubeconform -strict -summary -kubernetes-version 1.31.0 \
  -schema-location default -schema-location "$CRD" /tmp/prod.yaml
kubeconform -strict -summary -kubernetes-version 1.31.0 \
  -schema-location default -schema-location "$CRD" \
  $(find argocd platform -name '*.yaml')
```

`yamllint` ignores `charts/*/templates/` — those are Go templates, not YAML.
They are covered instead by `helm lint` + `helm template` (which produces real
YAML) and then `kubeconform` on that output.

### Local Kind smoke test

`charts/echo-pong/values-kind.yaml` exists **only** for this. It is not an
environment overlay and no Argo CD `Application` references it. It disables the
Ingress (no AWS Load Balancer Controller), the `ExternalSecret` (no ESO, no AWS)
and the HPA (no metrics-server), and swaps in a public placeholder image.

```bash
kind create cluster --name echo-pong-smoke
kubectl create namespace echo-pong-smoke
kubectl -n echo-pong-smoke create secret generic echo-pong-token \
  --from-literal=token=dummy-local-only-not-a-real-secret
helm install echo-pong charts/echo-pong \
  -f charts/echo-pong/values.yaml -f charts/echo-pong/values-kind.yaml \
  --namespace echo-pong-smoke --wait
```

**This is a test of chart mechanics, not of echo-pong.** The placeholder image
(`traefik/whoami`) shares echo-pong's runtime *shape* — tiny static Go binary,
multi-arch, no shell, works under `readOnlyRootFilesystem` as a non-root UID,
answers 200 on `/health` — but none of its behaviour: no auth, no secret file,
no 10s startup sleep.

**Kind's default CNI is `kindnetd`, which does not implement NetworkPolicy.**
This was confirmed empirically rather than assumed: applying an explicit
deny-all-ingress policy to the running pods changed nothing — a curl from
another pod still returned `HTTP 200`. NetworkPolicy *enforcement* is therefore
**not** validated by this smoke test; only that the API server accepts the
object. Enforcement in EKS depends on the VPC CNI network policy agent, Calico
or Cilium being enabled — see the chart README.

---

## Known limitations and risks

1. **The application has no graceful shutdown.** No SIGTERM handler, no
   `srv.Shutdown()`. The `preStop` sleep mitigates but does not eliminate
   dropped in-flight requests on every rollout, scale-down, node drain and spot
   reclaim. Nothing in this repository can fix that; it needs an application
   change. Do not describe this deployment as gracefully draining.
2. **Secret rotation requires a pod restart.** The app reads the token file once
   at startup. ESO will refresh the Kubernetes Secret on schedule, but running
   pods keep the old value indefinitely. Rotation is therefore a two-step
   operation (rotate, then roll), and for production the roll is a manual sync.
   A `reloader`-style annotation controller is the usual fix and is **not**
   installed here.
3. **The NetworkPolicy cannot gate the ALB path.** It restricts East-West
   traffic properly, but ALB→Pod-IP traffic can only be expressed as an
   `ipBlock`, which is subnet-coarse. See the chart README.
4. **Placeholder values throughout.** Account ID `000000000000`, region
   `eu-west-1`, `example.com` hosts, all-zero digests, ACM/WAF ARNs and the VPC
   ID in the ALB controller Application are placeholders and must be replaced
   with real values from the Terraform repo's outputs before any deployment.
5. **Cluster name is hardcoded per add-on Application.** The three platform
   add-on Applications name `echo-pong-prod` as the cluster. If dev/staging get
   their own clusters, these need to become an ApplicationSet over clusters —
   the echo-pong and Karpenter Applications already are.
6. **Chart-level version assumptions.** `preStop.sleep` needs Kubernetes ≥ 1.30;
   `matchLabelKeys` on topology spread needs ≥ 1.27. Both are satisfied by
   current EKS versions but are worth stating.
7. **ESO API version.** `external-secrets.io/v1beta1` is used and is templated
   via `externalSecret.apiVersion`. ESO 0.14+ prefers `v1`; upgrading the
   operator means changing that value in the same PR.
