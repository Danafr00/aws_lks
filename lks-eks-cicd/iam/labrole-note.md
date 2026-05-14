# IAM Note — LabRole

This module uses the pre-existing **LabRole** for all AWS services.
Vocareum lab blocks `iam:CreateRole` and `iam:CreateOpenIDConnectProvider`.

**Role ARN:** `arn:aws:iam::<ACCOUNT_ID>:role/LabRole`

## Blocked IAM Operations (live-confirmed 2026-05-11)

| Operation | Result | Impact |
|---|---|---|
| `iam:CreateRole` | AccessDenied | Cannot create IRSA roles |
| `iam:CreateOpenIDConnectProvider` | AccessDenied | Cannot register GitHub OIDC or EKS OIDC provider |
| `iam:AttachRolePolicy` | AccessDenied | Cannot modify existing roles |

## Services Using LabRole

| Component | Previously-defined role | Now replaced by |
|---|---|---|
| EFS CSI Driver | Custom IRSA role | LabRole (via EC2 node instance profile) |
| Cluster Autoscaler | Custom IRSA role | LabRole (via EC2 node instance profile) |
| External Secrets Operator | Custom IRSA role | LabRole (via EC2 node instance profile) |
| wallet-app pods | Custom IRSA role | LabRole (via EC2 node instance profile) |
| GitHub Actions CI/CD | Custom OIDC role | **Not available** — see workaround below |

## IRSA Workaround

Since `iam:CreateOpenIDConnectProvider` is blocked, IRSA is unavailable.
Pods inherit the EC2 node instance profile (LabRole) automatically.
No `serviceAccountName` annotation needed — LabRole already has the required permissions.

## GitHub Actions Workaround

`iam:CreateOpenIDConnectProvider` blocked → cannot set up GitHub OIDC trust.
**Alternative:** Build Docker image locally, then push to ECR manually:

```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
docker build -t lks-wallet-api .
docker tag lks-wallet-api:latest <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/lks-wallet-api:latest
docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/lks-wallet-api:latest
```

## IAM JSON Files (documentation only)

The `*-trust.json` and `*-policy.json` files describe what permissions each component
logically needs. They are kept as reference documentation but are NOT applied in
the Vocareum lab — LabRole already covers the required permissions for all services.
