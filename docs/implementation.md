# Implementation | how the week was built, step by step

**Davine Technologies Internship Project, AWS Cloud internship week 4.** In August 2026 I did these steps by hand in the AWS console. This rebuild does the same work with Terraform so it can be tested, repeated and removed. Each step names the console path too, for anyone following along without Terraform.

## Before starting

- An AWS account and a short-lived session: `aws sso login --profile <admin-profile>`, then `export AWS_PROFILE=<admin-profile>`. No access keys are stored anywhere.
- Terraform 1.10 or newer, AWS CLI v2, Python 3, curl.
- Cost: S3, DynamoDB and the VPC are effectively free at this size. The RDS instance costs about 0.02 USD an hour while it exists, so run the teardown the same day.

```bash
cd terraform
terraform init
```

## Part 1: the weekly task (stage `baseline`)

```bash
terraform apply -var stage=baseline      # 32 resources, about 9 minutes (RDS is the slow one)
../scripts/verify_live.sh
```

| Step in the brief | In Terraform | In the console |
|---|---|---|
| Create an S3 bucket | `aws_s3_bucket.site`, with a random suffix for a unique name | S3, Create bucket |
| Upload files into folders | `aws_s3_object.internal`: keys under `documents/`, `images/`, `logs/`, `backups/` | Create folder, then Upload |
| Configure permissions | ownership controls (ACLs off), public access block, bucket policy | Permissions tab |
| Enable static website hosting | `aws_s3_bucket_website_configuration.site` with index and error documents | Properties tab, Static website hosting |
| Explore storage classes | each folder's objects set a different `storage_class` | Upload, Properties, Storage class |
| Create an RDS instance | `aws_db_instance.main` in a dedicated VPC with two private subnets | RDS, Create database |
| Create a DynamoDB table | `aws_dynamodb_table.carts` and three sample items | DynamoDB, Create table, then Explore items |

Decisions made in this part:

- **The website needs a public-read bucket policy.** The S3 website endpoint serves anonymous visitors, so two of the four Block Public Access settings are off on this bucket. Public ACLs stay blocked.
- **Content types are set on upload.** Without `text/html`, a browser downloads the page instead of showing it.
- **The database has no route to the internet.** Its VPC has no internet gateway. The security group accepts port 5432 from the application security group and has no outbound rules.
- **Terraform never sees the database password.** `manage_master_user_password = true` makes RDS create it and keep it in Secrets Manager.
- **DynamoDB is on-demand.** No capacity to guess, and no charge while idle.

In the baseline the uploaded folders sit in the same bucket as the website. That is how a first attempt at "one bucket, some folders, turn on hosting" usually ends up, and it is what the review in part 2 examines.

## Part 2: the hands-on review (stage `hardened`)

The review is a script, so the same questions are asked before and after:

```bash
python3 scripts/storage_review.py .live/snapshot-baseline.json    # written by verify_live.sh
```

Against the baseline it reported 1 high, 4 medium and 1 low finding. The high one: all five internal files could be downloaded by anyone, because the website's policy allows `s3:GetObject` on `<bucket>/*` and that covers every object in the bucket. I confirmed it with a plain `curl`.

**The decision: separate public content from private data, and make the private data recoverable.** One change of variable applies it:

```bash
terraform apply                           # stage defaults to hardened
../scripts/verify_live.sh
```

| What changes | Why |
|---|---|
| A second bucket, `davine-wk4-data-<suffix>`, with all four Block Public Access settings on | the internal folders get a home that cannot be made public by a policy mistake |
| The five internal objects move there; the website bucket keeps its three files | the public-read policy now covers only content meant to be public |
| Versioning on the data bucket | an overwrite or delete can be undone |
| A bucket policy that denies requests without TLS | data cannot travel in clear text, even with valid credentials |
| Three lifecycle rules | documents age into cheaper classes, logs expire, old versions do not pile up |
| A manual RDS snapshot, `davine-wk4-postgres-review` | automated backups are deleted with the instance; a manual snapshot is not |
| A DynamoDB on-demand backup, `davine-wk4-carts-review` (taken by `verify_live.sh`) | a named backup that is kept until deleted, next to point-in-time recovery |

Why I did not choose other options:

- **Narrowing the policy to a `public/` prefix in one bucket** would also stop the leak. I rejected it because the safety of the private files would still depend on one line of JSON staying correct, and Block Public Access could not be turned on for the bucket.
- **CloudFront with origin access control** is the better production design, since the bucket can then be fully private and served over HTTPS. The brief asks for S3 static website hosting itself, so CloudFront is listed under Lab vs production in the README.

## Part 3: verify, record, remove

```bash
scripts/verify_live.sh | tee docs/evidence/verify-hardened-<date>.txt    # every line is redacted as it prints
scripts/teardown.sh    | tee docs/evidence/teardown-<date>.txt
```

`teardown.sh` deletes the DynamoDB backup, runs `terraform destroy`, then checks by name that no bucket, database, snapshot, retained backup, secret, table, VPC or security group is left.

## What stays in the console on purpose

- **Looking at the result.** The screenshots in the README are console views of what Terraform built.
- **Reading the database password.** If I needed it, I would fetch it from Secrets Manager at the moment of use. I did not need it.
