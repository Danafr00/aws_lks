# AWS Practice – Insert Data and Play with Core Services

Small hands-on labs you can run from your own terminal. Each lab inserts or moves a little data through one AWS service, with a **Note** after every action that says what it does and why. Every command in this guide was run against a real account before it was written down.

| Lab | Service | What you practice |
|---|---|---|
| 1 | DynamoDB | Create a table, insert, read, overwrite, protect against duplicates, update, delete |
| 2 | S3 | Private bucket, upload, read, temporary link, versions |
| 3 | RDS MySQL (DBeaver) | Connect, insert rows, read them back, see a column limit fail |
| 4 | SNS and SQS | Send one message to a topic and receive it in a queue |
| 5 | API Gateway | An HTTP API with a route, an integration and a stage, with no Lambda |

---

## Before You Start

- Install the AWS CLI v2, then create a profile from your access key (`aws configure --profile <your-profile>`).
- Use one region for everything. These labs use **`us-east-1`**.
- Replace `<name>` in resource names with your own name in lowercase. Some names (S3 buckets) are shared by every AWS customer in the world, so a name without your own part is probably taken.
- Set two variables once per terminal, so the commands below stay short:

```bash
export AWS_PROFILE=<your-profile>
export AWS_DEFAULT_REGION=us-east-1
```

> **Note**: `AWS_PROFILE` tells the CLI which credentials to use, and `AWS_DEFAULT_REGION` which region to talk to. Resources created in another region are invisible in the console of this one, so keep the region selector (top right of the console) on the same region.

- Run `aws sts get-caller-identity` first. It prints the account and user you are about to use.

> **Note**: It changes nothing and proves the credentials work. Make a habit of checking it before creating resources, especially when you have more than one profile.

- Delete what you create at the end of each lab. The cleanup steps are part of the lab.

---

## Lab 1 – DynamoDB: insert data

> **What you build**: a table of library visitors.

### Step 1: Create the table

```bash
aws dynamodb create-table --table-name lks-visitors-<name> --billing-mode PAY_PER_REQUEST \
  --attribute-definitions AttributeName=visitor_id,AttributeType=S \
  --key-schema AttributeName=visitor_id,KeyType=HASH
aws dynamodb wait table-exists --table-name lks-visitors-<name>
```

> **Note**: DynamoDB only needs the **key** up front: `visitor_id` is the partition key, and `S` means text. Every other attribute (name, class, purpose) is free-form and can differ from item to item. `PAY_PER_REQUEST` (on-demand) means no capacity planning and no cost while the table sits idle. The `wait` command blocks until the table is `ACTIVE`; inserting too early fails. In the console: DynamoDB → Create table → Customize settings → Capacity mode: On-demand.

### Step 2: Insert an item

```bash
aws dynamodb put-item --table-name lks-visitors-<name> \
  --item '{"visitor_id":{"S":"v-001"},"name":{"S":"Budi"},"class":{"S":"10A"},"purpose":{"S":"Reading"}}'
```

> **Note**: Every value is written together with its type: `S` for text, `N` for a number (still written as text, for example `{"N":"12"}`). The command prints nothing when it works. In the console: Explore items → Create item → JSON view.

### Step 3: Insert two more and read everything

Insert `v-002` and `v-003` with other names, then:

```bash
aws dynamodb scan --table-name lks-visitors-<name>
```

> **Note**: `scan` reads the whole table. It is fine for a lab and slow and expensive for a big table; real code reads by key (`get-item`) or by index (`query`).

### Step 4: Insert the same id again

```bash
aws dynamodb put-item --table-name lks-visitors-<name> \
  --item '{"visitor_id":{"S":"v-001"},"name":{"S":"Overwritten"}}'
aws dynamodb get-item --table-name lks-visitors-<name> --key '{"visitor_id":{"S":"v-001"}}'
```

> **Note**: There is **no error**: the old item is silently replaced, and `class` and `purpose` are gone because `put-item` writes a whole item. Two writers using the same key silently destroy each other's data.

### Step 5: Refuse duplicates

```bash
aws dynamodb put-item --table-name lks-visitors-<name> \
  --item '{"visitor_id":{"S":"v-001"},"name":{"S":"Again"}}' \
  --condition-expression "attribute_not_exists(visitor_id)"
```

