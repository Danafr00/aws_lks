import math
import os
import json
import boto3
from datetime import datetime, timezone
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

ENDPOINT_NAME = os.environ["SAGEMAKER_ENDPOINT_NAME"]
DYNAMODB_TABLE = os.environ["DYNAMODB_TABLE"]
RESULTS_BUCKET = os.environ["RESULTS_BUCKET"]
AWS_REGION = os.environ.get("AWS_DEFAULT_REGION", "ap-southeast-1")

sagemaker_runtime = boto3.client("sagemaker-runtime", region_name=AWS_REGION)
dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
s3 = boto3.client("s3", region_name=AWS_REGION)

table = dynamodb.Table(DYNAMODB_TABLE)

MERCHANT_ENCODING = {
    "grocery": 0,
    "electronics": 1,
    "restaurant": 2,
    "gas": 3,
    "travel": 4,
    "online": 5,
}


@asynccontextmanager
async def lifespan(app: FastAPI):
    print(f"Inference server started — endpoint: {ENDPOINT_NAME}")
    yield
    print("Inference server shutting down")


app = FastAPI(title="PayTech Fraud Detection API", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class TransactionRequest(BaseModel):
    transaction_id: str = Field(..., description="Unique transaction identifier")
    amount: float = Field(..., gt=0, description="Transaction amount in IDR")
    merchant_category: str = Field(..., description="grocery/electronics/restaurant/gas/travel/online")
    hour_of_day: int = Field(..., ge=0, le=23)
    day_of_week: int = Field(..., ge=0, le=6, description="0=Monday, 6=Sunday")
    user_account_age_days: int = Field(..., ge=0)
    previous_fraud_count: int = Field(..., ge=0)
    distance_from_home_km: float = Field(..., ge=0)
    is_foreign_transaction: int = Field(..., ge=0, le=1)
    transaction_frequency_24h: int = Field(..., ge=1)


class PredictionResponse(BaseModel):
    transaction_id: str
    fraud_score: float
    label: str
    confidence: str
    timestamp: str


def build_feature_vector(req: TransactionRequest) -> str:
    merchant_enc = MERCHANT_ENCODING.get(req.merchant_category.lower(), 5)
    features = [
        math.log1p(req.amount),
        merchant_enc,
        req.hour_of_day,
        req.day_of_week,
        req.user_account_age_days,
        req.previous_fraud_count,
        math.log1p(req.distance_from_home_km),
        req.is_foreign_transaction,
        req.transaction_frequency_24h,
    ]
    return ",".join(str(f) for f in features)


def classify(score: float) -> tuple[str, str]:
    if score >= 0.7:
        return "FRAUD", "HIGH"
    elif score >= 0.3:
        return "FRAUD", "MEDIUM"
    elif score >= 0.15:
        return "NORMAL", "LOW"
    else:
        return "NORMAL", "HIGH"


@app.get("/health")
async def health():
    return {"status": "ok", "endpoint": ENDPOINT_NAME}


@app.post("/predict", response_model=PredictionResponse)
async def predict(req: TransactionRequest):
    feature_csv = build_feature_vector(req)

    try:
        response = sagemaker_runtime.invoke_endpoint(
            EndpointName=ENDPOINT_NAME,
            ContentType="text/csv",
            Body=feature_csv,
        )
        fraud_score = float(response["Body"].read().decode("utf-8").strip())
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"Model endpoint error: {e}")

    label, confidence = classify(fraud_score)
    timestamp = datetime.now(timezone.utc).isoformat()

    result = PredictionResponse(
        transaction_id=req.transaction_id,
        fraud_score=round(fraud_score, 4),
        label=label,
        confidence=confidence,
        timestamp=timestamp,
    )

    # Save to DynamoDB
    try:
        table.put_item(Item={
            "transaction_id": req.transaction_id,
            "timestamp": timestamp,
            "fraud_score": str(round(fraud_score, 4)),
            "label": label,
            "confidence": confidence,
            "amount": str(req.amount),
            "merchant_category": req.merchant_category,
        })
    except Exception as e:
        print(f"DynamoDB write failed: {e}")

    # Save to S3 results bucket
    try:
        s3_key = f"predictions/{timestamp[:10]}/{req.transaction_id}.json"
        s3.put_object(
            Bucket=RESULTS_BUCKET,
            Key=s3_key,
            Body=json.dumps(result.model_dump()).encode("utf-8"),
            ContentType="application/json",
        )
    except Exception as e:
        print(f"S3 write failed: {e}")

    return result
