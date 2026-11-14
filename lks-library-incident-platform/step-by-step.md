# Step-by-Step – Library Visitor & Incident Platform (AWS web console)

This is the answer key. You build everything in the **AWS web console**. Every action is followed by a **Note** that explains what you just did and why, so you understand the platform instead of only clicking.

You build it in 8 layers. Each layer adds one idea and ends with a **checkpoint**. Do not start the next layer before the checkpoint passes.

## Layer Overview

| Layer | What You Build | Checkpoint |
|---|---|---|
| **1** | RDS + Lambda `insert_visitor` + API `POST /visitor` | `curl` returns 200 and the row is in MySQL |
| **2** | S3 + presigned URL Lambda + API `GET /upload-url` | Upload with `curl` returns 200, the file is in the bucket |
| **3** | S3 → SQS (+DLQ) → Lambda dispatcher + idempotency table | The same file key is claimed only once |
| **4** | Step Functions `Map` + DynamoDB direct integration | A file with 3 incidents gives 3 DynamoDB items |
| **5** | `Parallel` enrichment + `Choice` + SNS alert | Visitor name is stored, HIGH publishes to SNS |
| **6** | Human approval with `waitForTaskToken` | Approve resumes the execution, no answer escalates |
| **7** | Scheduler report + read APIs + Amplify dashboard | The dashboard shows summaries, incidents and approvals |
| **8** | AWS Backup + CloudWatch alarms | A recovery point exists, alarms are created |

---

## Before You Start

- Region: **Asia Pacific (Singapore) `ap-southeast-1`**. Check the region selector (top right) in **every** service. Resources created in another region are invisible and cannot talk to each other.
- Your **suffix**: your name in lowercase letters and digits, for example `dana`. It is added to every resource name (`lks-libinc-<purpose>-<suffix>`).

> **Note**: S3 bucket names are global across all AWS accounts, so a name without your own suffix is probably taken already. In a shared account the suffix also stops you from overwriting a classmate's resources.

- **IAM is already done for you.** Every time a service asks for a role, choose the existing role **`lks_learning_role`** (*Use an existing role*). Do not create roles. Never let the console "create a new role" in this module.

> **Note**: One role is shared by Lambda, Step Functions, EventBridge Scheduler and AWS Backup. It already trusts those five services and holds the permissions this module needs (the exact JSON is in the *Instructor appendix* at the end).

- **CloudShell** (the `>_` icon at the top of the console) is a ready-made terminal in the same region. You will use it for a few commands (`curl`, building one zip). Anywhere below that says `$API`, first run `API=https://<your-api-id>.execute-api.ap-southeast-1.amazonaws.com` in CloudShell, using the invoke URL of **your** API (layer 1).

---

## Layer 1 – Visitor API (RDS + Lambda + API Gateway)

> **What you build**: a visitor is stored in MySQL through an HTTP API.

### Step 1: Create the RDS database

Console: **RDS → Create database**

| Setting | Value |
|---|---|
| Creation method | Standard create |
| Engine | MySQL (latest 8.4) |
| Template | **Free tier** (or Sandbox) |
| DB instance identifier | `lks-libinc-db-<suffix>` |
| Master username | `admin` |
| Credentials management | **Self managed**, set a password of letters and digits (12+ characters) and write it down |
| Instance class | `db.t3.micro` |
| Storage | gp2, 20 GiB, untick *Enable storage autoscaling* |
| Public access | **Yes** |
| VPC security group | **Create new** → name `lks-libinc-rds-sg-<suffix>` |
| Additional configuration → Initial database name | `library` |
| Backup retention | 1 day |
| Deletion protection | untick |
| Tags | `Project=lks-libinc`, `Environment=practice`, `ManagedBy=LKS-Team` |

Press **Create database** and wait until the status is **Available** (about 5–10 minutes).

> **Note**: `db.t3.micro` is the smallest class. **Public access = Yes** gives the database a public IP, so the security group is the only protection. *Initial database name* creates the empty database `library` for you; without it you would have to run `CREATE DATABASE` yourself. Deletion protection is off so you can delete the database when you finish. Put the password somewhere safe now: AWS can never show it again.

### Step 2: Open port 3306

Console: **EC2 → Security Groups →** `lks-libinc-rds-sg-<suffix>` **→ Inbound rules → Edit inbound rules → Add rule**: Type **MySQL/Aurora** (port 3306), Source **Anywhere-IPv4** (`0.0.0.0/0`) → Save.

> **Note**: A security group is the firewall of the database; 3306 is the MySQL port. `0.0.0.0/0` means "the whole internet". It is the simplest way to let your CloudShell **and** Lambda (which is not inside a VPC and has no fixed IP) connect. It is acceptable only in a practice account with a strong password and a short life. Never do this with real data.

### Step 3: Build the `pymysql` Lambda layer (CloudShell)

Open CloudShell and run:

```bash
mkdir -p layer/python && cd layer
pip install pymysql cryptography -t python \
  --platform manylinux2014_x86_64 --python-version 3.11 --implementation cp --only-binary=:all:
zip -q -r pymysql-layer.zip python
ls -lh pymysql-layer.zip
```

Then **Actions → Download file** and enter the path `layer/pymysql-layer.zip`.

