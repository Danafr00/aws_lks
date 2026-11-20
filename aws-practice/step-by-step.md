# AWS Practice – Insert Data and Play with Core Services (AWS web console)

Small hands-on labs you do in the **AWS web console**. Each lab inserts or moves a little data through one AWS service, with a **Note** after every action that says what it does and why. The behaviour described in the Notes (what is overwritten, what is refused, which error appears) was checked against a real account.

| Lab | Service | What you practice |
|---|---|---|
| 1 | DynamoDB | Create a table, insert, read, overwrite, refuse duplicates, update, delete |
| 2 | S3 | Private bucket, upload, temporary link, versions |
| 3 | RDS MySQL (DBeaver) | Connect, insert rows, read them back, see a column limit fail |
| 4 | SNS and SQS | Send one message to a topic and receive it in a queue |
| 5 | API Gateway | An HTTP API with a route, an integration and a stage, with no Lambda |

---

## Before You Start

- Sign in to the console with your IAM user. The top-right corner shows the account and the user you are using: check it before you create anything.
- Set the region selector (top right) to **US East (N. Virginia) `us-east-1`** and keep it there for every lab.

> **Note**: Resources live in one region. A table or queue created in another region is invisible here, and two services in different regions cannot find each other by name.

- Replace `<name>` in resource names with your own name in lowercase.

> **Note**: Some names, such as S3 buckets, are shared by every AWS customer in the world, so a name without your own part is probably taken. In a shared account your name also stops you from overwriting a classmate's resources.

- **CloudShell** is the `>_` icon in the top bar. It opens a terminal inside the console, in the same region, already signed in. A few steps use it only to run `curl`. Where a step says `curl`, open CloudShell for it.
- Delete what you create at the end of each lab. The cleanup steps are part of the lab.

---

## Lab 1 – DynamoDB: insert data

> **What you build**: a table of library visitors.

### Step 1: Create the table

Console: **DynamoDB → Tables → Create table**

| Setting | Value |
|---|---|
| Table name | `lks-visitors-<name>` |
| Partition key | `visitor_id`, type **String** |
| Table settings | **Customize settings** → Capacity mode **On-demand** |

Press **Create table** and wait until the status is **Active**.

> **Note**: DynamoDB only needs the **key** up front. `visitor_id` is the partition key, and String means text. Every other attribute (name, class, purpose) is free-form and may differ from item to item. *On-demand* means no capacity planning and no cost while the table sits idle. Inserting before the status is *Active* fails.

### Step 2: Insert an item

Console: open the table → **Explore table items → Create item**. Add the attributes with **Add new attribute**:

| Attribute | Type | Value |
|---|---|---|
| `visitor_id` | String | `v-001` |
| `name` | String | `Budi` |
| `class` | String | `10A` |
| `purpose` | String | `Reading` |

Press **Create item**.

> **Note**: Every value has a type: String for text, Number for numbers. You can also switch the form to **JSON view** and paste `{"visitor_id": "v-001", "name": "Budi", "class": "10A", "purpose": "Reading"}`; the console fills in the types. The item then appears in the list under *Items returned*.

### Step 3: Insert two more

Create `v-002` and `v-003` the same way, with other names. The list under **Explore table items** shows all three.

> **Note**: This list is a *scan*: it reads the whole table. That is fine for a lab and slow and expensive on a big table. Real code reads one item by its key, or uses an index.

### Step 4: Insert the same id again

Create another item with `visitor_id` = `v-001`, `name` = `Overwritten`, and nothing else. Press **Create item** and open `v-001` in the list.

> **Note**: There is **no error**. The old item is silently replaced, and `class` and `purpose` are gone, because creating an item writes a whole item. Two writers that use the same key silently destroy each other's data.

### Step 5: Refuse duplicates with PartiQL

Console: **DynamoDB → PartiQL editor**. Run this (use your table name; the double quotes matter):

```sql
INSERT INTO "lks-visitors-<name>" VALUE {'visitor_id': 'v-001', 'name': 'Again'}
```

> **Note**: PartiQL is a SQL-like language for DynamoDB. Unlike *Create item*, a PartiQL `INSERT` refuses to touch an existing key: it fails with `DuplicateItemException: Duplicate primary key exists in table`. Use a new id (`v-010`) and the same statement works. This is how you make an insert safe when the same message can arrive twice.

### Step 6: Update one attribute

In the PartiQL editor:

```sql
UPDATE "lks-visitors-<name>" SET purpose = 'Studying' WHERE visitor_id = 'v-002'
SELECT * FROM "lks-visitors-<name>" WHERE visitor_id = 'v-002'
```

> **Note**: `UPDATE` changes only the attribute you name and leaves the others alone, unlike creating an item, which rewrites the whole thing. In the item list you can do the same with **Actions → Edit item**.

### Step 7: Delete an item

Select `v-001` in the item list → **Actions → Delete items** → confirm.

### Step 8: Clean up

Console: **DynamoDB → Tables** → select your table → **Delete** → confirm.

**Lab 1 checkpoint:**
- [ ] After step 4, `v-001` has only `visitor_id` and `name` (= `Overwritten`)
- [ ] Step 5 with `v-001` fails with `DuplicateItemException`
- [ ] After step 6, `v-002` shows `purpose` = `Studying`

