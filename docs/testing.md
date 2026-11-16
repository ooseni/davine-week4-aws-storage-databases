# Testing

**Davine Technologies Internship Project, AWS Cloud internship week 4.** Two layers: checks that run on every push with no AWS credentials, and checks that ran against the live stack on 16 November 2026.

## On every push (GitHub Actions, pinned Docker images)

| Step | Tool and version | Result |
|---|---|---|
| Workflow lint | actionlint 1.7.8 | no issues |
| Storage review unit tests | Python 3.14.2, unittest | 39 of 39 pass |
| Shell lint | ShellCheck 0.11.0 | no issues in 4 scripts |
| Redaction tests | bash | 16 of 16 pass |
| No database password in code | grep guard | pass |
| Format, validate, test | Terraform 1.17.1, mocked AWS provider | 25 of 25 pass |
| Lint | TFLint 0.66.0 | 0 issues |
| Security scan | Checkov 3.4.3 | 59 passed, 0 failed, 26 skipped with a written reason each |
| Security scan | Trivy 0.76.2 | 0 findings, 11 ignores with a written reason each |
| Secret scan of the history | gitleaks 8.30.1 | no leaks |

### The 25 Terraform tests

[`terraform/tests/storage.tftest.hcl`](../terraform/tests/storage.tftest.hcl) plans the configuration against a mocked AWS provider and asserts one decision per test:

- **Website bucket (5):** the policy grants anonymous `s3:GetObject` on that bucket's objects and nothing else; public ACLs stay blocked while the policy is allowed; index and error documents are set; the three objects carry browser-friendly content types; ACLs are disabled on both buckets.
- **Data bucket (5):** all four Block Public Access settings are on; versioning is enabled; both buckets encrypt at rest; the policy denies every request without TLS and allows nothing; the three lifecycle rules do what the report says.
- **Stages (4):** hardened puts the folders in the private bucket; each folder keeps its storage class; baseline has no data bucket, no versioning and no manual snapshot; an unknown stage is rejected.
- **Network (3):** two private subnets in two zones with a local-only route table; the database rule is port 5432 from a security group, never an address range; the default security group is empty.
- **RDS (5):** private, encrypted gp3 PostgreSQL on db.t4g.micro; no password in code and RDS manages it; 7 days of backups with tags copied to snapshots; a retention of 0 is rejected; hardened takes the named manual snapshot.
- **DynamoDB (3):** on-demand with the composite key; point-in-time recovery and TTL on; three sample items with numbers stored as numbers.

**Do the tests catch real mistakes?** I broke a copy of the Terraform five ways and ran the suite each time. Every break failed exactly one test:

| Break | Test that failed |
|---|---|
| database made publicly accessible | `database_is_private_and_encrypted` |
| website policy widened to `s3:*` | `site_policy_grants_anonymous_get_object_and_nothing_else` |
| one Block Public Access setting turned off on the data bucket | `data_bucket_blocks_all_public_access` |
| point-in-time recovery turned off | `cart_table_has_point_in_time_recovery_and_ttl` |
| database rule changed from the app security group to the VPC range | `database_accepts_postgresql_from_the_app_group_only` |

### The 39 storage review tests

[`tests/test_storage_review.py`](../tests/test_storage_review.py) runs [`scripts/storage_review.py`](../scripts/storage_review.py) against two fixtures, [`baseline.json`](../tests/fixtures/baseline.json) and [`hardened.json`](../tests/fixtures/hardened.json), and variations of them:

- **Whole designs (5):** the baseline needs six changes and names all five exposed objects; the hardened design has nothing to fix; findings are sorted by severity; an empty snapshot is clean.
- **Anonymous access (11):** website objects are public but the bucket cannot be listed or written; no policy means no access; `RestrictPublicBuckets` overrides a public policy; an explicit deny beats an allow; a prefix-scoped allow leaves other prefixes private; four forms of `Principal`; action wildcards and case; an allow with a condition the script cannot decide is not counted as public; a TLS-only allow depends on the transport.
- **Bucket rules (11):** anonymous write or list is high; suspended versioning counts as off; a missing TLS deny, one that misses a folder, or one with no condition is flagged; each of the four Block Public Access settings matters; missing encryption and lifecycle are low; an untagged object is treated as internal; a website-only bucket gets a note.
- **Database rules (8):** public, unencrypted or backup-less databases are high; no manual snapshot is medium, and automated snapshots or another instance's snapshots do not count; Multi-AZ and deletion protection clear the notes; a table without point-in-time recovery is medium.
- **Command line (4):** exit codes 0, 1 and 2, the verdict line, and JSON output.

### The 16 redaction cases

