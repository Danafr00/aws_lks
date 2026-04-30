# LKS Lab — Simple EKS App with ALB

**Difficulty**: ★★★☆☆  
**Time**: ~1 hour  
**Region**: ap-southeast-1

---

## Background

A startup wants to run a simple web application on Kubernetes using Amazon EKS. The application must be publicly accessible via an Application Load Balancer (ALB). You are tasked with setting up the cluster, deploying the application, and exposing it to the internet.

---

## Architecture

```
Internet → ALB → EKS (2 nginx pods) ← AWS Load Balancer Controller
```

---

## Tasks

1. Create an EKS cluster named `lks-simple-eks` with 2 managed `t3.small` nodes in `ap-southeast-1`.
2. Install the **AWS Load Balancer Controller** using Helm and IRSA.
3. Deploy the provided nginx application (`k8s/` directory) to the `default` namespace.
4. Expose the application via an ALB Ingress with `internet-facing` scheme and `ip` target type.
5. Verify the app is accessible via the ALB DNS name (HTTP port 80).

---

## Deliverables

- ALB DNS name that returns HTTP 200 with the Hello EKS page.
- All pods in `Running` state.
- LBC controller in `Ready` state.

---

## Answer Key

See [`step-by-step.md`](./step-by-step.md) for the complete CLI walkthrough.

---

## Cost Warning

| Resource | Cost |
|---|---|
| EKS control plane | $0.10/hr |
| 2x t3.small EC2 | ~$0.042/hr |
| ALB | ~$0.008/hr + LCU |

**Delete all resources after the lab** using the cleanup commands in `step-by-step.md`.
