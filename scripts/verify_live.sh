#!/usr/bin/env bash
# Live checks against the deployed stack. Works for both stages and says which one it found:
#   baseline  proves the weekly task works, and records what the review found wrong with it
#   hardened  proves the fix: internal files private and recoverable, backups taken
#
# Everything is a real request: anonymous HTTP from this machine, read-only describe calls, one
# DynamoDB item written and removed, and (hardened) one S3 object overwritten, deleted and
# brought back from its versions. Output is redacted as it is printed.
#
# Usage: AWS_PROFILE=<profile> scripts/verify_live.sh | tee docs/evidence/<name>.txt
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
exec > >(redact) 2>&1
load_outputs

echo "== Week 4 live verification, stage: $stage ($(date -u '+%d %B %Y %H:%M UTC'), $AWS_REGION)"
echo "   caller: $(aws sts get-caller-identity --query Arn --output text)"
echo "   tools: $(terraform version | head -n 1), $(aws --version | cut -d' ' -f1)"

s3_rest="https://$site_bucket.s3.$AWS_REGION.amazonaws.com"
leak_key="documents/customer-export.csv"

section "S3 static website ($website_url)"
check "home page status" 200 "$(http_code "$website_url/")"
check "home page content type" "text/html; charset=utf-8" "$(curl -s -m 15 -o /dev/null -w '%{content_type}' "$website_url/")"
check "home page text" 1 "$(curl -s -m 15 "$website_url/" | grep -c 'Served straight from Amazon S3')"
check "stylesheet status" 200 "$(http_code "$website_url/styles.css")"
check "missing page status" 404 "$(http_code "$website_url/no-such-page")"
check "missing page shows the custom error document" 1 "$(curl -s -m 15 "$website_url/no-such-page" | grep -c 'That page is not here')"

section "Website bucket access settings (s3://$site_bucket)"
check "anonymous listing of the bucket" 403 "$(http_code "$s3_rest/")"
check "anonymous upload" 403 "$(http_code -X PUT --data 'defaced' "$s3_rest/defaced.html")"
check "anonymous delete" 403 "$(http_code -X DELETE "$s3_rest/index.html")"
check "home page still there after the delete attempt" 200 "$(http_code "$website_url/")"
check "ACLs disabled (object ownership)" BucketOwnerEnforced "$(aws s3api get-bucket-ownership-controls --bucket "$site_bucket" --query 'OwnershipControls.Rules[0].ObjectOwnership' --output text)"
check "public ACLs blocked" "True True" "$(aws s3api get-public-access-block --bucket "$site_bucket" --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls]' --output text | tr '\t' ' ')"
check "default encryption" AES256 "$(aws s3api get-bucket-encryption --bucket "$site_bucket" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)"

section "Uploaded folders and storage classes (s3://$internal_bucket)"
check "folders" "backups/ documents/ images/ logs/" "$(aws s3api list-objects-v2 --bucket "$internal_bucket" --delimiter / --query 'CommonPrefixes[].Prefix' --output text | tr '\t' ' ')"
while IFS=$'\t' read -r key class; do
    # S3 leaves StorageClass out of the reply for STANDARD
    got=$(aws s3api head-object --bucket "$internal_bucket" --key "$key" --query 'StorageClass' --output text)
    check "storage class of $key" "$class" "${got/None/STANDARD}"
done < <(python3 -c 'import json,sys; [print(k, v, sep="\t") for k, v in sorted(json.loads(sys.argv[1]).items())]' "$internal_keys")

if [[ "$stage" == baseline ]]; then
    section "Review of the baseline: what is wrong with one public bucket"
    code=$(http_code "$website_url/$leak_key")
    if [[ "$code" == 200 ]]; then
        finding "anyone can download $leak_key: HTTP $code from the website endpoint, no credentials"
        finding "first line served: $(curl -s -m 15 "$website_url/$leak_key" | head -n 1)"
    fi
    check "internal file is publicly readable (the problem to fix)" 200 "$code"
    check "versioning status (empty means never enabled)" "" "$(aws s3api get-bucket-versioning --bucket "$site_bucket" --query 'Status' --output text | sed 's/^None$//')"