> **Note**: Lambda does not include a MySQL driver, so you package one. A *layer* is a zip that Lambda unpacks into `/opt/python`, so many functions can share it. `cryptography` is needed because MySQL 8.4 users log in with `caching_sha2_password`, and `pymysql` needs it when the connection is not encrypted. `cryptography` contains compiled code. CloudShell runs Python 3.9, so the `--platform … --python-version 3.11` options download the build for **Lambda's Python 3.11**; without them the function fails with an import error.

Console: **Lambda → Layers → Create layer**: name `lks-libinc-pymysql-<suffix>`, upload `pymysql-layer.zip`, compatible runtime **Python 3.11**, architecture **x86_64** → Create.

> **Note**: Layers are versioned. You attach a specific version to each function that needs it.

### Step 4: Create the tables

In CloudShell (replace the host with the **Endpoint** shown on your RDS page and the password with yours):

```bash
pip install --user pymysql cryptography -q
python3 - <<'EOF'
import pymysql
conn = pymysql.connect(host="<RDS-ENDPOINT>", user="admin", password="<PASSWORD>", database="library", connect_timeout=10)
cur = conn.cursor()
cur.execute("""CREATE TABLE IF NOT EXISTS visitors (
    id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100) NOT NULL, class VARCHAR(20) NOT NULL,
    purpose VARCHAR(255) NOT NULL, visit_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP)""")
cur.execute("""CREATE TABLE IF NOT EXISTS daily_summary (
    id INT AUTO_INCREMENT PRIMARY KEY, report_date DATE NOT NULL,
    total_visitors INT NOT NULL DEFAULT 0, total_incidents INT NOT NULL DEFAULT 0,
    critical_incidents INT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_report_date (report_date))""")
conn.commit()
cur.execute("SHOW TABLES"); print(cur.fetchall())
EOF
```

> **Note**: This is the same SQL as `sql/schema.sql`. `visitors` stores check-ins. `daily_summary` has a `UNIQUE` key on `report_date`, so the nightly report can run twice for the same day and update the row instead of adding a second one. You should see `(('daily_summary',), ('visitors',))`. Prefer a GUI? DBeaver works too: host = the endpoint, user `admin`, database `library`, and in *Driver properties* set `allowPublicKeyRetrieval=true`.

### Step 5: Create the Lambda `insert-visitor`

Console: **Lambda → Create function → Author from scratch**

| Setting | Value |
|---|---|
| Function name | `lks-libinc-insert-visitor-<suffix>` |
| Runtime | Python 3.11 |
| Execution role | **Use an existing role → `lks_learning_role`** |

1. In the **Code** tab, replace everything in `lambda_function.py` with the content of `app/lambda/insert_visitor.py`, then **Deploy**.
2. **Code → Layers → Add a layer → Custom layers** → your `lks-libinc-pymysql-<suffix>` → Add.
3. **Configuration → Environment variables → Edit**: `DB_HOST` (RDS endpoint), `DB_NAME` = `library`, `DB_USER` = `admin`, `DB_PASS` (your password).
4. **Configuration → General configuration → Edit**: Timeout **15 sec**.

> **Note**: The handler stays `lambda_function.lambda_handler` (file name + function name), which is why the code goes into `lambda_function.py`. Connection details come from environment variables so no password is written in the source code. The default timeout is only 3 seconds, too short for opening a database connection. The function returns `400` for a missing field instead of crashing with `500`.

### Step 6: Create the HTTP API

Console: **API Gateway → Create API → HTTP API → Build**

1. **Add integration → Lambda** → region `ap-southeast-1` → your `insert-visitor` function.
2. API name `lks-libinc-api-<suffix>` → Next.
3. Routes: Method **POST**, Resource path `/visitor`, integration = your Lambda → Next.
4. Stages: keep **`$default`** with **Auto-deploy** on → Next → Create.
5. **Develop → CORS → Configure**: Access-Control-Allow-Origin `*`, Access-Control-Allow-Headers `content-type`, Access-Control-Allow-Methods `GET, POST, OPTIONS` → Save.

> **Note**: An HTTP API is simpler and cheaper than a REST API. The `$default` stage with auto-deploy means the URL has **no stage name in the path**: it is `https://<id>.execute-api.ap-southeast-1.amazonaws.com/visitor`, not `.../prod/visitor`. Calling a path that is not a route (for example the bare stage URL) gives `404 Not Found`. When you attach a Lambda in the console, it also adds the permission that lets API Gateway invoke that function. CORS is needed because the dashboard (on another website) calls this API from a browser; without it the browser blocks the call even though the server answered.

**Layer 1 checkpoint — verify before continuing:**
- [ ] CloudShell: `API=<invoke URL>` then `curl -s -X POST $API/visitor -H 'Content-Type: application/json' -d '{"name":"Budi Santoso","class":"XII RPL 1","purpose":"Reading"}'` → `{"message": "Visitor recorded", "visitor_id": 1}`
- [ ] `curl -s -X POST $API/visitor -d '{}'` → `{"message": "name, class and purpose are required"}` (a clear `400`, not a `500`)
- [ ] The row is in MySQL (rerun the Python from step 4 with `cur.execute("SELECT id,name,class FROM visitors"); print(cur.fetchall())`)

