# Week 4 report | AWS storage services and databases

**Davine Technologies Internship Project, AWS Cloud internship week 4** | Oseni Sakariyau Oluwadamilare | Exercise week of 24 August 2026, rebuilt and re-verified 16 November 2026

This is the short report the week 4 brief asked for, written in my own words. It explains Amazon S3, its storage classes and bucket policies, Amazon EBS, Amazon EFS, Amazon RDS and Amazon DynamoDB, then the storage security practices that tie them together. Each section ends with what I saw in my own account on 16 November 2026, when I rebuilt the week as Terraform and ran it. AWS-specific figures were checked against the AWS documentation listed at the end.

## 1. Amazon S3

Amazon Simple Storage Service stores **objects** in **buckets**. An object is a file plus its metadata, addressed by a **key** such as `documents/invoice-2026-08.txt`. A bucket is a container with a globally unique name that lives in one Region.

Three things make S3 different from a disk:

- **There are no folders.** The console draws `documents/` as a folder, but it is only a shared prefix in the key. "Organising files into folders" means choosing key prefixes. Prefixes matter because lifecycle rules and policies can target them.
- **It is reached over HTTP, not mounted.** Every read and write is an API request. An object is replaced whole; it cannot be edited in place.
- **It is built to not lose data.** S3 is designed for 99.999999999% (eleven nines) durability and stores each object across at least three Availability Zones, except in the One Zone classes. Reads after a write are strongly consistent.

**Static website hosting** makes a bucket answer plain web requests: an index document for `/`, an error document for missing pages. The website endpoint is HTTP only and serves anonymous visitors, so the objects must be publicly readable.

**In my account:** `davine-wk4-site-<suffix>` serves three objects. The home page returns 200 as `text/html`, a missing page returns 404 with my custom error document, and anonymous list, upload and delete requests all return 403 ([live run](evidence/verify-hardened-2026-11-16.txt)).

## 2. S3 storage classes

Every object has a storage class. The classes trade a lower storage price for a retrieval fee, a minimum storage duration, or slower access.

| Class | Built for | Zones | Retrieval | Minimum duration | What I used it for |
|---|---|---|---|---|---|
| S3 Standard | data read often | 3 or more | instant, no fee | none | `documents/`, the website |
| S3 Intelligent-Tiering | unknown or changing access | 3 or more | instant, no fee | none | `images/` |
| S3 Standard-IA | read rarely, needed at once | 3 or more | instant, fee per GB | 30 days | `logs/` |
| S3 One Zone-IA | re-creatable data read rarely | 1 | instant, fee per GB | 30 days | not used |
| S3 Glacier Instant Retrieval | archives read about once a quarter | 3 or more | instant, higher fee | 90 days | `backups/` |
| S3 Glacier Flexible Retrieval | archives that can wait | 3 or more | minutes to hours | 90 days | not used |
| S3 Glacier Deep Archive | compliance archives | 3 or more | hours | 180 days | not used |
| S3 Express One Zone | very low latency next to compute | 1 | single-digit milliseconds | none | not used |

Two details decide whether a cheaper class really saves money:

- **Small objects.** Standard-IA, One Zone-IA and Glacier Instant Retrieval bill each object as at least 128 KB. Thousands of 2 KB log lines cost more in Standard-IA than in Standard.
- **Early deletion.** Deleting an object before its minimum duration still bills the remaining days.

A **lifecycle rule** moves objects between classes by age, so nobody has to remember. Mine moves `documents/` to Standard-IA after 30 days and to Glacier Instant Retrieval after 90, expires `logs/` after a year, and deletes old versions after 30 days.

**In my account:** `head-object` reported the class I chose for each of the five uploaded files, and the data bucket lists the three lifecycle rules by name. My sample files are tiny, so the 128 KB minimum applies to them; the lab shows the mechanism, not a saving.

## 3. Bucket policies and access control

S3 starts from "deny". A request succeeds only if something allows it and nothing denies it.

- **IAM policies** are attached to users and roles: what may *this identity* do?
- **Bucket policies** are attached to the bucket: who may do what *to this bucket*? This is the only way to grant access to anonymous visitors or to another account.
- **Block Public Access** is a set of four switches above both. When on, they override any policy or ACL that would make data public. New buckets have all four on.
- **ACLs** are the old per-object mechanism. New buckets disable them (Object Ownership: bucket owner enforced), and I left them off.

An explicit `Deny` always beats an `Allow`. Two policies from this week show both directions:

