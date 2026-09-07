# ACE customerEnquiryAPI CI/CD + GitOps POC

A real IBM ACE REST API (`POST /customerenquiryapi/v1/enquiry`) taken all
the way through: Git commit → BAR build → basic validation → SonarQube →
container image → Trivy → Docker Hub → GitOps (ArgoCD) → DEV → SIT → **manual
approval** → UAT.

See [`docs/IMPLEMENTATION-STEPS.md`](docs/IMPLEMENTATION-STEPS.md) for the
full build runbook and the client-demo script (including the drift/self-heal
and developer-commit demo steps).

## Layout

- `customerEnquiryAPI/` — the ACE application source (Toolkit-exported:
  `.msgflow`, `.esql`, `restapi.descriptor`, `swagger.json`). Branches
  `v1.0.0`/`v2.0.0`/`v3.0.0` hold each provided snapshot; `main` is where the
  live pipeline runs from.
- `docker/Dockerfile` — layers a freshly-built BAR onto the already-published
  `rahulnayak11631/customerenqapi:main-7` base image (which itself bakes in
  the full ACE 13.0.8.0 runtime) - no re-installing ACE on every build.
- `charts/customerenquiry-api/` — one Helm chart, three per-environment
  `values-{dev,sit,uat}.yaml` overrides (image tag + ingress path only).
- `argocd/` — the three ArgoCD `Application` objects (one per environment).
- `ci/` — RBAC for the CI runner's scoped kubeconfig, and the shell scripts
  the pipeline uses to wait for a healthy rollout and smoke-test the API.
- `.github/workflows/ace-cicd.yml` — the pipeline itself.

## How a build flows

1. Push to `main` (or `workflow_dispatch`) builds the BAR with `ibmint
   package`, validates it's a real archive containing the app, runs
   SonarQube (with a quality gate), builds + Trivy-scans the image, and
   pushes it to Docker Hub tagged with the git short SHA.
2. **DEV**: bumps `values-dev.yaml`'s image tag, pushes, triggers an
   immediate `argocd app sync`, waits for the Deployment to roll out, then
   smoke-tests the real endpoint through the shared ingress.
3. **SIT**: identical shape, runs automatically once DEV's smoke test
   passes.
4. **UAT**: gated. The job pauses on GitHub's `uat-promotion` Environment —
   an email goes to the required reviewer, who must click **Approve** in
   the Actions UI before UAT is ever touched. Reject it and UAT stays
   untouched, no different from an automated failure.

## Access

- DEV: `https://ai-poc-ingress:31083/ace-dev/customerenquiryapi/v1/enquiry`
- SIT: `https://ai-poc-ingress:31083/ace-sit/customerenquiryapi/v1/enquiry`
- UAT: `https://ai-poc-ingress:31083/ace-uat/customerenquiryapi/v1/enquiry`

Example request:
```bash
curl -sk https://ai-poc-ingress:31083/ace-dev/customerenquiryapi/v1/enquiry \
  -H 'Content-Type: application/json' -d '{"customerId":"1001"}'
```