> **Note**: The condition says "only write if no item with this key exists yet". Now the call fails with `ConditionalCheckFailedException`. This is the standard way to make an insert safe when the same message may arrive twice.

### Step 6: Update one attribute, then delete

```bash
aws dynamodb update-item --table-name lks-visitors-<name> --key '{"visitor_id":{"S":"v-001"}}' \
  --update-expression "SET purpose = :p" --expression-attribute-values '{":p":{"S":"Studying"}}' \
  --return-values ALL_NEW
aws dynamodb delete-item --table-name lks-visitors-<name> --key '{"visitor_id":{"S":"v-001"}}'
```

> **Note**: `update-item` changes only the attributes you name and leaves the others alone, unlike `put-item`. `:p` is a placeholder; values are never pasted into the expression text, which keeps them safe and typed. `--return-values ALL_NEW` prints the item after the change.

### Step 7: Clean up

```bash
aws dynamodb delete-table --table-name lks-visitors-<name>
```

**Lab 1 checkpoint:**
- [ ] After step 4, `get-item` shows `Overwritten` and no `class`
- [ ] Step 5 fails with `ConditionalCheckFailedException`
- [ ] After step 6, `update-item` prints `purpose` = `Studying`

---

## Lab 2 – S3: private bucket, temporary link, versions

> **What you build**: a bucket you can read only with your credentials, and a link that works for five minutes.

### Step 1: Create the bucket

```bash
aws s3api create-bucket --bucket lks-practice-<name>
```

> **Note**: In `us-east-1` this command takes **no** `--create-bucket-configuration`. In every other region (for example `ap-southeast-1`) you must add `--create-bucket-configuration LocationConstraint=<region>`, otherwise it fails. A new bucket has **Block Public Access** turned on; leave it on.

### Step 2: Upload a file into a "folder"

```bash
echo '{"visitor_id":"v-001","name":"Budi","class":"10A"}' > visitor.json
aws s3 cp visitor.json s3://lks-practice-<name>/incoming/visitor.json
```

> **Note**: S3 has no real folders. `incoming/` is just the first part of the object's name (its *key*). The console draws it as a folder to be friendly.

### Step 3: List, then read without downloading

```bash
aws s3 ls s3://lks-practice-<name>/incoming/
aws s3 cp s3://lks-practice-<name>/incoming/visitor.json -
```

> **Note**: The `-` as destination means "print to the terminal" instead of saving a file.

### Step 4: Make a temporary link

```bash
aws s3 presign s3://lks-practice-<name>/incoming/visitor.json --expires-in 300
```

Open the printed link in a browser, or `curl` it. Then try the plain address without the long signature:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://lks-practice-<name>.s3.amazonaws.com/incoming/visitor.json
```

> **Note**: The bucket is still private. The long query string is a signature made with *your* credentials; it carries your permission for one action for 300 seconds, then dies. The plain address answers `403`. This is how a website lets a browser upload or download without making the bucket public.

### Step 5: Keep old versions

```bash
aws s3api put-bucket-versioning --bucket lks-practice-<name> --versioning-configuration Status=Enabled
echo '{"v":2}' > visitor.json
aws s3 cp visitor.json s3://lks-practice-<name>/incoming/visitor.json
aws s3api list-object-versions --bucket lks-practice-<name> --query 'Versions[].[Key,VersionId,IsLatest]' --output text
```

> **Note**: Without versioning, uploading the same key overwrites the file for good. With versioning on, both versions stay and each has its own `VersionId`; the newest is `IsLatest`. Versioning can be suspended later but not removed.

### Step 6: Clean up

```bash
aws s3api list-object-versions --bucket lks-practice-<name> --query 'Versions[].[Key,VersionId]' --output text \
  | while read key version; do aws s3api delete-object --bucket lks-practice-<name> --key "$key" --version-id "$version"; done
