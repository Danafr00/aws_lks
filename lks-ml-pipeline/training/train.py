"""
SageMaker XGBoost training wrapper for PayTech fraud detection.

Usage:
  python train.py --train          # run training job
  python train.py --deploy         # deploy endpoint from latest job
  python train.py --delete         # delete endpoint
"""

import argparse
import json
import os
import boto3
import sagemaker
from sagemaker.inputs import TrainingInput
from sagemaker.estimator import Estimator

REGION = os.environ.get("AWS_DEFAULT_REGION", "ap-southeast-1")
ACCOUNT_ID = boto3.client("sts").get_caller_identity()["Account"]
ROLE_NAME = "LKS-SageMakerRole"
ENDPOINT_NAME = "lks-paytech-endpoint"
DATA_BUCKET = f"lks-paytech-processed-{ACCOUNT_ID}"
MODEL_BUCKET = f"lks-paytech-processed-{ACCOUNT_ID}"

sm_client = boto3.client("sagemaker", region_name=REGION)
session = sagemaker.Session(boto_session=boto3.Session(region_name=REGION))
role_arn = boto3.client("iam").get_role(RoleName=ROLE_NAME)["Role"]["Arn"]


def train():
    image_uri = sagemaker.image_uris.retrieve(
        framework="xgboost",
        region=REGION,
        version="1.7-1",
        image_scope="training",
        instance_type="ml.m5.xlarge",
    )

    estimator = Estimator(
        image_uri=image_uri,
        role=role_arn,
        instance_count=1,
        instance_type="ml.m5.xlarge",
        output_path=f"s3://{MODEL_BUCKET}/models/",
        sagemaker_session=session,
        hyperparameters={
            "objective": "binary:logistic",
            "num_round": "150",
            "max_depth": "5",
            "eta": "0.2",
            "subsample": "0.8",
            "colsample_bytree": "0.8",
            "eval_metric": "auc",
            "scale_pos_weight": "4",
        },
    )

    train_input = TrainingInput(
        s3_data=f"s3://{DATA_BUCKET}/training/train.csv",
        content_type="text/csv",
    )
    val_input = TrainingInput(
        s3_data=f"s3://{DATA_BUCKET}/training/validation.csv",
        content_type="text/csv",
    )

    estimator.fit({"train": train_input, "validation": val_input}, wait=True)

    with open("/tmp/training_job_name.txt", "w") as f:
        f.write(estimator.latest_training_job.name)

    print(f"Training complete: {estimator.latest_training_job.name}")
    return estimator


def deploy():
    with open("/tmp/training_job_name.txt") as f:
        job_name = f.read().strip()

    job = sm_client.describe_training_job(TrainingJobName=job_name)
    model_data = job["ModelArtifacts"]["S3ModelArtifacts"]

    image_uri = sagemaker.image_uris.retrieve(
        framework="xgboost",
        region=REGION,
        version="1.7-1",
        image_scope="inference",
        instance_type="ml.m5.large",
    )

    model = sagemaker.Model(
        image_uri=image_uri,
        model_data=model_data,
        role=role_arn,
        sagemaker_session=session,
    )

    predictor = model.deploy(
        initial_instance_count=1,
        instance_type="ml.m5.large",
        endpoint_name=ENDPOINT_NAME,
    )

    print(f"Endpoint deployed: {ENDPOINT_NAME}")
    print("⚠️  Remember to delete when done: python train.py --delete")
    return predictor


def delete_endpoint():
    sm_client.delete_endpoint(EndpointName=ENDPOINT_NAME)
    print(f"Endpoint {ENDPOINT_NAME} deleted")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--train", action="store_true")
    parser.add_argument("--deploy", action="store_true")
    parser.add_argument("--delete", action="store_true")
    args = parser.parse_args()

    if args.train:
        train()
    elif args.deploy:
        deploy()
    elif args.delete:
        delete_endpoint()
    else:
        print("Use --train, --deploy, or --delete")
