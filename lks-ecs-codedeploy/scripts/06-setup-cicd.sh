#!/bin/bash
set -e

ACCOUNT_ID="547849081977"
REGION="us-east-1"
LAB_ROLE="arn:aws:iam::547849081977:role/LabRole"
PROJECT="nusantara-shop"
REPO_NAME="nusantara-shop-app"
PIPELINE_BUCKET="lks-nusantara-pipeline-$ACCOUNT_ID"
PIPELINE_DIR="$(dirname "$0")/../pipeline"

ALB_ARN="${ALB_ARN:-$(aws elbv2 describe-load-balancers \
  --names "lks-nusantara-alb" \
  --region "$REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)}"
TG_BLUE_ARN="${TG_BLUE_ARN:-$(aws elbv2 describe-target-groups \
  --names "lks-nusantara-tg-blue" \
  --region "$REGION" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)}"
TG_GREEN_ARN="${TG_GREEN_ARN:-$(aws elbv2 describe-target-groups \
  --names "lks-nusantara-tg-green" \
  --region "$REGION" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)}"
LISTENER_PROD_ARN="${LISTENER_PROD_ARN:-$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" --region "$REGION" \
  --query "Listeners[?Port==\`80\`].ListenerArn" --output text)}"
LISTENER_TEST_ARN="${LISTENER_TEST_ARN:-$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" --region "$REGION" \
  --query "Listeners[?Port==\`8080\`].ListenerArn" --output text)}"

echo "=== Layer 6: CodeCommit + CodePipeline + CodeDeploy ==="

# Create S3 artifact bucket
echo "[1/6] Creating pipeline artifact bucket..."
aws s3api create-bucket \
  --bucket "$PIPELINE_BUCKET" \
  --region "$REGION" \
  2>/dev/null || echo "  Artifact bucket already exists, skipping..."

aws s3api put-bucket-versioning \
  --bucket "$PIPELINE_BUCKET" \
  --versioning-configuration Status=Enabled

# Create CodeCommit repository
echo "[2/6] Creating CodeCommit repository..."
REPO_URL=$(aws codecommit create-repository \
  --repository-name "$REPO_NAME" \
  --repository-description "NusantaraShop CI/CD source repo" \
  --region "$REGION" \
  --tags Project=$PROJECT,Environment=production,ManagedBy=LKS-Team \
  --query 'repositoryMetadata.cloneUrlHttp' --output text 2>/dev/null) || \
REPO_URL=$(aws codecommit get-repository \
  --repository-name "$REPO_NAME" \
  --region "$REGION" \
  --query 'repositoryMetadata.cloneUrlHttp' --output text)

echo "  Repo URL: $REPO_URL"

# Create CodeDeploy application
echo "[3/6] Creating CodeDeploy application..."
aws deploy create-application \
  --application-name "lks-nusantara-app" \
  --compute-platform ECS \
  --region "$REGION" \
  --tags Key=Project,Value=$PROJECT Key=Environment,Value=production Key=ManagedBy,Value=LKS-Team \
  2>/dev/null || echo "  CodeDeploy app already exists, skipping..."

# Create CodeDeploy deployment group
echo "[4/6] Creating CodeDeploy deployment group (Blue/Green)..."
aws deploy create-deployment-group \
  --application-name "lks-nusantara-app" \
  --deployment-group-name "lks-nusantara-dg" \
  --service-role-arn "$LAB_ROLE" \
  --deployment-config-name "CodeDeployDefault.ECSAllAtOnce" \
  --ecs-services "[{\"serviceName\":\"nusantara-shop-svc\",\"clusterName\":\"lks-nusantara-cluster\"}]" \
  --load-balancer-info "{
    \"targetGroupPairInfoList\": [{
      \"targetGroups\": [
        {\"name\": \"lks-nusantara-tg-blue\"},
        {\"name\": \"lks-nusantara-tg-green\"}
      ],
      \"prodTrafficRoute\": {\"listenerArns\": [\"$LISTENER_PROD_ARN\"]},
      \"testTrafficRoute\": {\"listenerArns\": [\"$LISTENER_TEST_ARN\"]}
    }]
  }" \
  --blue-green-deployment-configuration "{
    \"terminateBlueInstancesOnDeploymentSuccess\": {
      \"action\": \"TERMINATE\",
      \"terminationWaitTimeInMinutes\": 5
    },
    \"deploymentReadyOption\": {
      \"actionOnTimeout\": \"CONTINUE_DEPLOYMENT\",
      \"waitTimeInMinutes\": 0
    }
  }" \
  --auto-rollback-configuration "enabled=true,events=DEPLOYMENT_FAILURE" \
  --region "$REGION" \
  --tags Key=Project,Value=$PROJECT Key=Environment,Value=production Key=ManagedBy,Value=LKS-Team \
  2>/dev/null || echo "  Deployment group already exists, skipping..."

