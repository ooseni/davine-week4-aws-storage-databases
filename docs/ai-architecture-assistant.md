# AI as a cloud architecture assistant | what it suggested and what held up

**Davine Technologies Internship Project, AWS Cloud internship week 4.** The brief asked me to use AI as an architecture assistant:

- ask which storage service suits different business scenarios;
- have it compare S3, EBS and EFS for my use case;
- have it compare RDS and DynamoDB for my application;
- have it review my architecture and suggest improvements;
- verify at least one of its recommendations in AWS.

The assistant was **Claude (Anthropic's Fable 5.2 model, in Claude Code)**, used on 16 November 2026 while I rebuilt the week. I counted an AI answer only once AWS documentation or my own account confirmed it. Section 5 lists where checking changed the answer.

## 1. Which storage service for which business scenario

The use case I gave it: a small online shop with a public website, product images, customer documents, application logs, nightly database dumps, orders and shopping carts.

| Scenario | Its answer | Why | What I did with it |
|---|---|---|---|
| Public website pages and assets | Amazon S3 with static website hosting | no server, pay per request | built and served live |
| Customer invoices and exports | Amazon S3, private bucket, versioned | durable, cheap, access by policy | built: the data bucket |
| Images with unpredictable access | S3 Intelligent-Tiering | moves objects between tiers with no retrieval fee | used for `images/` |
| Logs read rarely but needed quickly | S3 Standard-IA, with an expiry | lower storage price, instant access | used for `logs/` |
| Nightly database dumps | S3 Glacier Instant Retrieval | archive price, still instant when a restore is urgent | used for `backups/` |
| The disk under a database server | Amazon EBS gp3 | low latency block device for one instance | present as the RDS volume |
| Uploads shared by several web servers | Amazon EFS | one file system mounted by many instances | not needed: one website, no fleet |
| Orders and customers | Amazon RDS for PostgreSQL | relations, constraints, transactions | built |
| Shopping carts and sessions | Amazon DynamoDB | lookups by key, spiky traffic, TTL | built |

## 2. S3, EBS and EFS for my use case

Its summary, which I checked against the AWS pages listed in the [report](report.md):

- **S3** is the default for anything that is a whole file written once and read many times. It is the only one of the three reached over HTTP and the only one with no capacity to manage.
- **EBS** is a disk for one EC2 instance in one Availability Zone. It is the right answer only when software needs a block device: an operating system, or a database engine's files.
- **EFS** is a shared Linux file system across zones. It earns its higher price only when several machines must see the same directory.

For the shop, that made S3 the answer for every file, EBS something I use indirectly through RDS, and EFS not needed. I asked what would change its mind about EFS. Its answer: a second web server that must write user uploads to a local path. Even then it would first consider writing uploads straight to S3.

## 3. RDS and DynamoDB for my application

I asked it to decide table by table instead of picking one database for everything.

| Data | Its choice | The deciding question |
|---|---|---|
| Customers, orders, order lines | RDS (PostgreSQL) | "Does an order have to reference a real customer, and must totals be right inside one transaction?" Yes. |
| Monthly sales report | RDS | "Will someone ask a question nobody planned for?" Yes: that needs SQL and joins. |
| Shopping carts | DynamoDB | "Is it always fetched by one key?" Yes: the customer. |
| Sessions | DynamoDB | "Should it delete itself?" Yes: TTL. |

Its caution about DynamoDB was the part I found most useful: the key design fixes which questions are cheap. With `customer_id` as the partition key, "what is in this customer's cart" is one query, but "which carts contain this product" needs a secondary index or a scan.

## 4. Its review of the architecture

I gave it the baseline (one bucket with website hosting and the uploaded folders, the database, the table) and asked what it would change. Its list, in its order:

| # | Suggestion | Kind | What I did |
|---|---|---|---|
| 1 | The public-read policy covers `/*`, so the folders are public too. Move them to a second bucket with Block Public Access on | security | **done, and verified** |
| 2 | Turn on versioning for the data bucket, with an expiry for old versions | reliability | **done, and verified** |
| 3 | Deny requests without TLS on the data bucket | security | **done, and verified** |
| 4 | Take a manual RDS snapshot, because automated backups go when the instance goes | reliability | **done, and verified** |
| 5 | Lifecycle rules so documents age into cheaper classes | cost | done |
| 6 | Serve the site through CloudFront with origin access control, so no bucket is public and the site has HTTPS | security | not done: the brief asks for S3 website hosting. Listed under Lab vs production |
| 7 | Multi-AZ for the database | reliability | not done: it doubles the instance cost. Listed under Lab vs production |
| 8 | Customer managed KMS keys | security | not done: 1 USD a month per key. Listed under Lab vs production |

I turned the review into [`scripts/storage_review.py`](../scripts/storage_review.py) so the same questions are asked the same way before and after. Against the baseline it reports 1 high, 4 medium and 1 low finding. Against the hardened stack it reports none, plus 4 notes for the production items.

## 5. Recommendations verified in AWS

The brief asks for at least one. I verified four, all on 16 November 2026 ([baseline transcript](evidence/verify-baseline-2026-11-16.txt), [hardened transcript](evidence/verify-hardened-2026-11-16.txt)).

| Recommendation | Before | After |
|---|---|---|
| Separate public and private content | `curl` with no credentials fetched `documents/customer-export.csv`: HTTP 200 | the same request returns 404 from the website and 403 from the data bucket; policy status `IsPublic: False` |
| Versioning | versioning never enabled | I overwrote a file, deleted it (404), then removed the delete marker and the bad version. The checksum and version ID match the original |
| TLS only | not enforced | a correctly signed request over plain HTTP is refused with 403; over HTTPS it succeeds |
| Manual snapshot | 0 manual snapshots | `davine-wk4-postgres-review`: available, manual, encrypted |

## 6. Where checking changed the answer

The AI wrote the first draft of the code. Running it found five things it got wrong or I had to question.

1. **DynamoDB changed its numbers.** The sample items stored prices as `6.50` and `39.00`. DynamoDB normalises numbers, so they came back as `6.5` and `39`, and Terraform wanted to "fix" two items on every plan. Prices are now whole cents (`unit_price_cents = 650`), which is also the safer way to store money.
2. **A check that could never pass.** The verify script asked the AWS CLI for `ResponseMetadata.HTTPStatusCode`. The CLI does not expose that field, so the check printed `None`. It now tests whether the request succeeded.
3. **An upload from a pipe.** The recovery drill piped text into `aws s3api put-object --body /dev/stdin`. The CLI requires a real file path. The run stopped before changing anything; the drill now writes a small temporary file.
4. **One day of backups.** The first draft kept automated RDS backups for 1 day. Trivy flagged it as very low. It is now 7 days, and Terraform rejects 0.
5. **"TLS is forced by default."** The AI said PostgreSQL 15 and later on RDS set `rds.force_ssl` to 1 by default. I did not take that on trust: the live run reads the parameter group and found `1`.

What I took from this: the AI was right about the design and wrong about several details, and only running the code against AWS showed which was which.
