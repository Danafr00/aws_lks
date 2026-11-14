# Step-by-Step – Report Pipeline (AWS web console)

This is the answer key. You build everything in the **AWS web console**. Every action is followed by a **Note** that explains what you just did and why, so you understand the pipeline instead of only clicking.

You build it in 6 layers. Each layer adds one idea and ends with a **checkpoint**. Do not start the next layer before the checkpoint passes.

## Layer Overview

| Layer | What You Build | Checkpoint |
|---|---|---|
| **1** | RDS + Lambda `get_reports` + API `GET /reports` | `curl` returns `[]` |
| **2** | S3 + presigned URL Lambda + API `GET /upload-url` | Upload with `curl` returns 200, the file is in the bucket |
| **3** | SNS + Step Functions (validate, Choice, process, notify), started by hand | Execution succeeds, one row in RDS |
| **4** | EventBridge rule on the bucket | Uploading a file starts an execution by itself |
| **5** | DynamoDB status + API `GET /reports/{id}` | Status goes `PROCESSING` → `DONE`, bad files show `INVALID` |
| **6** | Amplify dashboard + CloudWatch alarm | The page shows the upload, the list and the status |

---

## Before You Start

- Region: **Asia Pacific (Singapore) `ap-southeast-1`**. Check the region selector (top right) in **every** service. Resources created in another region are invisible and cannot talk to each other.
- Your **suffix**: your name in lowercase letters and digits, for example `dana`. It is added to every resource name (`lks-rp-<purpose>-<suffix>`).

> **Note**: S3 bucket names are global across all AWS accounts, so a name without your own suffix is probably taken already. In a shared account the suffix also stops you from overwriting a classmate's resources.

- **IAM is already done for you.** Every time a service asks for a role, choose the existing role **`lks_learning_role`** (*Use an existing role*). Do not create roles, and never let the console "create a new role" in this module.

> **Note**: One role is shared by Lambda, Step Functions and EventBridge. It already trusts those three services and holds the permissions this module needs (the exact JSON is in the *Instructor appendix* at the end).

- **Networking is not part of this module.** Whenever a screen shows VPC, subnet or similar settings, keep the **default** value. You will learn to design networks in a later module.
- **Get the module files onto your computer**: the `app/lambda/` code files, the `app/statemachine/` JSON files, `app/frontend/index.html` and the `data/` sample files. They are all in this folder of the repository (download the repository as a zip, or clone it).
- **CloudShell** (the `>_` icon at the top of the console) is a ready-made terminal in the same region. You use it for a few commands (`curl`, building one zip). Anywhere below that says `$API`, first run `API=https://<your-api-id>.execute-api.ap-southeast-1.amazonaws.com` in CloudShell, using the invoke URL of **your** API (layer 1).

---

## Layer 1 – Reports API (RDS + Lambda + API Gateway)

> **What you build**: an HTTP API that reads the processed reports from MySQL.

### Step 1: Create the RDS database

Console: **RDS → Create database**

| Setting | Value |
|---|---|
| Creation method | Standard create |
| Engine | MySQL (latest 8.4) |
| Template | **Free tier** (or Sandbox) |
| DB instance identifier | `lks-rp-db-<suffix>` |
| Master username | `admin` |
| Credentials management | **Self managed**, set a password of letters and digits (12+ characters) and write it down |
| Instance class | `db.t3.micro` |
| Storage | gp2, 20 GiB, untick *Enable storage autoscaling* |
| Connectivity | keep the **default VPC** and the default subnet group |
| Public access | **Yes** |
| VPC security group | **Create new** → name `lks-rp-rds-sg-<suffix>` |
| Additional configuration → Initial database name | `reports` |
| Backup retention | 1 day |
| Deletion protection | untick |
| Tags | `Project=lks-rp`, `Environment=practice`, `ManagedBy=LKS-Team` |

Press **Create database** and wait until the status is **Available** (about 5–10 minutes).

