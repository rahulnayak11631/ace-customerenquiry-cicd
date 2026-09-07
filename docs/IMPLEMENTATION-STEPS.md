# Implementation runbook

Written as the work actually happens. Cluster: same `ai-poc` kubeadm cluster
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

*(pending - extract 3 zips into v1.0.0/v2.0.0/v3.0.0 branches, main from v1,
create the GitHub repo public, push)*

## 2. Cluster setup

*(pending - ace-dev/ace-sit/ace-uat namespaces, copy ingress-tls + regcred,
apply ace-ci-deployer RBAC)*

## 3. SonarQube token

*(pending)*

## 4. ArgoCD ace-ci account + Applications

*(pending)*

## 5. Self-hosted runner (2nd one on worker-02)

*(pending - sonar-scanner CLI install, runner registration)*

## 6. GitHub secrets + uat-promotion Environment

*(pending)*

## 7. First run + verification

*(pending)*

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