```json
{ "Sid": "PublicReadForWebsite", "Effect": "Allow", "Principal": "*",
  "Action": "s3:GetObject", "Resource": "arn:aws:s3:::davine-wk4-site-<suffix>/*" }
```

```json
{ "Sid": "DenyRequestsWithoutTLS", "Effect": "Deny", "Principal": "*", "Action": "s3:*",
  "Resource": ["arn:aws:s3:::davine-wk4-data-<suffix>", "arn:aws:s3:::davine-wk4-data-<suffix>/*"],
  "Condition": { "Bool": { "aws:SecureTransport": "false" } } }
```

The first is the risk of the week. `Resource: .../*` means **every object in the bucket**, not "the website". Anything else uploaded to that bucket is public the moment it lands.

**In my account:** that is exactly what the baseline showed. With the uploaded folders in the website bucket, `documents/customer-export.csv` came back with HTTP 200 to a request with no credentials. After moving the folders to a second bucket with Block Public Access fully on, the same file returns 404 from the website and 403 from the data bucket, and a correctly signed request over plain HTTP is refused with 403.

## 4. Amazon EBS

Amazon Elastic Block Store is a **network disk for one EC2 instance**. The instance sees a raw block device, formats it with a file system and mounts it, as it would a physical drive.

- A volume lives in **one Availability Zone** and attaches to an instance in the same zone. Normally one instance at a time.
- It persists independently of the instance, so data survives a stop or a replacement.
- **gp3** is the general purpose SSD type: 3,000 IOPS and 125 MiB/s included at any size, with more available separately. io2 Block Express is for the heaviest databases; st1 and sc1 are cheap HDD types for large sequential workloads.
- **Snapshots** are incremental backups of a volume, stored by AWS in S3. A snapshot can be copied to another Region or turned into a new volume in any zone.

Use it for: an operating system disk, a self-managed database on EC2, anything that needs a low-latency disk owned by one machine.

**In my account:** I did not create a standalone volume, because week 2's instance already had one. EBS still appears here: the RDS instance stores its data on a 20 GiB encrypted gp3 volume that RDS manages, and an RDS snapshot is an EBS snapshot underneath.

## 5. Amazon EFS

Amazon Elastic File System is a **shared network file system** for Linux. Many instances, containers and Lambda functions mount the same file system at once over NFS and see the same files.

- It is **Regional**: data is stored across several Availability Zones, with a mount target in each zone's subnet.
- It is **elastic**: no size to provision, it grows and shrinks with the files, and bills per GB stored.
- It has its own storage classes (Standard, Infrequent Access, Archive) with lifecycle management.
- It costs several times more per GB than S3 and has higher latency per operation than EBS.

Use it for: a shared content directory behind several web servers, home directories, a build cache shared by many workers.

**In my account:** not created. Nothing in this lab has two machines that need the same files, and the honest answer to "which service?" for my use case was S3 and RDS.

### S3, EBS and EFS side by side

| Question | Amazon S3 | Amazon EBS | Amazon EFS |
|---|---|---|---|
| What is it? | object storage | block storage (a disk) | file storage (a shared drive) |
| How is it reached? | HTTPS API | attached to one EC2 instance | mounted over NFS by many clients |
| Scope | Region | one Availability Zone | Region |
| Capacity | unlimited, nothing to provision | size chosen up front, can grow | elastic |
| Edit part of a file? | no, replace the object | yes | yes |
| Typical use | website assets, uploads, backups, logs, data lakes | boot disks, database files | shared content for a fleet of servers |
| Relative price per GB | lowest | middle | highest |

For an online shop: product images and invoices go to **S3**; the disk under a database or an application server is **EBS**; a directory that ten web servers must all write to is **EFS**.

## 6. Amazon RDS

Amazon Relational Database Service runs a relational database engine for me: PostgreSQL, MySQL, MariaDB, Oracle, SQL Server, Db2, or Amazon Aurora. AWS does the provisioning, patching, backups and failover. I still own the schema, the queries, the access rules and the instance size.

- **Automated backups**: a daily snapshot plus transaction logs, kept for 1 to 35 days, which allow a restore to a point in time. They are deleted with the instance unless retained.
- **Manual snapshots**: taken on request and kept until someone deletes them.
- **Multi-AZ**: a synchronous standby in a second zone with automatic failover. It is for availability, not for scaling reads.
- **Read replicas**: asynchronous copies that scale reads.
- A restore always creates a **new** instance with a new endpoint; it never overwrites the running one.

Use it when the data is relational: orders that reference customers, constraints the database must enforce, transactions across several tables, ad-hoc SQL and joins.