else
    section "After the fix: internal files are private (s3://$data_bucket)"
    data_rest="https://$data_bucket.s3.$AWS_REGION.amazonaws.com"
    check "internal file through the website endpoint" 404 "$(http_code "$website_url/$leak_key")"
    check "internal file from the data bucket, anonymous HTTPS" 403 "$(http_code "$data_rest/$leak_key")"
    check "anonymous listing of the data bucket" 403 "$(http_code "$data_rest/")"
    check "Block Public Access, all four settings" "True True True True" "$(aws s3api get-public-access-block --bucket "$data_bucket" --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text | tr '\t' ' ')"
    check "bucket policy status: IsPublic" False "$(aws s3api get-bucket-policy-status --bucket "$data_bucket" --query 'PolicyStatus.IsPublic' --output text)"
    check "default encryption" AES256 "$(aws s3api get-bucket-encryption --bucket "$data_bucket" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)"
    check "lifecycle rules" "age-documents-to-cheaper-classes expire-old-logs tidy-old-versions-and-failed-uploads" "$(aws s3api get-bucket-lifecycle-configuration --bucket "$data_bucket" --query 'Rules[].ID' --output text | tr '\t' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
    check "signed request over HTTPS" ok "$(aws s3api head-object --bucket "$data_bucket" --key "$leak_key" >/dev/null 2>&1 && echo ok || echo refused)"
    # The same signed request over plain HTTP must be refused by the aws:SecureTransport statement.
    plain=$(aws s3api head-object --bucket "$data_bucket" --key "$leak_key" --endpoint-url "http://s3.$AWS_REGION.amazonaws.com" 2>&1 || true)
    check "signed request over plain HTTP" 403 "$(grep -oE '\(403\)' <<<"$plain" | tr -d '()' | head -n 1)"

    section "Recovery drill: overwrite and delete a file, then bring it back from its versions"
    drill_key="documents/invoice-2026-08.txt"
    original="$tf_dir/sample-data/$drill_key"
    sha() { sha256sum | cut -c1-16; }
    want=$(sha <"$original")
    check "versioning status" Enabled "$(aws s3api get-bucket-versioning --bucket "$data_bucket" --query 'Status' --output text)"
    good_version=$(aws s3api head-object --bucket "$data_bucket" --key "$drill_key" --query 'VersionId' --output text)
    check "file matches the original before the drill" "$want" "$(aws s3 cp "s3://$data_bucket/$drill_key" - | sha)"
    printf 'overwritten by mistake\n' >"$live_dir/bad-upload.txt" # put-object needs a real file, not a pipe
    bad_version=$(aws s3api put-object --bucket "$data_bucket" --key "$drill_key" --body "$live_dir/bad-upload.txt" --query 'VersionId' --output text)
    check "after the overwrite the file no longer matches" differs "$([[ "$(aws s3 cp "s3://$data_bucket/$drill_key" - | sha)" == "$want" ]] && echo same || echo differs)"
    marker=$(aws s3api delete-object --bucket "$data_bucket" --key "$drill_key" --query 'VersionId' --output text)
    gone=$(aws s3api head-object --bucket "$data_bucket" --key "$drill_key" 2>&1 || true)
    check "after the delete the file is gone" 404 "$(grep -oE '\(404\)' <<<"$gone" | tr -d '()' | head -n 1)"
    check "versions kept (2) and delete markers (1)" "2 1" "$(aws s3api list-object-versions --bucket "$data_bucket" --prefix "$drill_key" --query '[length(Versions), length(DeleteMarkers)]' --output text | tr '\t' ' ')"
    # Recovery: remove the delete marker and the bad version, which makes the good version current again.
    aws s3api delete-object --bucket "$data_bucket" --key "$drill_key" --version-id "$marker" >/dev/null
    aws s3api delete-object --bucket "$data_bucket" --key "$drill_key" --version-id "$bad_version" >/dev/null
    check "restored file matches the original" "$want" "$(aws s3 cp "s3://$data_bucket/$drill_key" - | sha)"
    check "the current version is the original one again" "$good_version" "$(aws s3api head-object --bucket "$data_bucket" --key "$drill_key" --query 'VersionId' --output text)"