> **Note**: `db.t3.micro` is the smallest class. **Public access = Yes** gives the database an address that is reachable from the internet, so the security group (the database's firewall) is the only protection. *Initial database name* creates the empty database `reports` for you; without it you would have to run `CREATE DATABASE` yourself. Deletion protection is off so you can delete the database when you finish. Put the password somewhere safe now: AWS can never show it again.

### Step 2: Open port 3306 in the security group

Console: **EC2 → Security Groups →** `lks-rp-rds-sg-<suffix>` **→ Inbound rules → Edit inbound rules → Add rule**: Type **MySQL/Aurora** (port 3306), Source **Anywhere-IPv4** (`0.0.0.0/0`) → Save.

> **Note**: A security group is a firewall: it lists which traffic may reach a resource. 3306 is the MySQL port. `0.0.0.0/0` means "from anywhere". It is the simplest way to let both CloudShell **and** Lambda (which has no fixed address) reach the database. It is acceptable only in a practice account with a strong password and a short life. Never do this with real data.

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

Console: **Lambda → Layers → Create layer**: name `lks-rp-pymysql-<suffix>`, upload `pymysql-layer.zip`, compatible runtime **Python 3.11**, architecture **x86_64** → Create.

> **Note**: Layers are versioned. You attach a specific version to each function that needs it.

### Step 4: Create the table

In CloudShell (replace the host with the **Endpoint** on your RDS page and the password with yours):

```bash
pip install --user pymysql cryptography -q
python3 - <<'EOF'
import pymysql
conn = pymysql.connect(host="<RDS-ENDPOINT>", user="admin", password="<PASSWORD>", database="reports", connect_timeout=10)
cur = conn.cursor()
cur.execute("""CREATE TABLE IF NOT EXISTS reports (
    id INT AUTO_INCREMENT PRIMARY KEY,
    report_id VARCHAR(100) NOT NULL,
    filename VARCHAR(200) NOT NULL,
    record_count INT NOT NULL,
    total_amount DECIMAL(14,2) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_report_id (report_id))""")
conn.commit()
cur.execute("SHOW TABLES"); print(cur.fetchall())
EOF
```

> **Note**: This is the same SQL as `sql/schema.sql`. `DECIMAL(14,2)` stores money exactly (a `FLOAT` would give rounding errors such as `262502.49999`). `report_id` has a `UNIQUE` key: the processing Lambda inserts with `ON DUPLICATE KEY UPDATE`, so processing the same report twice updates one row instead of creating a duplicate. You should see `(('reports',),)`. Prefer a GUI? DBeaver works too: host = the endpoint, user `admin`, database `reports`, and in *Driver properties* set `allowPublicKeyRetrieval=true`.

### Step 5: Create the Lambda `get-reports`

Console: **Lambda → Create function → Author from scratch**

| Setting | Value |
|---|---|
| Function name | `lks-rp-get-reports-<suffix>` |
| Runtime | Python 3.11 |
| Execution role | **Use an existing role → `lks_learning_role`** |

1. In the **Code** tab, replace everything in `lambda_function.py` with the content of `app/lambda/get_reports.py`, then **Deploy**.
2. **Code → Layers → Add a layer → Custom layers** → your `lks-rp-pymysql-<suffix>` → Add.
3. **Configuration → Environment variables → Edit**: `DB_HOST` (RDS endpoint), `DB_NAME` = `reports`, `DB_USER` = `admin`, `DB_PASS` (your password).
4. **Configuration → General configuration → Edit**: Timeout **15 sec**.

> **Note**: The handler stays `lambda_function.lambda_handler` (file name + function name), which is why the code goes into `lambda_function.py`. Connection details come from environment variables, so no password is written in the source code. The default timeout is only 3 seconds, too short for opening a database connection. The code turns `Decimal` and `datetime` values into text with `default=str`, because `json.dumps` cannot write them.

### Step 6: Create the HTTP API

Console: **API Gateway → Create API → HTTP API → Build**

1. **Add integration → Lambda** → region `ap-southeast-1` → your `get-reports` function.
2. API name `lks-rp-api-<suffix>` → Next.
3. Routes: Method **GET**, Resource path `/reports`, integration = your Lambda → Next.
4. Stages: keep **`$default`** with **Auto-deploy** on → Next → Create.
5. **Develop → CORS → Configure**: Access-Control-Allow-Origin `*`, Access-Control-Allow-Headers `content-type`, Access-Control-Allow-Methods `GET, OPTIONS` → Save.

> **Note**: An HTTP API is simpler and cheaper than a REST API. The `$default` stage with auto-deploy means the URL has **no stage name in the path**: it is `https://<id>.execute-api.ap-southeast-1.amazonaws.com/reports`, not `.../prod/reports`. Calling a path that is not a route (for example the bare address) gives `404 Not Found`. When you attach a Lambda in the console it also adds the permission that lets API Gateway invoke that function. CORS is needed because the dashboard (on another website) calls this API from a browser; without it the browser blocks the call even though the server answered.

**Layer 1 checkpoint — verify before continuing:**
- [ ] CloudShell: `API=<invoke URL>` then `curl -s $API/reports` → `[]`
- [ ] Insert a test row by hand (rerun the Python of step 4 with `cur.execute("INSERT INTO reports (report_id, filename, record_count, total_amount) VALUES ('test.json','test',1,10.5)"); conn.commit()`), then `curl -s $API/reports` → one row with `"total_amount": "10.50"`
- [ ] Delete the test row (`DELETE FROM reports WHERE report_id='test.json'`) so the table is empty again

---

## Layer 2 – Upload (S3 + presigned URL)

> **What you build**: a browser can upload a report straight to a private bucket.

### Step 1: Create the bucket

Console: **S3 → Create bucket**: name `lks-rp-uploads-<suffix>`, region Singapore, **Block all public access stays ticked** → Create.

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

Create the function exactly like layer 1 step 5 (name `lks-rp-get-upload-url-<suffix>`, role `lks_learning_role`, **no layer needed**) with the code of `app/lambda/get_upload_url.py`, environment variable `BUCKET` = your bucket name, Timeout 10 sec.

> **Note**: A presigned URL is a normal S3 address with a signature in the query string. It allows exactly one action (`PUT` of one key) for 5 minutes, signed with the role of the Lambda. S3 checks that role's `s3:PutObject` permission when the upload arrives and answers `403 AccessDenied` if it is missing; `lks_learning_role` has it. The code builds the S3 client with the **regional endpoint** and virtual addressing: without that, boto3 can produce the global host `bucket.s3.amazonaws.com`, S3 answers `307 Temporary Redirect`, and a browser refuses to follow a redirect during the CORS preflight. The file name is a random id plus `.json` under `incoming/`; that id (without the folder) is the **report id** used everywhere later.

### Step 4: Add the route

Console: API Gateway → your API → **Routes → Create**: `GET` `/upload-url` → select the new route → **Attach integration → Create and attach an integration** → Lambda → `get-upload-url`.

> **Note**: A route without an integration returns `500`.

**Layer 2 checkpoint — verify before continuing:**
- [ ] CloudShell: `curl -s $API/upload-url` → JSON with `upload_url` (host looks like `lks-rp-uploads-<suffix>.s3.ap-southeast-1.amazonaws.com`), `key` and `report_id`
- [ ] Upload with the presigned URL:
  `URL=$(curl -s $API/upload-url | python3 -c 'import json,sys;print(json.load(sys.stdin)["upload_url"])')` then
  `echo '{}' > t.json; curl -s -o /dev/null -w "%{http_code}\n" -X PUT "$URL" -H 'Content-Type: application/json' --data-binary @t.json` → `200`
- [ ] S3 console → bucket → folder `incoming/` → one `.json` file

---

## Layer 3 – Workflow (SNS + Step Functions), started by hand

> **What you build**: a state machine that validates a report, stores it in RDS and sends an e-mail. For now you start it yourself.

### Step 1: Create the SNS topic

Console: **SNS → Topics → Create topic**: type **Standard**, name `lks-rp-alerts-<suffix>` → Create. Then **Create subscription**: Protocol **Email**, Endpoint your e-mail address → Create, and click **Confirm subscription** in the mail AWS sends you.

> **Note**: A topic fans a message out to its subscribers. **Nothing is delivered until you confirm the subscription.** The topic itself works (publishing succeeds) even with no subscriber, which is why the workflow does not break if you skip this.

### Step 2: Create the two Lambdas

| Function | Code | Layer | Environment variables | Timeout |
|---|---|---|---|---|
| `lks-rp-validate-<suffix>` | `app/lambda/validate.py` | none | none | 30 sec |
| `lks-rp-process-report-<suffix>` | `app/lambda/process_report.py` | `pymysql` layer | `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASS` (as in layer 1) | 30 sec |

Both use the role `lks_learning_role`.

> **Note**: `validate` reads the file from S3 and checks the rules of the README. A bad file is **not** an error for the Lambda: it answers `valid: false` with a `reason`, and it always returns the same five keys (`valid`, `reason`, `filename`, `record_count`, `etag`), because the state machine reads them with fixed paths. The `etag` is a fingerprint of the exact file that was checked. A crash would be retried and would end in a failed execution, but a wrong file is a normal business result. `process-report` reads the file again (the state machine passes only the file name and the `etag`, never the content, to keep the data small). It reads with `IfMatch=etag`: if somebody replaced the file after the check (the upload address stays valid for 5 minutes), S3 refuses with `PreconditionFailed`, the `Catch` ends the run as an error, and unchecked data is never processed. It then counts the rows, sums `qty × price` and writes one row with `INSERT … ON DUPLICATE KEY UPDATE`.

### Step 3: Create the state machine

Console: **Step Functions → State machines → Create state machine → Write your workflow in code**, Type **Standard**, and replace the *Definition* with the content of `app/statemachine/workflow-layer3.asl.json` after replacing the placeholders:

| Placeholder | Replace with |
|---|---|
| `__FN_VALIDATE__` | the **ARN** of your `validate` Lambda |
| `__FN_PROCESS__` | the **ARN** of your `process-report` Lambda |
| `__TOPIC_ARN__` | the **ARN** of your SNS topic |

Next → name `lks-rp-workflow-<suffix>` → **Permissions: Choose an existing role → `lks_learning_role`** → Create.

> **Note**: Use *Edit → Find and replace* in the editor, or replace the text in your own editor first. Read the definition and look at the *Graph* view: `Init` (a `Pass` state) turns the S3 event into `bucket`, `key` and `report_id` (`States.StringSplit` cuts the key at `/`, `States.ArrayGetItem` takes the second piece, the file name). `Validate` is a Lambda task with `Retry` for temporary Lambda errors and a `Catch` that sends any other error to `NotifyError`. `CheckValid` is a **`Choice`**: valid goes to `Process`, everything else to `NotifyInvalid`. `Process` has the same `Retry` and `Catch`. The three `Notify…` states use the **direct SNS integration** (`arn:aws:states:::sns:publish`), so no Lambda is needed to send a message. `ResultPath` decides where a task's result is stored: `$.validation` and `$.result` **add** to the data instead of replacing it, so `report_id` is still there at the end. The workflow ends in `Done`, `ReportRejected` (both *Succeeded*: a rejected file is a normal result) or `PipelineFailed` (*Failed*: a real error).

**Layer 3 checkpoint — verify before continuing:**
- [ ] Upload `data/report-valid.json` into `incoming/` of your bucket (S3 console → **Upload**). It keeps its name, so its report id is `report-valid.json`
- [ ] Step Functions → your state machine → **Start execution** with this input (your own bucket name):

```json
{"detail": {"bucket": {"name": "lks-rp-uploads-<suffix>"}, "object": {"key": "incoming/report-valid.json"}}}
```

- [ ] The execution ends **Succeeded** in the `Done` state; the Graph view shows `Validate` → `CheckValid` → `Process` → `NotifySuccess` in green
- [ ] `curl -s $API/reports` → one row: `record_count` 3, `total_amount` `262502.50`
- [ ] Start it again with the **same input** → still one row (the `UNIQUE` key and `ON DUPLICATE KEY UPDATE` at work)
- [ ] Upload `data/report-bad-row.json` and start an execution with `"key": "incoming/report-bad-row.json"` → ends in `ReportRejected` (Succeeded), **no** new row, and the `NotifyInvalid` step shows the reason (`row 1: 'qty' must be a whole number above 0`)

> **Note**: You wrote the input yourself: it is exactly the shape of the event S3 will send through EventBridge in layer 4. That is why the `Init` state reads `$.detail.bucket.name` and `$.detail.object.key`.

---

## Layer 4 – Automatic start (EventBridge)

> **What you build**: every new file in `incoming/` starts the workflow by itself.

### Step 1: Turn on EventBridge for the bucket

Console: bucket → **Properties → Amazon EventBridge → Edit → Send notifications to Amazon EventBridge for all events in this bucket: On** → Save changes.

> **Note**: S3 sends **nothing** to EventBridge until you switch this on. It is the most common reason an upload "does nothing". A new setting can take **a few minutes** to start working.

### Step 2: Create the rule

Console: **Amazon EventBridge → Rules → Create rule**

| Setting | Value |
|---|---|
| Name | `lks-rp-upload-rule-<suffix>` |
| Event bus | **default** |
| Rule type | **Rule with an event pattern** |
| Event source | **AWS events or EventBridge partner events** |
| Creation method | **Custom pattern (JSON editor)** |

Event pattern (your bucket name):

```json
{
  "source": ["aws.s3"],
  "detail-type": ["Object Created"],
  "detail": {
    "bucket": {"name": ["lks-rp-uploads-<suffix>"]},
    "object": {"key": [{"prefix": "incoming/"}]}
  }
}
```

Next → Target: **AWS service → Step Functions state machine** → your state machine → **Execution role: Use existing role → `lks_learning_role`** → Create rule.

> **Note**: The *event bus* is the channel events arrive on; events from AWS services such as S3 arrive on the `default` bus, so you do **not** create a custom bus. The *rule* is the filter plus the target: only `Object Created` events of your bucket under `incoming/` pass. A typo in the bucket name (even a trailing space) means the rule never matches and nothing happens, with no error. EventBridge needs a role to start the state machine; the shared role trusts `events.amazonaws.com`, which is what allows it. Without that trust the rule's *FailedInvocations* metric goes up and no execution starts.

**Layer 4 checkpoint — verify before continuing:**
- [ ] Wait a few minutes after step 1, then upload `data/report-valid.json` under a **new name** (for example `valid-2.json`) into `incoming/`
- [ ] Step Functions → **Executions**: a new execution appears by itself and ends **Succeeded**
- [ ] `curl -s $API/reports` → a second row with report id `valid-2.json`
- [ ] EventBridge → your rule → **Monitoring**: `Invocations` is 1 and `FailedInvocations` is 0
- [ ] Upload `data/report-broken.json` (not JSON) → an execution that ends in `ReportRejected`, with the e-mail/SNS reason `file is not valid JSON`

---

## Layer 5 – Status tracking (DynamoDB)

> **What you build**: every report gets a status record that the web page can read.

### Step 1: Create the status table

Console: **DynamoDB → Create table**: name `lks-rp-status-<suffix>`, partition key `report_id` (String), **Customize settings → Capacity mode: On-demand** → Create.

> **Note**: RDS (SQL) is good for the final, structured result. DynamoDB is good for small records that are read and written by key and very fast, such as "what is the status of report X right now". Only the key attribute is declared; `status`, `message`, `record_count` and the others are free-form. On-demand means no capacity planning and no cost while idle.

### Step 2: Create the Lambda `get-report-status` and its route

Create the function (name `lks-rp-get-report-status-<suffix>`, role `lks_learning_role`, no layer) with the code of `app/lambda/get_report_status.py`, environment variable `STATUS_TABLE` = the table name, Timeout 10 sec. Then API Gateway → Routes → Create: `GET` `/reports/{id}` → attach a new integration → this Lambda.

> **Note**: `{id}` is a *path parameter*: whatever follows `/reports/` arrives in `event["pathParameters"]["id"]`. The function answers `404` when there is no item. DynamoDB numbers arrive as `Decimal`, which `json.dumps` cannot write, so the code converts them first.

### Step 3: Update the state machine

Step Functions → your state machine → **Edit** → replace the definition with `app/statemachine/workflow-layer5.asl.json`, replacing the placeholders of layer 3 **plus** `__T_STATUS__` = the **name** of the status table (a name, not an ARN). Save (keep the same role).

> **Note**: Compare with layer 3 in the Graph view. `MarkProcessing` writes `PROCESSING` before validation, and `MarkDone`, `MarkInvalid` and `MarkError` write the final status. They use the **direct DynamoDB integration** (`arn:aws:states:::dynamodb:putItem` and `updateItem`), so no Lambda is needed to write a record. The attribute types are written out (`"S"` for text, `"N"` for number), and numbers are passed as text with `States.Format('{}', …)`. `ResultPath: null` throws the service's answer away, so the workflow data is not polluted. `updateItem` creates the item if it does not exist, so a status is written even when something fails early. `$$.State.EnteredTime` is the time Step Functions entered the state (the `$$` is the *context object*, where Step Functions keeps its own values).

**Layer 5 checkpoint — verify before continuing:**
- [ ] Upload `data/report-valid.json` under a new name (for example `valid-3.json`) → `curl -s $API/reports/valid-3.json` → `{"report_id": "valid-3.json", "status": "DONE", "record_count": 3, "total_amount": 262502.5, ...}`
- [ ] Upload `data/report-bad-row.json` under a new name (for example `bad-3.json`) → `curl -s $API/reports/bad-3.json` → `"status": "INVALID"` and `"message": "row 1: 'qty' must be a whole number above 0"`
- [ ] `curl -s -o /dev/null -w "%{http_code}\n" $API/reports/does-not-exist.json` → `404`
- [ ] DynamoDB → the table → **Explore items**: one item per report, `updated_at` filled in

---

## Layer 6 – Dashboard and alarm

> **What you build**: a web page for the staff, and an alarm for the operator.

### Step 1: Deploy the dashboard to Amplify

1. On your computer, open `app/frontend/index.html` and replace `__API_GATEWAY_URL__` with your API invoke URL (no trailing slash). Save it.
2. Put **only that file** in a zip: select `index.html` itself and compress it (do **not** zip the folder).
3. Console: **AWS Amplify → Create new app → Deploy without Git** → App name `lks-rp-web-<suffix>`, Branch name `main`, drag the zip → Save and deploy.

> **Note**: A web page cannot read your AWS settings, so you put the API address into the file yourself. `index.html` must be at the **root of the zip**: if it is inside a folder, the site answers `404`. When you upload a report, the page asks the API for a presigned URL, sends the file straight to S3, then asks `GET /reports/{id}` every 3 seconds and shows `PROCESSING` until the final status appears.

### Step 2: Create the alarm

Console: **CloudWatch → Alarms → Create alarm → Select metric → States → Execution Metrics** → `ExecutionsFailed` of your state machine → Statistic **Sum**, Period **5 minutes** → Static, **Greater/Equal than 1** → *Additional configuration → Missing data treatment: Treat missing data as good* → Next → Notification: **In alarm → Select an existing SNS topic** → your topic → name `lks-rp-workflow-failed-<suffix>` → Create.

> **Note**: The alarm fires when an execution *fails* (a real error), not when a report is merely rejected, because a rejected report ends as *Succeeded*. *Treat missing data as good* keeps the alarm green when there is no data, which is the normal state of a healthy system. It sends to the same SNS topic, so one e-mail subscription covers everything. Right after creation an alarm shows **Insufficient data** for a few minutes; it turns **OK** after the first evaluation.

**Layer 6 checkpoint — verify before continuing:**
- [ ] Open the Amplify address: *Upload report* → press **Upload** → the message goes `Processing …` and then `<id>.json: DONE`
- [ ] *Reports* lists the report with its record count and total; *Check status* finds it by its id
- [ ] Edit the text in the page so a row has `"qty": -1`, upload again → `INVALID - row 0: 'qty' must be a whole number above 0`
- [ ] CloudWatch → Alarms: `lks-rp-workflow-failed-<suffix>` exists (state `OK` after a few minutes)
- [ ] Run the whole scenario once more from scratch: valid report, rejected report, broken file, same file name twice

> **Note**: A file name is also the report id. Uploading the **same S3 key** again overwrites the file and starts a new execution, and the single RDS row is updated, not duplicated. The dashboard always creates a new random id, so every click is a new report.

---

## Clean up

RDS keeps costing money until deleted. Delete in this order:

1. **Amplify** app → **CloudWatch** alarm
2. **EventBridge** rule (delete its target first if the console asks)
3. **API Gateway** API
4. **Lambda**: delete all `lks-rp-*-<suffix>` functions and the layer (all versions)
5. **Step Functions** state machine, **SNS** topic
6. **DynamoDB** table
7. **S3**: *Empty* the bucket first, then *Delete* it
8. **RDS**: delete the database (untick *Create final snapshot* for practice, tick *Delete automated backups*), then delete the security group `lks-rp-rds-sg-<suffix>`

> **Note**: The order follows the dependencies: the rule that starts the state machine goes before the state machine, a bucket must be empty before it can be deleted, and the database goes before its security group. Do **not** touch `lks_learning_role`: it is shared.

---

## Instructor appendix – the shared role `lks_learning_role`

Students never edit IAM. Prepare the role once. Each student account also needs permission to *use* the role: `iam:PassRole` on `lks_learning_role` (the console asks for it whenever a student picks the role for a Lambda function, a state machine or an EventBridge target). Without it the console answers "not authorized to perform iam:PassRole".

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
          "events.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

> **Note**: A trust policy says *which service may use the role*. Lambda runs the functions, Step Functions runs the workflow, EventBridge starts the workflow. IAM does not accept `*` as a service name, so each service is written out. Saving a new trust policy **replaces** the old one, so keep any service that other modules already use in the list (the shared role may also trust `scheduler.amazonaws.com` and `backup.amazonaws.com` for other modules).

**Permission policies** to attach (IAM → Roles → `lks_learning_role` → Add permissions → Attach policies; also in `iam/lks_learning_role-policies.txt`):

```
AmazonRDSFullAccess
AWSLambdaBasicExecutionRole
AmazonSNSFullAccess
AWSStepFunctionsFullAccess
AmazonDynamoDBFullAccess
AmazonS3FullAccess
AWSLambdaRole
```

> **Note**: Full-access policies are acceptable for a practice account; in production you would grant only the needed actions on the needed resources. `AWSLambdaRole` lets Step Functions invoke Lambda, and `AWSLambdaBasicExecutionRole` lets Lambda write logs. `AWSStepFunctionsFullAccess` includes `states:StartExecution`, which EventBridge needs.

**Check that the role may do everything the module needs** (IAM → *Policy simulator*, or CloudShell; it never changes anything):

```bash
aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::<ACCOUNT-ID>:role/lks_learning_role \
  --action-names states:StartExecution lambda:InvokeFunction sns:Publish dynamodb:PutItem dynamodb:UpdateItem \
                 dynamodb:GetItem s3:GetObject s3:PutObject \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
```

> **Note**: Every line must say `allowed`; `implicitDeny` means no policy grants the action.