**In my account:** `davine-wk4-postgres`, PostgreSQL 17 on db.t4g.micro, in two private subnets of a VPC with no internet gateway. It is not publicly accessible, its storage is encrypted, automated backups are kept for 7 days, and its only inbound rule is port 5432 from the application security group. RDS created the master password and keeps it in Secrets Manager, so it is not in my code or my Terraform state. I did not run SQL against it: nothing in the lab can reach port 5432, which is the point of the network design, and adding a host to do so was outside the brief.

## 7. Amazon DynamoDB

Amazon DynamoDB is a serverless key-value and document database. There is no instance to size. A table has a **partition key** and an optional **sort key**; items with the same partition key are stored together and sorted.

- Reads and writes by key take single-digit milliseconds at any table size.
- **On-demand** mode bills per request and costs nothing while idle. **Provisioned** mode reserves capacity for steady workloads.
- Each item can have different attributes, up to 400 KB per item.
- **TTL** deletes items after a timestamp attribute passes. **Point-in-time recovery** restores the table to any second in a window of up to 35 days. **On-demand backups** are kept until deleted.
- There are no joins. The table is designed around the questions the application asks; a new question may need a secondary index.

**In my account:** `davine-wk4-carts`, keyed by `customer_id` then `sku`, on-demand, with TTL on `expires_at` and point-in-time recovery on. A query for one customer returned their 2 items, a conditional write refused to overwrite an existing item, an atomic `ADD` turned 1 into 3, and an on-demand backup reached `AVAILABLE`.

### RDS and DynamoDB side by side

| Question | Amazon RDS (PostgreSQL) | Amazon DynamoDB |
|---|---|---|
| Data model | tables with a fixed schema, foreign keys | items found by key, flexible attributes |
| Queries | any SQL, joins, aggregates | by key or index; no joins |
| Transactions | full ACID across tables | ACID transactions on up to 100 items |
| Scaling | bigger instance, read replicas | automatic, horizontal |
| Capacity to manage | instance class and storage | none in on-demand mode |
| Network | inside my VPC | a Regional HTTPS API guarded by IAM |
| Cost while idle | the instance bills every hour | nothing in on-demand mode |
| Good fit | orders, payments, inventory, reporting | carts, sessions, user preferences, event logs |

For the same shop: **orders and customers in RDS**, because an order must reference a real customer and money totals must add up inside a transaction. **Shopping carts in DynamoDB**, because a cart is read and written by one key, traffic is spiky, and abandoned carts should expire by themselves.

## 8. Storage security best practices

1. **Keep Block Public Access on** for every bucket that is not deliberately public, and at the account level where no bucket is.
2. **Separate public content from private data.** A public-read policy on a bucket covers everything in it. This was my finding of the week.
3. **Least privilege.** Grant the specific actions on the specific resource. The website policy allows `s3:GetObject` and nothing else; the database accepts one port from one security group.
4. **Encrypt at rest.** S3 encrypts new objects by default; RDS encryption must be chosen at creation; DynamoDB is always encrypted. Use customer managed KMS keys when access to the key itself must be controlled and audited.
5. **Encrypt in transit.** Deny S3 requests without TLS; require TLS on the database.
6. **Version and back up.** S3 versioning undoes overwrites and deletes. Databases need automated backups *and* a tested restore.
7. **Keep databases off the internet.** Private subnets, no public address, security groups that name other security groups.
8. **No stored secrets.** Let RDS manage the master password in Secrets Manager; use IAM roles instead of access keys.
9. **Log and watch.** CloudTrail data events, S3 server access logs, and IAM Access Analyzer for buckets shared outside the account.
10. **Control cost as part of safety.** Lifecycle rules, expiry for old versions, and tags that show who owns what.

**In my account:** items 1 to 8 are in the Terraform and checked by the live run. Item 9 is listed under Lab vs production in the README, because logging needs resources that outlive a short lab. Item 10 is the lifecycle configuration and the six tags on every resource.

## Sources

- [What is Amazon S3?](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html) and [Amazon S3 storage classes](https://aws.amazon.com/s3/storage-classes/)
- [Hosting a static website using Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/WebsiteHosting.html)
- [Blocking public access to your Amazon S3 storage](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html)
- [Security best practices for Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html)
- [Amazon EBS volume types](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html)
- [What is Amazon EFS?](https://docs.aws.amazon.com/efs/latest/ug/whatisefs.html)
- [Introduction to backups in Amazon RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithAutomatedBackups.html)
- [Password management with Amazon RDS and AWS Secrets Manager](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html)
- [What is Amazon DynamoDB?](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html) and [Point-in-time recovery](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Point-in-time-recovery.html)
