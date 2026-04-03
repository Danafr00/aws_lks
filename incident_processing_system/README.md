# 🚀 Event-Driven Incident Processing System (Serverless AWS)

---

## 📌 Overview

This project implements a **fully serverless, event-driven incident processing system** using AWS.

Users upload incident data via a web interface, and the system automatically:

1. Stores the file in S3
2. Triggers a workflow using EventBridge
3. Processes the incident using Step Functions
4. Sends alerts for high-severity incidents
5. Stores results in DynamoDB

---

## 🧠 Architecture

```mermaid
flowchart TD

A[User] --> B[Amplify Web App]

B --> C[API Gateway]
C --> D[Lambda: Generate Presigned URL]

D --> B
B --> E[S3 Upload]

E --> F[EventBridge]
F --> G[Step Functions]

G --> H[Lambda: Read S3]
H --> I{Severity Check}

I -->|HIGH| J[Lambda: Send Alert]
I -->|LOW| K[Lambda: Log Only]

J --> L[SNS Notification]
K --> M[S3 Logs]

J --> N[DynamoDB]
K --> N
```

---

## 🔄 Workflow

1. User uploads JSON file via frontend
2. API Gateway generates a presigned S3 upload URL
3. File is uploaded directly to S3
4. S3 triggers EventBridge
5. EventBridge starts Step Functions
6. Step Functions:

   * Reads file from S3
   * Checks severity
   * Sends alert (if HIGH)
   * Logs data
   * Saves to DynamoDB

---

## 📁 Project Structure

```bash
incident-system/
│
├── frontend/
│   └── index.html
│
├── lambda/
│   ├── generate_url.py
│   ├── read_s3.py
│   ├── alert.py
│   ├── log.py
│   └── save.py
│
├── stepfunctions/
│   └── state_machine.json
│
└── sample_event.json
```

---

## 💻 Lambda Functions

---

### 1️⃣ Generate Presigned URL

📄 `lambda/generate_url.py`

---

### 2️⃣ Read File from S3

📄 `lambda/read_s3.py`


### 3️⃣ Send Alert (SNS)

📄 `lambda/alert.py`


---

### 4️⃣ Log to S3

📄 `lambda/log.py`


---

### 5️⃣ Save to DynamoDB

📄 `lambda/save.py`


## 🧩 Step Functions

📄 `stepfunctions/state_machine.json`


---

## 🌐 Frontend (Amplify)

📄 `frontend/index.html`



## ⚙️ Setup Guide

---

### 1️⃣ Create S3 Buckets

```text
incident-input-bucket
incident-logs
```

Enable:

```
Send notifications to EventBridge
```

**Disable Block Public Access** on `incident-input-bucket`:

```
S3 → incident-input-bucket → Permissions → Block public access → Edit → Uncheck all → Save
```

**Add CORS policy** on `incident-input-bucket`:

```
S3 → incident-input-bucket → Permissions → Cross-origin resource sharing (CORS) → Edit
```

Paste:

```json
[
  {
    "AllowedHeaders": ["*"],
    "AllowedMethods": ["PUT", "OPTIONS"],
    "AllowedOrigins": ["*"],
    "ExposeHeaders": []
  }
]
```

---

### 2️⃣ Create DynamoDB

```text
Table: incident-table
Partition key: id
```

---

### 3️⃣ Create SNS

* Create topic
* Subscribe email

---

### 4️⃣ Create Lambda Functions

Upload all scripts

Add IAM permissions:

```
S3FullAccess
SNSFullAccess
DynamoDBFullAccess
```

---

### 4.5️⃣ Create IAM Role for Step Functions

* Create a new IAM role with trust policy for `states.amazonaws.com`
* Attach inline policy:

```json
{
  "Effect": "Allow",
  "Action": "lambda:InvokeFunction",
  "Resource": [
    "arn:aws:lambda:REGION:ACCOUNT_ID:function:read_s3",
    "arn:aws:lambda:REGION:ACCOUNT_ID:function:alert",
    "arn:aws:lambda:REGION:ACCOUNT_ID:function:log",
    "arn:aws:lambda:REGION:ACCOUNT_ID:function:save"
  ]
}
```

* Attach this role when creating the Step Functions state machine

---

### 5️⃣ Create API Gateway

* HTTP API
* Route:

```
GET /generate-url
```

* Integration:

```
Lambda → generate_url
```

**Enable CORS** with these values:

```
Access-Control-Allow-Origin:  *
Access-Control-Allow-Headers: *
Access-Control-Allow-Methods: GET, OPTIONS
```

---

### 6️⃣ Create Step Functions

* Paste JSON
* Replace Lambda ARNs

---

### 7️⃣ Create EventBridge Rule

Event pattern:

```json
{
  "source": ["aws.s3"],
  "detail-type": ["Object Created"],
  "detail": {
    "bucket": {
      "name": ["incident-input-bucket"]
    }
  }
}
```

Target:

```
Step Functions
```

Create a new IAM role for EventBridge with permission to start the state machine:

```json
{
  "Effect": "Allow",
  "Action": "states:StartExecution",
  "Resource": "arn:aws:states:REGION:ACCOUNT_ID:stateMachine:YOUR_STATE_MACHINE_NAME"
}
```

Attach this role to the EventBridge rule target.

---

### 8️⃣ Deploy Frontend

* Upload to Amplify
* Replace API URL

---

## 🧪 Testing

Upload:

`sample_event.json`

---

## 🎯 Expected Flow

```
Upload file
→ S3
→ EventBridge
→ Step Functions
→ Read S3
→ Branch (HIGH/LOW)
→ Alert / Log
→ Save to DynamoDB
```

---

## ⚠️ Common Issues

* EventBridge not enabled in S3
* Wrong bucket name in rule
* Lambda missing permissions
* Invalid JSON format
* CORS error on S3 PUT — presigned URL uses wrong endpoint: make sure `generate_url.py` uses `signature_version='s3v4'` and the correct `region_name`, otherwise boto3 generates a SigV2 URL pointing to `s3.amazonaws.com` instead of the regional endpoint and the browser preflight fails
* CORS error on S3 PUT — missing S3 CORS policy: add the CORS config to `incident-input-bucket` as shown in Step 1

---

## 🏁 Conclusion

This project demonstrates a **real-world event-driven architecture** using AWS serverless services, suitable for:

* LKS Cloud Computing competition
* Portfolio projects
* Learning advanced cloud patterns

---
