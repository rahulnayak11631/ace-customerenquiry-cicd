# Implementation runbook

Written as the work actually happened. Cluster: same `ai-poc` kubeadm cluster
as the Argo Rollouts project (3 nodes). This POC's new pieces live on
`ai-poc-worker-02` (same box as that project's GitHub Actions runner and
Jenkins) because that's where the real IBM ACE 13.0.8.0 install and the
proven `/opt/IBM/Dockerfile` build already exist.

## 0. What was already there (discovered, not built)

- ACE 13.0.8.0 at `/opt/IBM/ace-13.0.8.0` on worker-02 (`ibmint`, `mqsi*`
  binaries, sourced via `server/bin/mqsiprofile`).
- `/opt/IBM/Dockerfile` — bakes the whole ACE install + a BAR into a
  runtime image (`ENTRYPOINT` runs `IntegrationServer` on port 7800),
  already used to build/push `rahulnayak11631/customerenqapi:main-7`
  (4.91GB) to Docker Hub.
- Two Jenkins jobs (`ACE-CustomerEnquiry-CICD`, `ace-docker-cicd`) pointed
  at `github.com/MatrixAlgo/ACE-CustomerEnquiryAPI-CICD-POC` — proven the
  `ibmint package` BAR-build command and the Docker build/push shape;
  currently deploys via a plain `docker run` on the host, which this POC
  replaces with real Kubernetes + ArgoCD. Left untouched.
- SonarQube reachable at `http://34.204.251.107:9000` (admin/ai-poc given -
  a dedicated API token was generated from it rather than reusing the
  admin password directly in CI).
- 3 zips on the master (`/root/ace-cicd/customerEnqAPI_v{1,2,3}*.zip`),
  genuine ACE Toolkit-exported REST API artifacts for `customerEnquiryAPI`
  (`POST /customerenquiryapi/v1/enquiry`; success path keys off
  `customerId == "1001"`, `apiVersion` in the JSON response tells you which
  build answered).

## 1. Repo bootstrap

```bash
gh repo create rahulnayak11631/ace-customerenquiry-cicd --public \
  --description "IBM ACE customerEnquiryAPI - CI/CD + GitOps POC"
```

Extracted the 3 zips locally; `main` starts from v1's content plus the full
CI/CD scaffolding (Helm chart, ArgoCD Applications, RBAC, workflow, docs);
`v1.0.0`/`v2.0.0`/`v3.0.0` are snapshot branches of just `customerEnquiryAPI/`
for each provided version, mirroring the existing Jenkins job's `VERSION`
parameter choices. Pushed all 4 branches.

> The PAT used for pushing is a fine-grained token scoped to specific
> repos - had to add this new repo to its allowed list (GitHub Settings →
> Developer settings → Personal access tokens) before the first push
> would work; `gh api` reads succeeded throughout because those reflect
> account permissions, not the token's own restricted scope.

## 2. Cluster setup

```bash
for ns in ace-dev ace-sit ace-uat; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
# copy ingress-tls (from ai-copilot-demo) and regcred (from loanengine)
# into each of the three namespaces, same pattern as the Argo Rollouts project.
kubectl apply -f ci/rbac.yaml            # ace-ci-deployer SA + Roles + token Secret
kubectl apply -f argocd/application-dev.yaml \
               -f argocd/application-sit.yaml \
               -f argocd/application-uat.yaml
```

Found ArgoCD itself scaled to `0/0` replicas across every Deployment (likely
done earlier to ease memory pressure on a tight master node) - scaled it
back to 1 before anything would sync.

## 3. SonarQube token

```bash
curl -s -u admin:ai-poc -X POST "http://localhost:9000/api/user_tokens/generate" \
  -d "name=ace-cicd-$(date +%s)"
```
Run **from worker-02 itself** (`localhost:9000`) - hitting SonarQube via
worker-02's own public/Elastic IP from another node in the same VPC hit the
same hairpin-NAT timeout documented in the Argo Rollouts project.

## 4. ArgoCD `ci` account + Applications

Reused the Argo Rollouts project's existing ArgoCD local account (`ci`)
rather than creating a second one - just extended its RBAC policy to also
cover this project's app names:
```bash
kubectl patch cm argocd-rbac-cm -n argocd --type merge -p '{"data":{"policy.csv":
  "p, role:ci, applications, sync, default/bluegreen-demo-*, allow\n
   p, role:ci, applications, get, default/bluegreen-demo-*, allow\n
   p, role:ci, applications, sync, default/ace-customerenquiry-*, allow\n
   p, role:ci, applications, get, default/ace-customerenquiry-*, allow\n
   g, ci, role:ci\n"}}'
```

