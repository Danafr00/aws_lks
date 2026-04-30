#!/usr/bin/env python3
"""
Train and deploy the XGBoost loan-default model on SageMaker.

Prerequisites:
    pip install sagemaker boto3
    export AWS_REGION=ap-southeast-1

Usage:
    python train_deploy.py           # train + deploy
    python train_deploy.py --train   # train only, print model artifacts path
    python train_deploy.py --deploy  # deploy existing model (prompts for model path)
    python train_deploy.py --delete  # delete the endpoint (cost-saving)
"""
import boto3
import sagemaker
from sagemaker import image_uris
from sagemaker.estimator import Estimator
from sagemaker.inputs import TrainingInput
import os
import sys
import time

REGION = os.environ.get('AWS_REGION', 'ap-southeast-1')
ACCOUNT_ID = boto3.client('sts', region_name=REGION).get_caller_identity()['Account']

DATA_BUCKET = f'lks-sagemaker-data-{ACCOUNT_ID}'
MODEL_BUCKET = f'lks-sagemaker-models-{ACCOUNT_ID}'
ROLE_ARN = f'arn:aws:iam::{ACCOUNT_ID}:role/LKS-SageMakerRole'
ENDPOINT_NAME = 'lks-loan-risk-endpoint'

boto_session = boto3.Session(region_name=REGION)
sm_session = sagemaker.Session(boto_session=boto_session)

TAGS = [
    {'Key': 'Project', 'Value': 'nusantara-fincredit'},
    {'Key': 'Environment', 'Value': 'production'},
    {'Key': 'ManagedBy', 'Value': 'LKS-Team'},
]


def train():
    print(f"==> Region:  {REGION}")
    print(f"==> Account: {ACCOUNT_ID}")
    print(f"==> Role:    {ROLE_ARN}")

    container = image_uris.retrieve('xgboost', REGION, '1.7-1')
    print(f"==> XGBoost image: {container}")

    estimator = Estimator(
        image_uri=container,
        role=ROLE_ARN,
        instance_count=1,
        instance_type='ml.m5.xlarge',
        volume_size=10,
        max_run=600,
        output_path=f's3://{MODEL_BUCKET}/model-output/',
        sagemaker_session=sm_session,
        tags=TAGS,
    )

    estimator.set_hyperparameters(
        objective='binary:logistic',
        num_round=150,
        max_depth=5,
        eta=0.2,
        subsample=0.8,
        colsample_bytree=0.8,
        min_child_weight=1,
        eval_metric='auc',
        scale_pos_weight=3,   # compensate for 25% positive-class imbalance
    )

    train_input = TrainingInput(
        s3_data=f's3://{DATA_BUCKET}/train/',
        content_type='text/csv',
    )
    val_input = TrainingInput(
        s3_data=f's3://{DATA_BUCKET}/validation/',
        content_type='text/csv',
    )

    job_name = f'lks-loan-xgb-{int(time.time())}'
    print(f"\n==> Starting training job: {job_name}")
    estimator.fit(
        inputs={'train': train_input, 'validation': val_input},
        job_name=job_name,
        wait=True,
        logs=True,
    )

    print(f"\n==> Training complete.")
    print(f"    Model artifacts: {estimator.model_data}")
    return estimator


def deploy(estimator=None, model_data=None):
    if estimator is None:
        if model_data is None:
            model_data = input("Enter model artifacts S3 URI (e.g. s3://bucket/model-output/job/output/model.tar.gz): ").strip()
        container = image_uris.retrieve('xgboost', REGION, '1.7-1')
        from sagemaker.model import Model
        model = Model(
            image_uri=container,
            model_data=model_data,
            role=ROLE_ARN,
            sagemaker_session=sm_session,
        )
        predictor = model.deploy(
            initial_instance_count=1,
            instance_type='ml.m5.large',
            endpoint_name=ENDPOINT_NAME,
            tags=TAGS,
        )
    else:
        predictor = estimator.deploy(
            initial_instance_count=1,
            instance_type='ml.m5.large',
            endpoint_name=ENDPOINT_NAME,
            tags=TAGS,
        )

    print(f"\n==> Endpoint live: {ENDPOINT_NAME}")
    print(f"\n    Quick test (low-risk profile):")
    print(f"    aws sagemaker-runtime invoke-endpoint \\")
    print(f"      --endpoint-name {ENDPOINT_NAME} \\")
    print(f"      --content-type text/csv \\")
    print(f"      --body '42,85000,12000,36,720,12,0.22,1,3,0' \\")
    print(f"      --region {REGION} /dev/stdout")
    return predictor


def delete_endpoint():
    sm = boto3.client('sagemaker', region_name=REGION)
    sm.delete_endpoint(EndpointName=ENDPOINT_NAME)
    print(f"==> Endpoint deleted: {ENDPOINT_NAME}")


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else '--all'
    if mode == '--train':
        train()
    elif mode == '--deploy':
        deploy()
    elif mode == '--delete':
        delete_endpoint()
    else:
        estimator = train()
        deploy(estimator=estimator)


if __name__ == '__main__':
    main()