---

## Layer 2 – Upload (S3 + presigned URL)

> **What you build**: a browser can upload an incident file straight to a private bucket.

### Step 1: Create the bucket

Console: **S3 → Create bucket**: name `lks-libinc-incidents-<suffix>`, region Singapore, **Block all public access stays ticked** → Create.

> **Note**: The bucket stays private. The browser will upload with a *presigned URL*, which carries permission by itself, so the bucket never needs to be public and you never need a bucket policy.

### Step 2: Add CORS

Console: bucket → **Permissions → Cross-origin resource sharing (CORS) → Edit**, paste:

```json
[
  {
    "AllowedHeaders": ["*"],
    "AllowedMethods": ["PUT"],
    "AllowedOrigins": ["*"],
    "ExposeHeaders": []
  }
]
```

> **Note**: The browser sends the file straight to S3, which is a different website than your page, so S3 must allow it. Only `PUT` is listed: `OPTIONS` is not a valid value here (S3 rejects the configuration); S3 answers the browser's preflight request by itself once `PUT` is allowed.

### Step 3: Create the Lambda `get-upload-url`

Create the function exactly like layer 1 step 5 (name `lks-libinc-get-upload-url-<suffix>`, role `lks_learning_role`, **no layer needed**), with the code of `app/lambda/get_upload_url.py`, environment variable `BUCKET` = your bucket name, Timeout 10 sec.

> **Note**: A presigned URL is a normal S3 address with a signature in the query string. It allows exactly one action (`PUT` of one key) for 5 minutes, signed with the role of the Lambda. S3 checks that role's `s3:PutObject` permission when the upload arrives and answers `403 AccessDenied` if it is missing; `lks_learning_role` has it. The code builds the S3 client with the **regional endpoint** and virtual addressing: without that, boto3 can produce the global host `bucket.s3.amazonaws.com`, S3 answers `307 Temporary Redirect`, and a browser refuses to follow a redirect during the CORS preflight. The key always starts with `incoming/`, so layer 3 can listen only to that folder.

### Step 4: Add the route

Console: API Gateway → your API → **Routes → Create**: `GET` `/upload-url` → select the new route → **Attach integration → Create and attach an integration** → Lambda → `get-upload-url`.

> **Note**: This route has to be attached to its own integration. A route without an integration returns `500`.

**Layer 2 checkpoint — verify before continuing:**
- [ ] CloudShell: `curl -s $API/upload-url` → JSON with `upload_url` whose host looks like `lks-libinc-incidents-<suffix>.s3.ap-southeast-1.amazonaws.com`
- [ ] Upload with the presigned URL (the quotes matter):
  `URL=$(curl -s $API/upload-url | python3 -c 'import json,sys;print(json.load(sys.stdin)["upload_url"])')` then
  `echo '{"incidents":[]}' > t.json; curl -s -o /dev/null -w "%{http_code}\n" -X PUT "$URL" -H 'Content-Type: application/json' --data-binary @t.json` → `200`
- [ ] S3 console → bucket → folder `incoming/` → one `.json` file

---

## Layer 3 – Queue and dispatcher (S3 → SQS → Lambda)

> **What you build**: every new file in `incoming/` creates a message that a Lambda reads exactly once.

### Step 1: Create the queues

Console: **SQS → Create queue** (type **Standard**) three times:

| Name | Settings |
|---|---|
| `lks-libinc-incident-dlq-<suffix>` | defaults |
| `lks-libinc-failed-items-<suffix>` | defaults |
| `lks-libinc-incident-queue-<suffix>` | **Visibility timeout 3 minutes**; **Dead-letter queue → Enabled** → choose the DLQ, **Maximum receives 3** |

> **Note**: The DLQ (dead-letter queue) collects messages that failed 3 times, so a bad message cannot loop forever. The visibility timeout hides a message while a Lambda works on it; it must be **longer than the Lambda timeout** (30 seconds here, AWS recommends about 6 times), otherwise a second Lambda picks the same message up while the first is still busy. `failed-items` is for layer 4: when one incident fails inside the workflow, it is parked there and the other incidents continue.

### Step 2: Let S3 send messages to the main queue