# Package and upload pipeline artifacts to S3 (initial source bundle)
echo "[5/6] Uploading initial pipeline source bundle to S3..."
TEMP_BUNDLE=$(mktemp -d)
cp "$PIPELINE_DIR/appspec.yaml" "$TEMP_BUNDLE/"
cp "$PIPELINE_DIR/taskdef.json" "$TEMP_BUNDLE/"
cp "$PIPELINE_DIR/imageDetail.json" "$TEMP_BUNDLE/"

cd "$TEMP_BUNDLE"
zip -q pipeline-bundle.zip appspec.yaml taskdef.json imageDetail.json
aws s3 cp pipeline-bundle.zip "s3://$PIPELINE_BUCKET/source/pipeline-bundle.zip" --region "$REGION"
cd -
rm -rf "$TEMP_BUNDLE"

# Create CodePipeline
echo "[6/6] Creating CodePipeline..."
aws codepipeline create-pipeline \
  --pipeline "{
    \"name\": \"lks-nusantara-pipeline\",
    \"roleArn\": \"$LAB_ROLE\",
    \"artifactStore\": {
      \"type\": \"S3\",
      \"location\": \"$PIPELINE_BUCKET\"
    },
    \"stages\": [
      {
        \"name\": \"Source\",
        \"actions\": [{
          \"name\": \"Source\",
          \"actionTypeId\": {
            \"category\": \"Source\",
            \"owner\": \"AWS\",
            \"provider\": \"CodeCommit\",
            \"version\": \"1\"
          },
          \"configuration\": {
            \"RepositoryName\": \"$REPO_NAME\",
            \"BranchName\": \"main\",
            \"PollForSourceChanges\": \"true\"
          },
          \"outputArtifacts\": [{\"name\": \"SourceArtifact\"}],
          \"runOrder\": 1
        }]
      },
      {
        \"name\": \"Deploy\",
        \"actions\": [{
          \"name\": \"Deploy\",
          \"actionTypeId\": {
            \"category\": \"Deploy\",
            \"owner\": \"AWS\",
            \"provider\": \"CodeDeployToECS\",
            \"version\": \"1\"
          },
          \"configuration\": {
            \"ApplicationName\": \"lks-nusantara-app\",
            \"DeploymentGroupName\": \"lks-nusantara-dg\",
            \"TaskDefinitionTemplateArtifact\": \"SourceArtifact\",
            \"TaskDefinitionTemplatePath\": \"taskdef.json\",
            \"AppSpecTemplateArtifact\": \"SourceArtifact\",
            \"AppSpecTemplatePath\": \"appspec.yaml\",
            \"Image1ArtifactName\": \"SourceArtifact\",
            \"Image1ContainerName\": \"IMAGE1_NAME\"
          },
          \"inputArtifacts\": [{\"name\": \"SourceArtifact\"}],
          \"runOrder\": 1
        }]
      }
    ]
  }" \
  --region "$REGION" \
  --tags key=Project,value=$PROJECT key=Environment,value=production key=ManagedBy,value=LKS-Team \
  2>/dev/null || echo "  Pipeline already exists, skipping..."

echo ""
echo "=== Layer 6 Complete ==="
echo "CodeCommit repo: $REPO_URL"
echo "Pipeline: lks-nusantara-pipeline"
echo "CodeDeploy app: lks-nusantara-app"
echo "CodeDeploy DG: lks-nusantara-dg"
echo ""
echo "Next: Clone the repo, add pipeline files, push to trigger deployment"
echo "git clone $REPO_URL"
echo ""
echo "Checkpoint:"
aws codepipeline get-pipeline-state \
  --name "lks-nusantara-pipeline" \
  --region "$REGION" \
  --query 'stageStates[*].{Stage:stageName,Status:latestExecution.status}' \
  --output table 2>/dev/null || echo "  Pipeline will show status after first run"