fi

section "Amazon RDS for PostgreSQL ($db_id)"
db() { aws rds describe-db-instances --db-instance-identifier "$db_id" --query "DBInstances[0].$1" --output text; }
check "status" available "$(db DBInstanceStatus)"
check "engine and major version" "postgres 17" "$(db '[Engine,EngineVersion]' | tr '\t' ' ' | sed -E 's/\.[0-9]+$//')"
check "instance class" db.t4g.micro "$(db DBInstanceClass)"
check "publicly accessible" False "$(db PubliclyAccessible)"
check "storage: type, GiB, encrypted" "gp3 20 True" "$(db '[StorageType,AllocatedStorage,StorageEncrypted]' | tr '\t' ' ')"
check "automated backup retention (days)" 7 "$(db BackupRetentionPeriod)"
check "master password managed by Secrets Manager" active "$(db MasterUserSecret.SecretStatus)"
check "IAM database authentication" True "$(db IAMDatabaseAuthenticationEnabled)"
check "subnet group spans two Availability Zones" 2 "$(db 'DBSubnetGroup.Subnets[].SubnetAvailabilityZone.Name' | tr '\t' '\n' | sort -u | wc -l)"
check "internet gateways attached to the database VPC" 0 "$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc_id" --query 'length(InternetGateways)' --output text)"
check "database security group: inbound rules" 1 "$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$db_sg" --query 'length(SecurityGroupRules[?!IsEgress])' --output text)"
check "the one inbound rule: protocol, port, source" "tcp 5432 $app_sg" "$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$db_sg" --query 'SecurityGroupRules[?!IsEgress].[IpProtocol,FromPort,ReferencedGroupInfo.GroupId]' --output text | tr '\t' ' ')"
check "database security group: outbound rules" 0 "$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$db_sg" --query 'length(SecurityGroupRules[?IsEgress])' --output text)"
check "TLS required by the parameter group (rds.force_ssl)" 1 "$(aws rds describe-db-parameters --db-parameter-group-name "$(db 'DBParameterGroups[0].DBParameterGroupName')" --query "Parameters[?ParameterName=='rds.force_ssl'].ParameterValue" --output text)"
resolved=$(getent ahostsv4 "$db_address" | awk 'NR==1 {print $1}')
check "endpoint resolves inside the VPC range 10.40.0.0/16" yes "$([[ "$resolved" =~ ^10\.40\.1[12]\. ]] && echo yes || echo "no ($resolved)")"
check "endpoint reachable from the internet on 5432" no "$(timeout 6 bash -c "exec 3<>/dev/tcp/$db_address/5432" 2>/dev/null && echo yes || echo no)"
check "automated backups taken so far (at least 1)" yes "$([[ "$(aws rds describe-db-snapshots --db-instance-identifier "$db_id" --snapshot-type automated --query 'length(DBSnapshots)' --output text)" -ge 1 ]] && echo yes || echo no)"
if [[ "$stage" == hardened ]]; then
    check "manual snapshot: status, type, encrypted" "available manual True" "$(aws rds describe-db-snapshots --db-snapshot-identifier "$db_snapshot" --query 'DBSnapshots[0].[Status,SnapshotType,Encrypted]' --output text | tr '\t' ' ')"
else
    check "manual snapshots (none yet in the baseline)" 0 "$(aws rds describe-db-snapshots --db-instance-identifier "$db_id" --snapshot-type manual --query 'length(DBSnapshots)' --output text)"
fi