Console: `lks-libinc-incident-queue-<suffix>` → **Access policy → Edit** → replace with (use your queue ARN, bucket name and 12-digit account id):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "s3.amazonaws.com"},
    "Action": "sqs:SendMessage",
    "Resource": "<QUEUE-ARN>",
    "Condition": {
      "ArnLike": {"aws:SourceArn": "arn:aws:s3:::lks-libinc-incidents-<suffix>"},
      "StringEquals": {"aws:SourceAccount": "<ACCOUNT-ID>"}
    }
  }]
}
```

> **Note**: By default **nobody** may send to a queue except its owner. The next step fails with "Unable to validate the following destination configurations" if this policy is missing. `Principal: s3.amazonaws.com` says "the S3 service"; the two conditions narrow it to *your bucket* in *your account*, so no other bucket can fill your queue. This policy belongs to the queue, not to `lks_learning_role`.

### Step 3: Create the idempotency table

Console: **DynamoDB → Create table**: name `lks-libinc-files-<suffix>`, partition key `file_key` (String), **Customize settings → Capacity mode: On-demand** → Create.

> **Note**: S3 and SQS deliver messages *at least once*, so the same file can arrive twice. The dispatcher writes `file_key` only if it does not exist yet; the first writer wins and starts the workflow, a duplicate is skipped. On-demand means no capacity planning and no cost while idle.

### Step 4: Create the Lambda `dispatcher`

Create the function (name `lks-libinc-dispatcher-<suffix>`, role `lks_learning_role`, no layer), with the code of `app/lambda/dispatcher.py`. Environment variables: `FILES_TABLE` = your files table name and `STATE_MACHINE_ARN` = *empty* (add the variable with an empty value, or leave it out). Timeout **30 sec**.

> **Note**: `STATE_MACHINE_ARN` is empty on purpose: the state machine does not exist yet (layer 4). Until then the function only *claims* the file and logs it, which is enough to test the queue and the idempotency. The code skips the `s3:TestEvent` message S3 sends when you create the notification, and it returns `batchItemFailures`, so only the broken message of a batch goes back to the queue, not all 5.

### Step 5: Connect the queue to the Lambda

Console: Lambda `dispatcher` → **Configuration → Triggers → Add trigger → SQS** → your main queue, **Batch size 5**, expand *Additional settings* and tick **Report batch item failures** → Add.

> **Note**: The trigger is a poller that Lambda runs for you: it reads the queue and invokes the function with up to 5 messages. *Report batch item failures* switches on the partial-failure answer the code uses.

### Step 6: Send S3 events to the queue

Console: bucket → **Properties → Event notifications → Create event notification**: name `new-incident-file`, **Prefix `incoming/`**, Event types **All object create events**, Destination **SQS queue** → your main queue → Save.

> **Note**: The prefix matters: without it, any other file written to the bucket would also create messages. After saving, S3 sends one *test message* to the queue; the dispatcher logs `ignoring non-object message`, which is normal. **A new notification can take a few minutes to start working**: if your first uploads create no messages, wait and upload again.

**Layer 3 checkpoint — verify before continuing:**
- [ ] S3 console → bucket → **Create folder `incoming`** (if it is not there) → **Upload** `data/incidents-valid.json` into it. Wait a minute. DynamoDB → `lks-libinc-files-<suffix>` → **Explore table items** → one row with that key and `status` = `RECEIVED`
- [ ] Upload a file with the **same name** again (it overwrites the same key) → still one row, and the dispatcher log (**Monitor → View CloudWatch logs**) contains `duplicate event for incoming/… skipped`
- [ ] SQS → main queue shows `Messages available: 0` (the messages were consumed)

> **Note**: The key is the idempotency key, so uploading the same file name twice is *skipped by design*. To test again, upload under a **new file name** (or delete the row from the files table).

---

## Layer 4 – Workflow (Step Functions `Map`)

> **What you build**: a state machine validates the file and stores each incident in DynamoDB.

### Step 1: Create the incidents table

Console: **DynamoDB → Create table**: name `lks-libinc-incidents-<suffix>`, partition key `incident_id` (String), **Customize settings → On-demand**. Then, when the table is active, open it → **Indexes → Create index** twice:

| Index name | Partition key | Sort key |
|---|---|---|
| `severity-index` | `severity` (String) | `received_at` (String) |
| `report-date-index` | `report_date` (String) | `received_at` (String) |

Keep *Attribute projections* on **All**.

> **Note**: DynamoDB searches efficiently only by key. The dashboard needs "all HIGH incidents, newest first" and the daily report needs "all incidents of one day". A *global secondary index* (GSI) is a second copy of the table organized by another key, so both questions become a fast `Query` instead of reading the whole table. Only attributes used as a key are declared; every other field is free-form.

### Step 2: Create the `validate` Lambda

Name `lks-libinc-validate-<suffix>`, role `lks_learning_role`, no layer, code from `app/lambda/validate.py`, Timeout **30 sec**, no environment variables.

> **Note**: The function reads the file from S3 and checks every incident: id present, severity one of `LOW/MEDIUM/HIGH/CRITICAL`, description present, `visitor_id` a number. It returns two lists, `valid` and `invalid` (with the reason). A file that is not JSON, or has more than 100 incidents, raises an error **on purpose**: the state machine catches it and marks the file failed. The limit of 100 keeps the data passed between states below Step Functions' 256 KB limit.

### Step 3: Create the state machine

Console: **Step Functions → State machines → Create state machine → Write your workflow in code**, Type **Standard**, and replace the *Definition* with the content of `app/statemachine/workflow-layer4.asl.json` after replacing the placeholders:

| Placeholder | Replace with |
|---|---|
| `__FN_VALIDATE__` | the **ARN** of your `validate` Lambda |
| `__T_INCIDENTS__` | the **name** of the incidents table |
| `__T_FILES__` | the **name** of the files table |
| `__FAILED_QUEUE_URL__` | the **URL** of the `failed-items` queue |

Next → name `lks-libinc-workflow-<suffix>` → **Permissions: Choose an existing role → `lks_learning_role`** → Create.

> **Note**: Use *Edit → Find and replace* in the editor, or replace the text in your own editor first. Read the definition while you do it: `ValidateFile` (a Lambda task with `Retry` for temporary Lambda errors and a `Catch` to `MarkFileFailed`) → `ProcessIncidents` (a **`Map`** that processes up to 5 incidents at the same time) → `FinishFile`. Inside the `Map`, `SaveIncident` uses the **direct DynamoDB integration** (`arn:aws:states:::dynamodb:putItem`), so no Lambda is needed to write a row. `FinishFile` uses `updateItem` the same way, and its counters use the intrinsic functions `States.ArrayLength` and `States.Format`. The *Graph* view draws the whole flow; use it.

### Step 4: Let the dispatcher start the workflow

Lambda `dispatcher` → **Configuration → Environment variables → Edit** → set `STATE_MACHINE_ARN` to the **ARN of your state machine** → Save.

> **Note**: Now the dispatcher calls `StartExecution`. The execution name is a hash of the file key: Step Functions refuses a second execution with the same name and input, which is a second layer of protection after the DynamoDB claim.

**Layer 4 checkpoint — verify before continuing:**
- [ ] Upload `data/incidents-valid.json` under a **new name** (for example `valid-1.json`) into `incoming/` → Step Functions → your state machine → **Executions**: a new execution with status **Succeeded**
- [ ] DynamoDB → incidents table → **Explore items** → 3 items (`inc-1001`, `inc-1002`, `inc-1003`), each with `status` = `LOGGED`
- [ ] Upload `data/incidents-mixed.json` (new name) → 2 more items (`inc-3001`, `inc-3004`), and the files table row for it shows `processed_count` 2 and `invalid_count` 2
- [ ] Upload `data/incidents-broken.json` (new name) → the execution is **Failed** and its files-table row has `status` = `FAILED` and `error_type` = `JSONDecodeError`

---

## Layer 5 – Enrich in parallel and alert (Parallel, Choice, SNS)

> **What you build**: each incident gets the visitor name and a priority, and serious ones send an alert.

### Step 1: Create the SNS topic

Console: **SNS → Topics → Create topic**: type **Standard**, name `lks-libinc-alerts-<suffix>` → Create. Then **Create subscription**: Protocol **Email**, Endpoint your e-mail address → Create, and click **Confirm subscription** in the mail AWS sends you.

> **Note**: A topic fans a message out to its subscribers. **Nothing is delivered until you confirm the subscription.** The topic still works (publishing succeeds) with no subscriber, which is why the workflow does not break if you skip this.

### Step 2: Create the two Lambdas that run in parallel

| Function | Code | Layer | Environment variables | Timeout |
|---|---|---|---|---|
| `lks-libinc-lookup-visitor-<suffix>` | `app/lambda/lookup_visitor.py` | `pymysql` layer | `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASS` (as in layer 1) | 15 sec |
| `lks-libinc-classify-priority-<suffix>` | `app/lambda/classify_priority.py` | none | none | 10 sec |

Both use the role `lks_learning_role`.

> **Note**: `lookup-visitor` looks the `visitor_id` up in MySQL and returns the visitor, or `unknown` when the incident has no `visitor_id` or the visitor does not exist. `classify-priority` is pure logic: severity → priority number and SLA minutes, and a `security` incident gets one level more urgent. They do not depend on each other, so they can run at the same time.

### Step 3: Update the state machine

Step Functions → your state machine → **Edit** → replace the definition with `app/statemachine/workflow-layer5.asl.json`, replacing the placeholders of layer 4 **plus**:

| Placeholder | Replace with |
|---|---|
| `__FN_LOOKUP__` | ARN of `lookup-visitor` |
| `__FN_CLASSIFY__` | ARN of `classify-priority` |
| `__TOPIC_ARN__` | ARN of the SNS topic |

Save (keep the same role).

> **Note**: Compare with layer 4 in the Graph view. Inside the `Map`, `EnrichIncident` is a **`Parallel`** state with two branches. Its `ResultPath` is `$.enrichment`, which *adds* the results to the data instead of replacing it, so the incident is not lost. `MergeEnrichment` (a `Pass` state) reshapes the two branch results into one object. In the lookup branch a `Catch` sends any error to `VisitorUnknown`: if MySQL is down the incident is still saved (graceful degradation) instead of failing. `RouteBySeverity` is a **`Choice`**: HIGH and CRITICAL go to `NotifyHigh`, the **direct SNS integration** (`arn:aws:states:::sns:publish`) that builds the message with `States.Format`. Every path ends in `SaveIncident`, which now also stores `visitor_name` and `priority`.

**Layer 5 checkpoint — verify before continuing:**
- [ ] CloudShell: `curl -s -X POST $API/visitor -H 'Content-Type: application/json' -d '{"name":"Budi Santoso","class":"XII RPL 1","purpose":"Reading"}'` → note the `visitor_id` (the sample file uses `1`)
- [ ] Upload `data/incidents-valid.json` under a new name → DynamoDB → incident `inc-1003` shows `visitor_name` = `Budi Santoso`, `priority` = `2`, `status` = `NOTIFIED`
- [ ] Incident `inc-1001` shows `visitor_name` = `unknown`, `priority` = `4`, `status` = `LOGGED`
- [ ] Step Functions → the latest execution → Graph view: the `NotifyHigh` step is green (and your inbox has the alert, if you confirmed the subscription)

---

## Layer 6 – Human approval for CRITICAL incidents

> **What you build**: a CRITICAL incident pauses the workflow until a human approves or rejects it, or 15 minutes pass.

### Where does the approval appear?

There are three ways to answer, and they all end in the same Lambda:

1. **In the e-mail.** When a CRITICAL incident is processed, the SNS topic sends a message with two links, **Approve** and **Reject**. Clicking one opens a small web page saying "incident … approved".
2. **On the dashboard** (layer 7). The *Pending approvals* panel lists the waiting incidents with **Approve** and **Reject** buttons.
3. **With `curl`** in CloudShell, to test without a browser: `curl -s $API/approvals` lists pending approvals, then `curl -s "$API/approval?id=<approval_id>&decision=APPROVE"` answers one.

### Step 1: Create the approvals table

Console: **DynamoDB → Create table**: name `lks-libinc-approvals-<suffix>`, partition key `approval_id` (String), **On-demand**. Then open it → **Additional settings → Time to Live (TTL) → Turn on**, attribute name `ttl`.

> **Note**: Step Functions gives the waiting task a long secret *task token*. Anyone with the token can resume the workflow, so it must **never** be put in an e-mail link. It is stored in this table under a random `approval_id`, and only the `approval_id` goes into the link. TTL deletes old rows automatically after a day.

### Step 2: Create the two Lambdas

| Function | Code | Layer | Environment variables | Timeout |
|---|---|---|---|---|
| `lks-libinc-request-approval-<suffix>` | `app/lambda/request_approval.py` | none | `APPROVALS_TABLE` = approvals table name, `TOPIC_ARN` = SNS topic ARN, `API_BASE_URL` = your API invoke URL (no trailing slash) | 15 sec |
| `lks-libinc-approval-callback-<suffix>` | `app/lambda/approval_callback.py` | none | `APPROVALS_TABLE` = approvals table name | 15 sec |

> **Note**: `request-approval` is called by Step Functions with the task token. It saves the token, publishes the e-mail with the two links (`API_BASE_URL` is where the links point), and returns. The task does **not** finish when the function returns: the state machine keeps waiting. `approval-callback` serves three routes. On an answer it first makes a *conditional update* (`PENDING` → `APPROVED`/`REJECTED`), so a double click cannot answer twice, then calls `SendTaskSuccess` with the token. If the 15 minutes have already passed, AWS answers `TaskTimedOut`; the function marks the approval `EXPIRED` and shows a message.

### Step 3: Add the three API routes

Console: API Gateway → your API → **Routes → Create**, then attach the **same integration** (Lambda `approval-callback`) to each:

| Method | Path | Used by |
|---|---|---|
| `GET` | `/approval` | the link in the e-mail |
| `POST` | `/approval` | the dashboard buttons |
| `GET` | `/approvals` | the dashboard list |

> **Note**: The e-mail link must be `GET`, because a mail client can only open links. The list never returns the task token and only shows requests that have not expired.

### Step 4: Update the state machine

Edit the state machine → definition from `app/statemachine/workflow-layer6.asl.json`, with the placeholders of layer 5 **plus** `__FN_REQUEST_APPROVAL__` = ARN of `request-approval`. Save.

> **Note**: Now `RouteBySeverity` sends CRITICAL to `RequestApproval`. That task uses `arn:aws:states:::lambda:invoke.waitForTaskToken` and passes `$$.Task.Token` (`$$` is the *context object*, where Step Functions keeps its own values). `TimeoutSeconds: 900` is the 15 minutes. The first `Catch` handles `States.Timeout`: the incident goes to `NotifyEscalation` (an SNS message) and is saved with status `ESCALATED`. After an answer, `CheckDecision` stores `APPROVED` or `REJECTED`.

**Layer 6 checkpoint — verify before continuing:**
- [ ] Upload `data/incidents-critical.json` under a new name → the newest execution stays **Running** (it is waiting, not stuck)
- [ ] `curl -s $API/approvals` → one pending approval for `inc-2001`; your e-mail has the two links
- [ ] Open the **Approve** link (or `curl -s "$API/approval?id=<approval_id>&decision=APPROVE"`) → a page saying `incident inc-2001 approved`
- [ ] Within seconds the execution is **Succeeded** and DynamoDB shows `inc-2001` with `status` = `APPROVED`
- [ ] Open the same link again → `already handled (APPROVED)`
- [ ] Repeat with a new upload and answer with `curl -s -X POST $API/approval -H 'Content-Type: application/json' -d '{"id":"<approval_id>","decision":"REJECT"}'` → status `REJECTED`
- [ ] (Optional, 15 minutes) upload the critical file under another new name and do nothing → status `ESCALATED`

---

## Layer 7 – Daily report, read APIs and dashboard

> **What you build**: a nightly report, the data APIs, and a web dashboard.

### Step 1: Create the reports bucket

Console: **S3 → Create bucket** `lks-libinc-reports-<suffix>` (Block all public access stays on).

### Step 2: Create the three Lambdas

| Function | Code | Layer | Environment variables | Timeout |
|---|---|---|---|---|
| `lks-libinc-daily-report-<suffix>` | `app/lambda/daily_report.py` | `pymysql` | `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASS`, `INCIDENTS_TABLE` = incidents table name, `REPORT_BUCKET` = reports bucket name, `TOPIC_ARN` = SNS topic ARN | **60 sec** |
| `lks-libinc-get-summary-<suffix>` | `app/lambda/get_summary.py` | `pymysql` | `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASS` | 15 sec |
| `lks-libinc-get-incidents-<suffix>` | `app/lambda/get_incidents.py` | none | `INCIDENTS_TABLE` | 15 sec |

> **Note**: `daily-report` counts the visitors of one day in MySQL, counts the incidents of that day through `report-date-index` (a `Query`, not a `Scan`), saves one row in `daily_summary` (insert or update), writes `daily/<date>.json` to S3 and publishes a summary. It talks to three services, so it gets a 60 second timeout. Without a `date` in the event it reports on **yesterday**, because it runs just after midnight. All dates are UTC. `get-incidents` uses `severity-index` when a severity is requested and converts DynamoDB numbers (Decimal) to plain numbers, which `json.dumps` cannot handle otherwise.

### Step 3: Add the read routes

API Gateway → Routes → Create: `GET /summary` → `get-summary`, and `GET /incidents` → `get-incidents` (create and attach an integration for each).

> **Note**: These two plus `GET /approvals` are everything the dashboard reads.

### Step 4: Create the schedule

Console: **EventBridge → Scheduler → Schedules → Create schedule**

| Setting | Value |
|---|---|
| Name | `lks-libinc-daily-report-<suffix>` |
| Occurrence | Recurring schedule → **Cron-based** → `5 0 * * ? *` (time zone UTC) |
| Flexible time window | **Off** |
| Target | **Templated targets → AWS Lambda → Invoke** → `daily-report` |
| Execution role | **Use existing role → `lks_learning_role`** |

> **Note**: EventBridge **Scheduler** (not the older EventBridge *rules*) is built for time-based jobs. The cron has six fields: minute 5, hour 0, every day, every month, any weekday, every year → 00:05 UTC daily. *Flexible window Off* means "run exactly on time". Scheduler needs a role to invoke the Lambda; that is why the shared role trusts `scheduler.amazonaws.com`.

### Step 5: Deploy the dashboard to Amplify

1. On your computer, open `app/frontend/index.html` and replace `__API_GATEWAY_URL__` with your API invoke URL (no trailing slash). Save it.
2. Put **only that file** in a zip: select `index.html` itself and compress it (do **not** zip the folder).
3. Console: **AWS Amplify → Create new app → Deploy without Git** → App name `lks-libinc-web-<suffix>`, Branch name `main`, drag the zip → Save and deploy.

> **Note**: A web page cannot read your AWS settings, so you put the API address into the file yourself. `index.html` must be at the **root of the zip**: if it is inside a folder, the site answers `404`. The page has three views: visitor check-in, incident upload and the dashboard (summary, filtered incidents, pending approvals with buttons).

**Layer 7 checkpoint — verify before continuing:**
- [ ] Lambda `daily-report` → **Test** with event `{"date": "<today UTC, e.g. 2026-11-14>"}` → returns the report JSON
- [ ] S3 → reports bucket → `daily/<date>.json` exists; `curl -s $API/summary` → `last_days` has that date
- [ ] `curl -s "$API/incidents?severity=HIGH"` → only HIGH incidents, newest first; `curl -s "$API/incidents?severity=FOO"` → `400`
- [ ] Open the Amplify address: *Visitor check-in* works, *Report incidents* uploads (a new execution appears), and *Dashboard* shows the summary, the filtered incident table and pending approvals whose buttons work

---

## Layer 8 – Backup and alarms

> **What you build**: the database is backed up, and operators are alerted when something fails.

### Step 1: Create the vault and the plan

Console: **AWS Backup → Backup vaults → Create backup vault** `lks-libinc-vault-<suffix>` (default encryption key).

Then **Backup plans → Create backup plan → Build a new plan**: name `lks-libinc-plan-<suffix>`, rule name `daily-7-days`, vault = yours, Frequency **Daily**, start time `18:00 UTC`, **Retain for 7 days** → Create plan.

> **Note**: The *vault* stores the backups. The *plan* says when and for how long (daily, deleted after 7 days). Backups of RDS are snapshots, and a plan alone backs up nothing until you assign resources to it.

### Step 2: Assign the database

In the plan → **Assign resources**: name `library-db`, **IAM role → Choose an IAM role → `lks_learning_role`**, Resource selection **Include specific resource types → RDS** → pick your database → Assign.

> **Note**: The selection says *what* to back up, and which role AWS Backup uses (the shared role trusts `backup.amazonaws.com` and holds the two AWS Backup service policies). Do not choose *Default role*: it would create a new role.

### Step 3: Take one backup now

Console: **AWS Backup → Dashboard → Create on-demand backup**: Resource type **RDS**, your database, Backup vault = yours, **Retain 7 days**, IAM role **lks_learning_role** → Create.

> **Note**: The schedule runs once a day, and a checkpoint should not wait 24 hours. An on-demand job starts immediately and usually reaches **Completed** after a few minutes (**Jobs → Backup jobs**).

### Step 4: Create the alarms

Console: **CloudWatch → Alarms → Create alarm → Select metric**

1. **SQS → Queue Metrics** → `ApproximateNumberOfMessagesVisible` of the **DLQ** → Statistic **Maximum**, Period **1 minute** → Static, **Greater/Equal than 1** → *Additional configuration → Missing data treatment: Treat missing data as good* → Next → Notification: **In alarm → Select an existing SNS topic** → your topic → name `lks-libinc-dlq-not-empty-<suffix>` → Create.
2. **States → Execution Metrics** → `ExecutionsFailed` of your state machine → Statistic **Sum**, Period **5 minutes** → Static, **Greater/Equal than 1**, missing data **good**, same SNS topic → name `lks-libinc-workflow-failed-<suffix>` → Create.

> **Note**: The first alarm fires when the DLQ holds a message (a file that failed 3 times). The second fires when a workflow execution fails. *Treat missing data as good* keeps the alarm green when there is no data, which is the normal state of a healthy system. Both alarms send to the same SNS topic, so one e-mail subscription covers everything. Right after creation an alarm shows **Insufficient data** for a few minutes; it turns **OK** after the first evaluation.

**Layer 8 checkpoint — verify before continuing:**
- [ ] AWS Backup → **Jobs → Backup jobs**: the on-demand job is **Running**, then **Completed**; the vault lists one **recovery point**
- [ ] CloudWatch → Alarms: both alarms exist (state `OK` after a few minutes)
- [ ] Run the complete scenario once more: check in a visitor, upload `data/incidents-mixed.json` (new name), approve a CRITICAL incident, and see everything on the dashboard

---

## Clean up

RDS and backups keep costing money until deleted. Delete in this order:

1. **Amplify** app → **CloudWatch** alarms → **EventBridge Scheduler** schedule
2. **API Gateway** API
3. **Lambda**: first remove the SQS trigger of `dispatcher`, then delete all `lks-libinc-*-<suffix>` functions, and the layer (all versions)
4. **Step Functions** state machine, **SNS** topic, **SQS** queues (3)
5. **DynamoDB** tables (3)
6. **S3**: *Empty* each bucket first, then *Delete* it
7. **AWS Backup**: delete the plan's resource assignment, the plan, the **recovery points**, then the vault
8. **RDS**: delete the database (untick *Create final snapshot* for practice, tick *Delete automated backups*), then delete the security group `lks-libinc-rds-sg-<suffix>`

> **Note**: The order follows the dependencies: a trigger must go before its function, the database before its security group, a bucket must be empty before it can be deleted, and a vault cannot be deleted while it still holds recovery points. Do **not** touch `lks_learning_role`: it is shared.

---

## Instructor appendix – the shared role `lks_learning_role`

Students never edit IAM. Prepare the role once.

**Trust relationship** (IAM → Roles → `lks_learning_role` → Trust relationships → Edit trust policy; also in `iam/lks_learning_role-trust.json`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "lambda.amazonaws.com",
          "states.amazonaws.com",
          "events.amazonaws.com",
          "scheduler.amazonaws.com",
          "backup.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

> **Note**: A trust policy says *which service may use the role*. Lambda runs the functions, Step Functions runs the workflow, Scheduler runs the nightly job, AWS Backup runs the backups; `events` stays for EventBridge rules. IAM does not accept `*` as a service name, so each service is written out. Without a service in this list the symptom is an access error when that service tries to start (for example an EventBridge target that records *failed invocations* and starts nothing). Saving a new trust policy **replaces** the old one, so keep the old services in the list.

**Permission policies** to attach (IAM → Roles → `lks_learning_role` → Add permissions → Attach policies; also in `iam/lks_learning_role-policies.txt`):

```
AmazonRDSFullAccess
AWSLambdaBasicExecutionRole
AmazonSNSFullAccess
AmazonSQSFullAccess
AWSStepFunctionsFullAccess
AmazonDynamoDBFullAccess
AmazonS3FullAccess
AWSLambdaRole
AWSBackupServiceRolePolicyForBackup
AWSBackupServiceRolePolicyForRestores
```

> **Note**: Full-access policies are acceptable for a practice account; in production you would grant only the needed actions on the needed resources. `AWSLambdaRole` lets Step Functions and Scheduler invoke Lambda, `AWSLambdaBasicExecutionRole` lets Lambda write logs, and the two Backup policies let AWS Backup snapshot RDS.

**Check that the role may do everything the module needs** (IAM → *Policy simulator*, or CloudShell; it never changes anything):

```bash
aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::<ACCOUNT-ID>:role/lks_learning_role \
  --action-names sqs:SendMessage sqs:ReceiveMessage sqs:DeleteMessage states:StartExecution states:SendTaskSuccess \
                 lambda:InvokeFunction sns:Publish dynamodb:PutItem dynamodb:Query s3:PutObject \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
```

> **Note**: Every line must say `allowed`; `implicitDeny` means no policy grants it. The SQS actions matter twice: the Lambda trigger needs `ReceiveMessage` and `DeleteMessage`, and the state machine needs `SendMessage` for the `failed-items` queue. The **queue policy** that lets S3 send messages (layer 3, step 2) is a separate thing: it is attached to the queue, not to the role, and students write it themselves.
