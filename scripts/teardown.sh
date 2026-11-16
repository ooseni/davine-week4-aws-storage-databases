#!/usr/bin/env bash
# Remove everything the lab created, then prove the account holds none of it.
#
# 1. Deletes the DynamoDB on-demand backup that verify_live.sh took (Terraform does not manage it).
# 2. Runs terraform destroy (buckets with every object version, database, snapshot, table, VPC).
# 3. Looks for leftovers by name: nothing may remain that could cost money.
#
# Usage: AWS_PROFILE=<profile> scripts/teardown.sh | tee docs/evidence/<name>.txt
#        scripts/teardown.sh --check-only     (skip steps 1 and 2)
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
exec > >(redact) 2>&1
export AWS_REGION="${AWS_REGION:-us-east-1}"
name=davine-wk4

echo "== Week 4 teardown ($(date -u '+%d %B %Y %H:%M UTC'), $AWS_REGION)"
if [[ "${1:-}" != --check-only ]]; then
    section "DynamoDB on-demand backups"
    for arn in $(aws dynamodb list-backups --table-name "$name-carts" --backup-type USER --query 'BackupSummaries[].BackupArn' --output text); do
        aws dynamodb delete-backup --backup-arn "$arn" --query 'BackupDescription.BackupDetails.BackupName' --output text | sed 's/^/  deleted backup /'
    done
    section "terraform destroy"
    terraform -chdir="$tf_dir" destroy -auto-approve -input=false -no-color | grep -E '^(Destroy complete|Error|No changes)|: Destruction complete' | sed -E 's/^/  /; s/ after [0-9ms]+.*$//'
fi

# RDS removes the instance's automated snapshots on its own a few minutes after the instance is
# gone (delete_automated_backups = true). The first teardown checked too early and counted one, so
# wait up to 10 minutes for them to clear, and say what is still there while waiting.
lab_snapshots() { aws rds describe-db-snapshots --query "DBSnapshots[?starts_with(DBInstanceIdentifier, '$name-')].[DBSnapshotIdentifier,SnapshotType,Status]" --output text; }
for _ in $(seq 1 40); do
    left=$(lab_snapshots)
    [[ -z "$left" ]] && break
    echo "  waiting for RDS to remove: $(tr '\t\n' ' ;' <<<"$left")"
    sleep 15
done

section "Leftover check"
check "S3 buckets named $name-*" 0 "$(aws s3api list-buckets --query "length(Buckets[?starts_with(Name, '$name-')])" --output text)"
check "RDS instances named $name-*" 0 "$(aws rds describe-db-instances --query "length(DBInstances[?starts_with(DBInstanceIdentifier, '$name-')])" --output text)"
check "RDS snapshots of $name-* (manual and automated)" 0 "$(aws rds describe-db-snapshots --query "length(DBSnapshots[?starts_with(DBInstanceIdentifier, '$name-')])" --output text)"
check "retained automated backups of $name-*" 0 "$(aws rds describe-db-instance-automated-backups --query "length(DBInstanceAutomatedBackups[?starts_with(DBInstanceIdentifier, '$name-')])" --output text)"
check "DB subnet groups named $name-*" 0 "$(aws rds describe-db-subnet-groups --query "length(DBSubnetGroups[?starts_with(DBSubnetGroupName, '$name-')])" --output text)"
check "Secrets Manager secrets tagged for the lab" 0 "$(aws secretsmanager list-secrets --include-planned-deletion --filters Key=tag-value,Values=davine-week4-aws-storage-databases --query 'length(SecretList)' --output text)"
check "DynamoDB tables named $name-*" 0 "$(aws dynamodb list-tables --query "length(TableNames[?starts_with(@, '$name-')])" --output text)"
check "DynamoDB backups of $name-carts" 0 "$(aws dynamodb list-backups --table-name "$name-carts" --query 'length(BackupSummaries)' --output text)"
check "VPCs named $name-vpc" 0 "$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$name-vpc" --query 'length(Vpcs)' --output text)"
check "security groups named $name-*" 0 "$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$name-*" --query 'length(SecurityGroups)' --output text)"
check "resources left in the Terraform state" 0 "$(terraform -chdir="$tf_dir" state list 2>/dev/null | wc -l)"

summary "Teardown"