---

## Lab 2 – S3: private bucket, temporary link, versions

> **What you build**: a bucket you can read only with your own login, and a link that works for five minutes.

Before you start, make a small file on your computer named `visitor.json` with this text:

```json
{"visitor_id": "v-001", "name": "Budi", "class": "10A"}
```

### Step 1: Create the bucket

Console: **S3 → Create bucket**: Bucket name `lks-practice-<name>`, Region **US East (N. Virginia)**, **Block all public access stays ticked** → Create bucket.

> **Note**: A new bucket is private. Leave *Block all public access* on: this lab never makes anything public.

### Step 2: Upload a file into a "folder"

Open the bucket → **Create folder** → name `incoming` → Create. Open `incoming/` → **Upload → Add files** → pick `visitor.json` → **Upload**.

> **Note**: S3 has no real folders. `incoming/` is just the first part of the object's name (its *key*, here `incoming/visitor.json`); the console draws it as a folder to be friendly.

### Step 3: Open the file

Click `visitor.json` → **Open** (top right of the object page).

> **Note**: **Open** gives you a temporary link signed for *you*, which is why it works even though the bucket is private. Keep this in mind for the next step.

### Step 4: Make a temporary link, and compare

On the object page: **Object actions → Share with a presigned URL** → time interval **5 minutes** → **Create presigned URL**. Open the copied link in a browser.

Now copy the plain **Object URL** from the object page and open it in a new browser tab.

> **Note**: The bucket is still private. The long query string of the presigned URL is a signature made with *your* credentials; it carries your permission for one action for 5 minutes, then it dies. The plain Object URL answers **Access Denied**. This is how a website lets a browser upload or download a file without making the bucket public.

### Step 5: Keep old versions

Bucket → **Properties → Bucket Versioning → Edit → Enable → Save changes**. Edit `visitor.json` on your computer (change `10A` to `10B`), upload it to `incoming/` again, then open `incoming/` and switch on **List versions**.

> **Note**: Without versioning, uploading the same key overwrites the file for good. With versioning on, both versions stay: each has its own *Version ID* and the newest is marked **Latest version**. Versioning can be suspended later but never removed.

### Step 6: Clean up

Bucket list → select your bucket → **Empty** → type `permanently delete` → Empty. Then select the bucket again → **Delete** → type the bucket name → Delete bucket.

> **Note**: A bucket must be **empty** before it can be deleted. *Empty* also removes every old version, which is why it works on a versioned bucket where deleting single files would only add *delete markers*.

**Lab 2 checkpoint:**
- [ ] The presigned link shows the file; the plain Object URL says **Access Denied**
- [ ] With **List versions** on, `incoming/visitor.json` has two versions

---

## Lab 3 – RDS MySQL: insert with DBeaver

> **What you need**: an RDS MySQL database with **Public access = Yes**, a security group that allows port **3306** from your IP, and a `visitors` table (see `library_visitor_app/README.md`, steps 1–2). DBeaver is a desktop program; everything else is in the console.

### Step 1: Get the password

If the database was created with *Managed in AWS Secrets Manager*, there is no password you chose. Console: **Secrets Manager** → the secret whose name starts with `rds!db-` → **Retrieve secret value**.

> **Note**: With a managed password AWS creates and rotates the master password and keeps it in Secrets Manager. You also cannot reset it from the RDS page: *Modify* will not accept a new master password while the instance is managed this way.

### Step 2: Find the endpoint and connect

Console: **RDS → Databases →** your database → **Connectivity & security → Endpoint**. In DBeaver create a MySQL connection: host = the endpoint, port `3306`, user `admin`, your database name, and the password from step 1. Open **Driver properties** and set `allowPublicKeyRetrieval` = `true` (and `useSSL` = `false` for a practice database).

> **Note**: MySQL 8 users log in with `caching_sha2_password`. Without SSL the client must ask the server for its public key to encrypt the password, and DBeaver refuses by default with `Public Key Retrieval is not allowed`. `allowPublicKeyRetrieval=true` allows it. With `useSSL=false` the password travels unencrypted, so use SSL for anything real. A **timeout** instead of this error means the network, not the login: check *Public access* and the 3306 rule in the security group.

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

> **Note**: `class` is `VARCHAR(20)`, so MySQL 8 rejects the row with `Data too long for column 'class'`. This is why application code trims input to the column size before it inserts.

### Step 5: Count per day, then clean up

```sql
SELECT DATE(visit_time) AS day, COUNT(*) AS total FROM visitors GROUP BY DATE(visit_time) ORDER BY day DESC;
DELETE FROM visitors WHERE name IN ('Budi', 'Siti', 'Test');
```

> **Note**: The first query is what a "daily summary" job runs. The `DELETE` removes your practice rows so the next person starts clean.

**Lab 3 checkpoint:**
- [ ] Step 3 returns your two rows with an `id` and a `visit_time` you did not type
- [ ] Step 4 fails with `Data too long`

---

## Lab 4 – SNS to SQS: one message, one queue (no e-mail)