The `ace-ci-deployer` Kubernetes ServiceAccount's kubeconfig had to be
hand-built and placed at `/home/ec2-user/.kube/ace-ci-deployer.config` on
worker-02 (extract the token + CA data from the ServiceAccount's Secret,
write a kubeconfig, done) - the RBAC objects existing in the cluster isn't
the same as the runner having a usable file at the path the workflow's
`KUBECONFIG` env var points to. Missing this caused `kubectl` to silently
fall back to its legacy default `localhost:8080` - which happens to be
Jenkins' own port on this box, producing a very misleading "Jenkins login
page" error instead of a connection-refused.

## 5. Self-hosted runner (2nd one on worker-02)

```bash
mkdir -p ~/actions-runner-ace && cd ~/actions-runner-ace
tar -xzf ~/actions-runner/actions-runner.tar.gz   # reuse the cached tarball
REG_TOKEN=$(gh api -X POST repos/rahulnayak11631/ace-customerenquiry-cicd/actions/runners/registration-token --jq .token)
./config.sh --url https://github.com/rahulnayak11631/ace-customerenquiry-cicd \
  --token "$REG_TOKEN" --name worker-02-ace --labels ace-cicd --work _work --unattended
sudo ./svc.sh install ec2-user && sudo ./svc.sh start
```

Also installed `sonar-scanner` CLI (`/opt/sonar-scanner-6.2.1.4610-linux-x64`,
symlinked to `/usr/local/bin/sonar-scanner`); `kustomize`/`yq`/`argocd`
were already on `/usr/local/bin` from the Argo Rollouts project setup.

`ec2-user` wasn't in the `docker` group on worker-02 (only had `sudo docker`
access) - `usermod -aG docker ec2-user` + restart the runner service to pick
up the new group membership.

## 6. GitHub secrets + `uat-promotion` Environment

`DOCKERHUB_USERNAME`/`TOKEN` (from `regcred`), `ARGOCD_SERVER`/`ARGOCD_AUTH_TOKEN`
(ClusterIP `10.110.112.200:80`, a fresh `ci` account token), `SONAR_HOST_URL`
(`http://localhost:9000` - the runner IS on the SonarQube box)/`SONAR_TOKEN`.

`uat-promotion` Environment created via `gh api ... environments/uat-promotion`
with `reviewers: [{"type":"User","id":<rahulnayak11631's id>}]` - identical
mechanism to the Argo Rollouts project's Jenkins-vs-GitHub-Actions decision;
chosen here specifically because GitHub emails the reviewer automatically,
no SMTP server needed.

## 7. First run + verification - six real bugs, in the order they surfaced

1. **`aquasecurity/trivy-action@0.28.0` unresolvable** - release tags are
   `v`-prefixed (`v0.36.0`), not bare.
2. **`permission denied ... docker.sock`** - see step 5, `ec2-user` needed
   the `docker` group.
3. **Trivy `context deadline exceeded`** - secret-scanning a 4.9GB image hit
   the default timeout. Fixed with `scanners: vuln` (drop secret-scanning)
   + `timeout: 15m0s`.
4. **`kubectl` silently talking to `localhost:8080`** (Jenkins) instead of
   the cluster - see step 4, the kubeconfig file didn't exist yet at the
   path the workflow referenced.
5. **Smoke test always saw an empty `apiVersion`**, timing out after 8
   retries, even though every single raw response in the log already showed
   the correct value. Root cause was in `smoke-test.sh`'s own Python parser:
   it looked for `Data.customer.apiVersion`, but ACE's REST binding emits
   `OutputRoot.JSON.Data` directly as the HTTP response body's root - the
   real shape is just `customer.apiVersion`, no `Data` wrapper. The
   Deployment, the rollout, and the API were never actually broken.
6. **`deploy-sit`'s push rejected as non-fast-forward** - `actions/checkout`
   pins to the commit SHA that triggered the *whole run*, not the branch's
   live tip, so `deploy-sit`'s checkout didn't include `deploy-dev`'s own
   bump commit (pushed moments earlier in the same run). Added
   `git pull --rebase` before every deploy job's `git push` - same fix
   already used in the Argo Rollouts project's workflow, just missed here
   the first time.

First fully green run reached the `uat-promotion` gate for real - verified
via `gh api .../pending_deployments` (`current_user_can_approve: true`) and
by confirming `ace-uat`'s Deployment was still on the untouched base image
at that point, before anyone clicked Approve.

## Client demo script

### Developer commit → pipeline

Make a small, visible change on `main` (e.g. bump a response field or
message text in `customerEnquiryAPI/postEnquiry_customerEnqAPI.esql`),
push, and watch `.github/workflows/ace-cicd.yml` run end to end.