[`tests/test_redact.sh`](../tests/test_redact.sh) feeds known lines through the redactor used by every live script. It replaces account IDs (alone, in ARNs, in lists), public addresses, private addresses outside the lab and the assumed-role session name. It leaves alone the lab's `10.40` addresses, bucket names, version numbers, timestamps, prices, and resource IDs that happen to contain twelve digits in a row.

## Live on AWS, 16 November 2026 (us-east-1)

Every check is a real request made by [`scripts/verify_live.sh`](../scripts/verify_live.sh): anonymous HTTP from my machine, read-only describe calls, one DynamoDB item written and removed, and one S3 object overwritten, deleted and restored. Output is redacted as it prints.

| Run | Time (UTC) | Result | Transcript |
|---|---|---|---|
| Baseline: `terraform apply -var stage=baseline`, 32 resources | 09:03 | **52 passed, 0 failed** | [verify-baseline-2026-11-16.txt](evidence/verify-baseline-2026-11-16.txt) |
| Hardened: `terraform apply`, 13 added, 5 destroyed | 09:20 | **67 passed, 0 failed** | [verify-hardened-2026-11-16.txt](evidence/verify-hardened-2026-11-16.txt) |
| Teardown: `scripts/teardown.sh`, 40 resources destroyed | 10:45 | 10 passed, **1 failed** | [teardown-2026-11-16.txt](evidence/teardown-2026-11-16.txt) |
| Teardown leftover check, run again | 10:54 | **11 passed, 0 failed** | same file, second run |

### What the baseline run showed

- **The weekly task works.** The website answers 200 with `text/html`, a missing page gets 404 with the custom error document, and anonymous list, upload and delete are refused with 403. Each of the five uploaded files has the storage class chosen for it.
- **The finding.** `documents/customer-export.csv` came back with HTTP 200 to a request with no credentials. The review script listed all five internal files as exposed and exited 1.
- **The databases were sound from the start.** RDS: available, PostgreSQL 17, not public, encrypted gp3, 7 days of backups, password managed by Secrets Manager, one inbound rule (5432 from the app security group), no outbound rules, `rds.force_ssl` 1, an endpoint that resolves to a `10.40` address and does not answer from the internet. DynamoDB: active, on-demand, point-in-time recovery and TTL on, a query, a strongly consistent read after write, a refused conditional overwrite and an atomic counter.

### What the hardened run showed

- **The leak is closed.** The same file returns 404 from the website endpoint and 403 from the data bucket. All four Block Public Access settings are on and the policy status is `IsPublic: False`.
- **TLS is enforced.** A signed request succeeds over HTTPS and is refused with 403 over plain HTTP.
- **Recovery works.** With versioning on, I overwrote `documents/invoice-2026-08.txt`, then deleted it (404). Two versions and one delete marker were kept. Removing the marker and the bad version brought the original back with the same checksum and the same version ID.
- **Backups exist.** The manual RDS snapshot is available, manual and encrypted. The DynamoDB on-demand backup is `AVAILABLE`.
- **The review is clean.** 0 high, 0 medium, 0 low, 4 notes, exit 0. `terraform plan` afterwards reports no changes.

### What the live run does not cover

- **No SQL was run.** Nothing in the lab can reach port 5432, by design. The database checks are about its configuration, network and backups.
- **No restore was performed** from the RDS snapshot or the DynamoDB backup. A restore creates a new instance or table and was outside the near-free budget. The S3 recovery drill is the one restore that was exercised end to end.
- **Lifecycle transitions were not observed.** They act after 30 and 90 days. The run confirms the rules exist and are enabled.

### The teardown

`teardown.sh` deleted the DynamoDB on-demand backup, ran `terraform destroy` (40 resources) and then searched the account by name for S3 buckets, RDS instances, snapshots, retained backups and subnet groups, Secrets Manager secrets, DynamoDB tables and backups, VPCs and security groups.

The first search, a minute after the destroy, still found one RDS snapshot. It was most likely the instance's automated backup, which RDS deletes by itself shortly after the instance (`delete_automated_backups = true`). Nine minutes later it was gone without any action from me, and the second search passed 11 of 11. The script now waits up to 10 minutes for RDS before it searches.

Cost: the RDS instance ran for about two hours. At on-demand prices that is about US$0.05 including storage and the Secrets Manager secret; S3, DynamoDB and the VPC cost next to nothing at this size. This is an estimate from published prices, not a billed figure.

### The first hardened run failed, and why

The first run against the hardened stage stopped part way with one failed check and one CLI error. The causes were two mistakes in my verify script and one in the Terraform (details in the README under Mistakes I fixed). No AWS resource was changed by the failed run. After the fixes the run above passed 67 of 67.