> **What you build**: a topic that forwards each message to a queue.

### Step 1: Create the topic

Console: **SNS → Topics → Create topic**: type **Standard**, name `lks-demo-<name>` → Create topic.

> **Note**: A topic hands each message to all of its subscribers and keeps nothing itself.

### Step 2: Create the queue

Console: **SQS → Create queue**: type **Standard**, name `lks-demo-<name>`, defaults → Create queue.

> **Note**: A queue keeps messages until a consumer takes them. This is what makes it a good place to receive a message that arrives while nobody is listening.

### Step 3: Subscribe the queue to the topic

Console: **SQS →** your queue → **SNS subscriptions** tab → **Subscribe to Amazon SNS topic** → choose your topic → **Save**. Then open the queue's **Queue policies** (Access policy) tab and read what was added.

> **Note**: By default only the queue's owner may send to a queue, so SNS would be refused. Subscribing from the SQS side adds a *queue policy* for you: it allows `sns.amazonaws.com` to send messages (`sqs:SendMessage`), with a condition `aws:SourceArn` that limits it to **your** topic, so no other topic can fill your queue. If you subscribe from the SNS side instead, you must write that policy yourself, or messages never arrive and nothing says why.

### Step 4: Deliver the message exactly as sent

Console: **SNS → Subscriptions →** the new subscription → **Edit** → tick **Enable raw message delivery** → Save changes.

> **Note**: Without raw delivery, SNS wraps your text in its own JSON envelope (with `Type`, `MessageId`, `TopicArn` and more) and your message becomes a string inside it. With it on, the queue receives your message exactly as you sent it. Try the lab once with it off and compare the bodies.

### Step 5: Publish

Console: **SNS → Topics →** your topic → **Publish message**: Message body `{"visitor":"Budi","class":"10A"}` → **Publish message**.

### Step 6: Receive

Console: **SQS →** your queue → **Send and receive messages → Poll for messages**. Open the message that appears.

> **Note**: *Poll for messages* asks the queue for messages for a few seconds (*long polling*). The message body is your JSON. A subscription by **e-mail** instead needs a click on the confirmation link AWS mails you before anything is delivered.

### Step 7: Clean up

Delete the topic (**SNS → Topics → select → Delete**) and the queue (**SQS → Queues → select → Delete**).

**Lab 4 checkpoint:**
- [ ] The queue's message body is exactly `{"visitor":"Budi","class":"10A"}`

---

## Lab 5 – API Gateway: an HTTP API with no Lambda

> **What you build**: an API whose `GET /zen` route forwards to a public URL.

### Step 1: Create the API with an integration

Console: **API Gateway → Create API → HTTP API → Build**

1. **Integrations → Add integration**: type **HTTP URL**, Method **GET**, URL `https://api.github.com/zen`.
2. API name `lks-demo-<name>` → Next.

> **Note**: An HTTP API is simpler and cheaper than a REST API. The *integration* says where a request is sent. Later you can replace this one with a Lambda function or an EC2 server without changing the route or the address the clients use.

### Step 2: Add the route

On the **Routes** screen: Method **GET**, Resource path `/zen`, Integration target = the integration you just added → Next.

> **Note**: The *route* says which requests are accepted. It is separate from the integration so one integration can serve many routes.

### Step 3: Create the stage

On the **Stages** screen keep **`$default`** with **Auto-deploy** on → Next → **Create**.

> **Note**: A stage is a published version of the API. The special name `$default` with auto-deploy means every change goes live at once **and the address has no stage name in its path**. A stage called `prod` would make the address `.../prod/zen`.

### Step 4: Allow other websites to call it

Console: **Develop → CORS → Configure**: Access-Control-Allow-Origin `*`, Access-Control-Allow-Methods `GET, OPTIONS` → Save.

> **Note**: CORS is what lets a web page on another website call this API from a browser. Without it the browser blocks the call even though the server answered fine. `*` allows every website: fine for a lab, narrow it for real use.

### Step 5: Call it

On the API's page copy the **Invoke URL**. Open `<Invoke URL>/zen` in a browser.

> **Note**: The answer is a random sentence from GitHub. If you get `Not Found` the very first time, wait a few seconds and reload.

### Step 6: Call something that is not a route

Open `<Invoke URL>/nothing` in the browser.

> **Note**: API Gateway itself answers `{"message":"Not Found"}` (HTTP 404), because no route matches. The same error appears when a web page calls your API without the route's path at the end.

### Step 7: Clean up

Console: **API Gateway → APIs →** select your API → **Actions → Delete** → confirm.

**Lab 5 checkpoint:**
- [ ] `<Invoke URL>/zen` shows a sentence
- [ ] `<Invoke URL>/nothing` shows `{"message":"Not Found"}`

---

## Costs and Cleanup

DynamoDB on-demand, SQS, SNS and an HTTP API cost almost nothing for these labs; an S3 bucket and an RDS instance keep costing until you delete them. Delete the resources of every lab as soon as you finish, and check each service's page in the region you used for anything left behind.

> **Note**: The console shows only the region in the selector. A forgotten resource in another region keeps running and costing money without showing up where you are looking.