aws s3api delete-bucket --bucket lks-practice-<name>
```

> **Note**: A bucket must be **empty** before it can be deleted, and a versioned bucket is not empty until every *version* is deleted (a plain `aws s3 rm` only adds a delete marker). The loop deletes each version one by one. Use `$key` and `$version` as names: in some shells a variable called `path` silently breaks your `PATH`.

**Lab 2 checkpoint:**
- [ ] The presigned link shows the file; the plain address answers `403`
- [ ] `list-object-versions` shows two versions of `incoming/visitor.json`

---

## Lab 3 – RDS MySQL: insert with DBeaver

> **What you need**: an RDS MySQL database with **Public access = Yes**, a security group that allows port 3306 from your IP, and a `visitors` table (see `library_visitor_app/README.md`, steps 1–2).

### Step 1: Get the password

If the database was created with *Managed in AWS Secrets Manager*, there is no password you chose. Open **Secrets Manager**, pick the secret whose name starts with `rds!db-`, and press **Retrieve secret value**.

> **Note**: With a managed password AWS creates and rotates the master password for you and stores it in Secrets Manager. You also cannot reset it with `modify-db-instance --master-user-password`; AWS answers that the instance has `ManageMasterUserPassword` enabled.

### Step 2: Connect

In DBeaver create a MySQL connection: host = the **Endpoint** shown on the RDS page, port `3306`, user `admin`, your database name and the password from step 1. Open **Driver properties** and set `allowPublicKeyRetrieval` = `true` (and `useSSL` = `false` for a practice database).

> **Note**: MySQL 8 users log in with `caching_sha2_password`. Without SSL, the client must ask the server for its public key to encrypt the password, and DBeaver refuses by default: `Public Key Retrieval is not allowed`. `allowPublicKeyRetrieval=true` allows it. With `useSSL=false` the password is exposed on the network, so use SSL for anything real. A timeout instead of this error means the network, not the login: check *Public access* and the 3306 rule.

### Step 3: Insert and read

```sql
INSERT INTO visitors (name, class, purpose) VALUES ('Budi', '10A', 'Reading'), ('Siti', '10B', 'Study');
SELECT id, name, class, purpose, visit_time FROM visitors ORDER BY id DESC;
```

> **Note**: `id` and `visit_time` are filled in by MySQL (`AUTO_INCREMENT` and `DEFAULT CURRENT_TIMESTAMP`), so the `INSERT` names only the three columns you provide.

### Step 4: Break a limit on purpose

```sql
INSERT INTO visitors (name, class, purpose) VALUES ('Test', 'a-class-name-that-is-far-too-long', 'x');
```

> **Note**: `class` is `VARCHAR(20)`, so MySQL 8 rejects it with `Data too long for column 'class'`. This is why application code trims input to the column size before inserting.

### Step 5: Count per day

```sql
SELECT DATE(visit_time) AS day, COUNT(*) AS total FROM visitors GROUP BY DATE(visit_time) ORDER BY day DESC;
```

> **Note**: This is the query a "daily summary" job runs. Remove your test rows afterwards (`DELETE FROM visitors WHERE name IN ('Budi','Siti','Test')`).

**Lab 3 checkpoint:**
- [ ] Step 3 returns your two rows with an `id` and a `visit_time` you did not type
- [ ] Step 4 fails with `Data too long`

---

## Lab 4 – SNS to SQS: one message, one queue (no e-mail)

> **What you build**: a topic that forwards each message to a queue.

### Step 1: Create the topic and the queue

```bash
TOPIC=$(aws sns create-topic --name lks-demo-<name> --query TopicArn --output text)
QURL=$(aws sqs create-queue --queue-name lks-demo-<name> --query QueueUrl --output text)
QARN=$(aws sqs get-queue-attributes --queue-url "$QURL" --attribute-names QueueArn --query Attributes.QueueArn --output text)
```

> **Note**: An SNS *topic* hands each message to all of its subscribers and keeps nothing. An SQS *queue* keeps messages until a consumer takes them. The three variables hold the identifiers the next steps need.

### Step 2: Allow SNS to send to the queue

```bash
python3 - "$QARN" "$TOPIC" > policy.json <<'PY'
import json, sys
q, t = sys.argv[1:3]
pol = {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": {"Service": "sns.amazonaws.com"},
       "Action": "sqs:SendMessage", "Resource": q, "Condition": {"ArnEquals": {"aws:SourceArn": t}}}]}