section "Amazon DynamoDB ($table)"
tbl() { aws dynamodb describe-table --table-name "$table" --query "Table.$1" --output text; }
check "status" ACTIVE "$(tbl TableStatus)"
check "billing mode" PAY_PER_REQUEST "$(tbl BillingModeSummary.BillingMode)"
check "key schema" "customer_id HASH sku RANGE" "$(tbl 'KeySchema[].[AttributeName,KeyType]' | tr '\t\n' '  ' | sed 's/ $//')"
check "encrypted at rest" yes "$([[ "$(tbl SSEDescription.Status)" =~ ^(ENABLED|None)$ ]] && echo yes || echo no)"
check "point-in-time recovery" ENABLED "$(aws dynamodb describe-continuous-backups --table-name "$table" --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' --output text)"
check "TTL: status and attribute" "ENABLED expires_at" "$(aws dynamodb describe-time-to-live --table-name "$table" --query 'TimeToLiveDescription.[TimeToLiveStatus,AttributeName]' --output text | tr '\t' ' ')"
check "query: items in the cart of CUST-1001" 2 "$(aws dynamodb query --table-name "$table" --consistent-read --key-condition-expression 'customer_id = :c' --expression-attribute-values '{":c":{"S":"CUST-1001"}}' --query 'Count' --output text)"
check "query: quantity of SKU-MUG in that cart" 4 "$(aws dynamodb get-item --table-name "$table" --consistent-read --key '{"customer_id":{"S":"CUST-1001"},"sku":{"S":"SKU-MUG"}}' --query 'Item.quantity.N' --output text)"
probe='{"customer_id":{"S":"CUST-9999"},"sku":{"S":"SKU-PROBE"}}'
aws dynamodb put-item --table-name "$table" --item '{"customer_id":{"S":"CUST-9999"},"sku":{"S":"SKU-PROBE"},"quantity":{"N":"1"}}' --condition-expression 'attribute_not_exists(customer_id)'
check "write then strongly consistent read" 1 "$(aws dynamodb get-item --table-name "$table" --consistent-read --key "$probe" --query 'Item.quantity.N' --output text)"
dup=$(aws dynamodb put-item --table-name "$table" --item '{"customer_id":{"S":"CUST-9999"},"sku":{"S":"SKU-PROBE"},"quantity":{"N":"99"}}' --condition-expression 'attribute_not_exists(customer_id)' 2>&1 || true)
check "conditional write refuses to overwrite an existing item" ConditionalCheckFailedException "$(grep -o 'ConditionalCheckFailedException' <<<"$dup" | head -n 1)"
check "atomic counter update (1 + 2)" 3 "$(aws dynamodb update-item --table-name "$table" --key "$probe" --update-expression 'ADD quantity :n' --expression-attribute-values '{":n":{"N":"2"}}' --return-values UPDATED_NEW --query 'Attributes.quantity.N' --output text)"
aws dynamodb delete-item --table-name "$table" --key "$probe"
check "probe item removed" None "$(aws dynamodb get-item --table-name "$table" --consistent-read --key "$probe" --query 'Item.quantity.N' --output text)"
if [[ "$stage" == hardened ]]; then
    backup_name="$table-review"
    if [[ "$(aws dynamodb list-backups --table-name "$table" --backup-type USER --query "length(BackupSummaries[?BackupName=='$backup_name'])" --output text)" == 0 ]]; then
        aws dynamodb create-backup --table-name "$table" --backup-name "$backup_name" >/dev/null
    fi
    for _ in $(seq 1 30); do
        state=$(aws dynamodb list-backups --table-name "$table" --backup-type USER --query "BackupSummaries[?BackupName=='$backup_name'] | [0].BackupStatus" --output text)
        [[ "$state" == AVAILABLE ]] && break
        sleep 4
    done
    check "on-demand backup $backup_name" AVAILABLE "$state"
fi

section "Storage review (scripts/storage_review.py on a fresh snapshot)"
snapshot "$live_dir/snapshot-$stage.json"
review_rc=0
python3 "$here/scripts/storage_review.py" "$live_dir/snapshot-$stage.json" || review_rc=$?
if [[ "$stage" == baseline ]]; then
    check "review exit status (1 = changes needed)" 1 "$review_rc"
else
    check "review exit status (0 = nothing to fix)" 0 "$review_rc"
fi

summary "Stage $stage"