### Version promotion via branches

`git checkout v2.0.0 -- customerEnquiryAPI && git commit ... && git push`
onto `main` to demonstrate promoting a specific pre-built version through
the same pipeline (mirrors the existing Jenkins job's `VERSION` parameter
choices, just via a real git operation instead of a dropdown).

### Drift detection + self-healing

```bash
kubectl scale deployment/customerenquiry-api -n ace-dev --replicas=5
# ArgoCD's ace-customerenquiry-dev Application flips to OutOfSync within
# seconds (selfHeal watches the live state) - watch it revert replicas back
# to what's in Git on its own, no human action needed.
argocd app get ace-customerenquiry-dev --server 10.110.112.200:80 --plaintext --grpc-web --grpc-web-root-path argocd
```

### End-to-end validation

```bash
curl -sk https://ai-poc-ingress:31083/ace-dev/customerenquiryapi/v1/enquiry \
  -H 'Content-Type: application/json' -d '{"customerId":"1001"}'
```

## Future enhancements

### Per-environment automated testing, without forking the code

Today's gate is one scripted assertion per environment (`ci/scripts/smoke-test.sh`):
POST a known request, check the response. Two real problems to solve before
that becomes a genuine per-environment test suite:

1. **The image must stay byte-identical across DEV/SIT/UAT** (that's the
   entire point of one Helm chart + three `values-<env>.yaml` files - see
   the pipeline explainer artifact's Part 3). So any behavioral difference
   between environments - and there will be one, since **lower environments
   normally can't reach what higher environments reach** (a stub in DEV vs.
   a real core-banking system in UAT) - can never live in the ESQL/BAR. It
   has to live in configuration the pod picks up at start-up, not in code
   that gets recompiled per environment.

2. **Externalize the downstream endpoint, not the code.** For ACE this
   means either:
   - `mqsicreateconfigurableservice` / a policy project + `server.conf.yaml`
     override read at start-up, or
   - plain environment variables the message flow reads via `Environment.*`
     ESQL built-ins,

   set per environment via a `ConfigMap`/`Secret` added alongside each
   `values-<env>.yaml` in the Helm chart - `ace-dev`/`ace-sit` mount a
   ConfigMap pointing at a small stub service (seeded with fixed,
   deterministic responses - a lightweight WireMock-style container is
   enough), `ace-uat` mounts one pointing at the real system with
   UAT-scoped credentials. Same image, same BAR, different config mount.

3. **A per-environment test data set**, not one hardcoded `customerId`.
   Add `tests/<env>/cases.json` - request/expected-response pairs matching
   what *that* environment's stub or real system actually returns - and a
   `ci/scripts/run-tests.sh <env>` that iterates over them. It's a drop-in
   replacement for `smoke-test.sh` in each deploy job, not a parallel
   system: same call site, more assertions, environment-aware data.

This is the same principle already applied to the image tag (never baked
in, always injected via the environment's own values file) extended to
everything else that differs between environments - endpoints,
credentials, and now expected test outcomes.

### Canary releases with Argo Rollouts

The Argo Rollouts project earlier in this work used **Blue-Green** - build
the new version fully, then cut traffic over in one atomic move. **Canary**
is Argo Rollouts' other strategy: shift a small, growing percentage of real
traffic to the new version and watch it before shifting more, instead of an
all-or-nothing switch. It's a direct drop-in for this project's current
plain `Deployment` - the same `ingress-nginx` already fronting `ace-dev`/
`ace-sit`/`ace-uat` is exactly what Argo Rollouts' nginx traffic-routing
integration drives; nothing new to install.

Mechanically: convert `templates/deployment.yaml`'s `kind: Deployment` to
`kind: Rollout` (`argoproj.io/v1alpha1`), point it at a `stableService` and
a `canaryService`, and let Argo Rollouts manage the ingress's
`canary-weight` annotation directly:

```yaml
strategy:
  canary:
    stableService: customerenquiry-api-stable
    canaryService: customerenquiry-api-canary
    trafficRouting:
      nginx:
        stableIngress: customerenquiry-api
    steps:
      - setWeight: 20
      - pause: {}                 # manual gate, same GitHub Environment pattern as UAT today
      - setWeight: 50
      - pause: {duration: 5m}      # or an automated AnalysisTemplate checking error rate
      - setWeight: 100
```

Each `pause` is a natural place to run the Part-above test suite against
just the canary slice before it takes more traffic, or to `kubectl argo
rollouts abort` and send 100% back to the stable version instantly if
something looks wrong. All of the RBAC, ArgoCD Application, and GitOps
plumbing already built for this project carries over unchanged - only the
workload kind and the ingress annotations change.