print(json.dumps({"Policy": json.dumps(pol)}))
PY
aws sqs set-queue-attributes --queue-url "$QURL" --attributes file://policy.json
```

> **Note**: By default only the queue's owner may send to it, so SNS would be refused. This *queue policy* allows the SNS service, and the `aws:SourceArn` condition limits that to **your** topic, so no other topic can fill your queue. The policy has to be a JSON string inside JSON, which is why Python builds the file. In the console: SQS → the queue → Access policy → Edit.

### Step 3: Subscribe the queue and publish

```bash
aws sns subscribe --topic-arn "$TOPIC" --protocol sqs --notification-endpoint "$QARN" --attributes RawMessageDelivery=true
aws sns publish --topic-arn "$TOPIC" --message '{"visitor":"Budi","class":"10A"}'
```

> **Note**: `RawMessageDelivery=true` delivers the message exactly as sent. Without it SNS wraps the message in its own JSON envelope (with `Type`, `MessageId`, `TopicArn`…) and your text becomes a string inside it. A subscription by **e-mail** instead needs a click on the confirmation link AWS mails you before anything is delivered.

### Step 4: Receive the message

```bash
aws sqs receive-message --queue-url "$QURL" --wait-time-seconds 5
```

> **Note**: `--wait-time-seconds` is *long polling*: the call waits up to 5 seconds for a message instead of answering empty at once. Try the lab again without `RawMessageDelivery` and compare the bodies.

### Step 5: Clean up

```bash
aws sns delete-topic --topic-arn "$TOPIC"
aws sqs delete-queue --queue-url "$QURL"
```

**Lab 4 checkpoint:**
- [ ] `receive-message` returns `{"visitor":"Budi","class":"10A"}` as the body

---

## Lab 5 – API Gateway: an HTTP API with no Lambda

> **What you build**: an API whose `GET /zen` route forwards to a public URL.

### Step 1: Create the API

```bash
API=$(aws apigatewayv2 create-api --name lks-demo-<name> --protocol-type HTTP \
  --cors-configuration '{"AllowOrigins":["*"],"AllowMethods":["GET","OPTIONS"]}' --query ApiId --output text)
```

> **Note**: An HTTP API is simpler and cheaper than a REST API. The CORS block is what lets a web page on another website call this API from a browser; without it the browser blocks the call even though the server answered. `*` allows any website: fine for a lab, narrow it for real use.

### Step 2: Create the integration and the route

```bash
INT=$(aws apigatewayv2 create-integration --api-id $API --integration-type HTTP_PROXY --integration-method GET \
  --integration-uri https://api.github.com/zen --payload-format-version 1.0 --query IntegrationId --output text)
aws apigatewayv2 create-route --api-id $API --route-key "GET /zen" --target integrations/$INT
```

> **Note**: The *integration* says where a request is sent; the *route* says which requests are accepted. They are separate so one integration can serve many routes. Later you can swap this integration for a Lambda function or an EC2 server without changing the route or the address clients use.

### Step 3: Create a stage and call it

```bash
aws apigatewayv2 create-stage --api-id $API --stage-name '$default' --auto-deploy
curl https://$API.execute-api.us-east-1.amazonaws.com/zen
```

> **Note**: A stage is a published version of the API. The special name `$default` with `--auto-deploy` means every change goes live at once **and the address has no stage name in its path**. With a stage called `prod` the address would be `.../prod/zen`. The answer is a random sentence from GitHub. If you get `404` the very first time, wait a few seconds and retry.

### Step 4: Call something that is not a route

```bash
curl -i https://$API.execute-api.us-east-1.amazonaws.com/nothing
```

> **Note**: API Gateway itself answers `404 Not Found`, because no route matches. The same error appears when a web page calls the API address without the route's path.

### Step 5: Clean up

```bash
aws apigatewayv2 delete-api --api-id $API
```

**Lab 5 checkpoint:**
- [ ] `curl .../zen` answers HTTP 200 with a sentence
- [ ] `curl .../nothing` answers `404`

---

## Costs and Cleanup

DynamoDB on-demand, SQS, SNS and HTTP API cost almost nothing for these labs; an S3 bucket and an RDS instance keep costing until you delete them. Delete the resources of every lab as soon as you finish, and check the console of the region you used for anything left behind.
