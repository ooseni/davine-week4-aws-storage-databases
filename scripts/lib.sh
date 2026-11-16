#!/usr/bin/env bash
# Shared helpers for the live scripts. Source it; do not run it.
#
# Reads the stack's names from `terraform output`, counts PASS/FAIL checks, writes the JSON
# snapshot that scripts/storage_review.py reads, and redacts everything printed so transcripts
# can go straight into docs/evidence/.
# shellcheck shell=bash

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tf_dir="$here/terraform"
live_dir="$here/.live" # git-ignored: raw snapshots before redaction
mkdir -p "$live_dir"
export AWS_PAGER=""
export LC_ALL=C

# Redaction. The account ID becomes <ACCOUNT_ID>, the signed-in role and user become placeholders,
# and any public address becomes <PUBLIC_IP>. Addresses inside the lab's own range (10.40.0.0/16)
# stay readable: they are in the Terraform code. 0.0.0.0/0 and 127.0.0.1 stay readable too.
# An account ID is 12 digits with no letter or digit on either side, so the tail of a hex
# resource ID is left alone. The pattern consumes the character after the match, so it runs
# twice to catch a second match that shares it ("id,id").
redact() {
    local account='s/(^|[^0-9A-Za-z])[0-9]{12}([^0-9A-Za-z]|$)/\1<ACCOUNT_ID>\2/g'
    sed -u -E -e "$account" -e "$account" \
        -e "s#assumed-role/[^/ ]+/[^ \"]+#assumed-role/<ROLE>/<USER>#g" \
        -e "s/0\.0\.0\.0\/0/__ANY4__/g; s/127\.0\.0\.1/__LOOPBACK__/g" \
        -e "s/(^|[^0-9.])10\.40\.([0-9]{1,3})\.([0-9]{1,3})/\1__LAB_\2_\3__/g" \
        -e "s/(^|[^0-9.])(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}/\1<PRIVATE_IP>/g" \
        -e "s/(^|[^0-9.])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/\1<PUBLIC_IP>/g" \
        -e "s/__ANY4__/0.0.0.0\/0/g; s/__LOOPBACK__/127.0.0.1/g; s/__LAB_([0-9]+)_([0-9]+)__/10.40.\1.\2/g"
}

# --- PASS/FAIL bookkeeping ----------------------------------------------------------------------
passed=0
failed=0
section() { printf '\n== %s\n' "$1"; }
# check "what is being checked" EXPECTED ACTUAL
check() {
    if [[ "$3" == "$2" ]]; then
        printf '  PASS  %s: %s\n' "$1" "$3"; passed=$((passed + 1))
    else
        printf '  FAIL  %s: got "%s", wanted "%s"\n' "$1" "$3" "$2"; failed=$((failed + 1))
    fi
}
# finding "text": something the baseline is expected to get wrong. Recorded, not counted as a pass.
finding() { printf '  FOUND %s\n' "$1"; }
summary() {
    printf '\n== %s: %d passed, %d failed\n' "$1" "$passed" "$failed"
    [[ "$failed" -eq 0 ]]
}

# http_code URL [curl args]: status code of an anonymous request (000 when nothing answers)
http_code() { curl -s -o /dev/null -m 15 -w '%{http_code}' "$@" || true; }

load_outputs() {
    terraform -chdir="$tf_dir" output -json >"$live_dir/outputs.json" 2>/dev/null || true
    out() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2],{}).get("value",""); print(v if isinstance(v,str) else json.dumps(v))' "$live_dir/outputs.json" "$1"; }
    stage=$(out stage)
    if [[ -z "$stage" ]]; then
        echo "No Terraform outputs found: run terraform apply in terraform/ first." >&2
        exit 2
    fi
    # shellcheck disable=SC2034 # read by the scripts that source this file
    {
        AWS_REGION=$(out region); export AWS_REGION
        site_bucket=$(out site_bucket)
        data_bucket=$(out data_bucket)
        internal_bucket=$(out internal_bucket)
        website_url=$(out website_url)
        internal_keys=$(out internal_keys)
        vpc_id=$(out vpc_id)
        db_sg=$(out db_security_group_id)
        app_sg=$(out app_security_group_id)
        db_id=$(out db_identifier)
        db_address=$(out db_address)
        db_snapshot=$(out db_snapshot_identifier)
        table=$(out dynamodb_table)
    }
}

# snapshot DEST: the settings storage_review.py judges, gathered with read-only calls
snapshot() {
    python3 - "$1" "$stage" "$db_id" "$table" "$site_bucket" "$data_bucket" <<'PY'
import json, subprocess, sys

dest, stage, db_id, table, *buckets = sys.argv[1:]


def aws(*args, missing=None):
    """Run a read-only AWS CLI call. `missing` is returned when the setting does not exist."""
    run = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if run.returncode != 0:
        if missing is not None and any(code in run.stderr for code in (
                "NoSuchBucketPolicy", "NoSuchPublicAccessBlockConfiguration", "NoSuchWebsiteConfiguration",
                "NoSuchLifecycleConfiguration", "ServerSideEncryptionConfigurationNotFoundError", "NoSuchTagSet")):
            return missing
        sys.exit("aws %s failed: %s" % (" ".join(args), run.stderr.strip()))
    return json.loads(run.stdout) if run.stdout.strip() else {}


snap = {"stage": stage, "buckets": [], "tables": []}
for name in filter(None, buckets):
    b = ["--bucket", name]
    policy = aws("s3api", "get-bucket-policy", *b, missing={}).get("Policy")
    rules = aws("s3api", "get-bucket-encryption", *b, missing={}).get("ServerSideEncryptionConfiguration", {}).get("Rules", [])
    objects = []
    for o in aws("s3api", "list-objects-v2", *b).get("Contents", []):
        tags = {t["Key"]: t["Value"] for t in aws("s3api", "get-object-tagging", *b, "--key", o["Key"], missing={}).get("TagSet", [])}
        objects.append({"key": o["Key"], "storage_class": o.get("StorageClass", "STANDARD"), "classification": tags.get("DataClassification")})
    snap["buckets"].append({
        "name": name,
        "policy": json.loads(policy) if policy else None,
        "public_access_block": aws("s3api", "get-public-access-block", *b, missing={}).get("PublicAccessBlockConfiguration"),
        "versioning": aws("s3api", "get-bucket-versioning", *b).get("Status", ""),
        "encryption": rules[0]["ApplyServerSideEncryptionByDefault"]["SSEAlgorithm"] if rules else None,
        "website": bool(aws("s3api", "get-bucket-website", *b, missing={})),
        "lifecycle_rules": len(aws("s3api", "get-bucket-lifecycle-configuration", *b, missing={}).get("Rules", [])),
        "objects": objects,
    })
keep = ("DBInstanceIdentifier", "Engine", "PubliclyAccessible", "StorageEncrypted", "BackupRetentionPeriod", "MultiAZ", "DeletionProtection")
snap["db_instances"] = [{k: d.get(k) for k in keep}
                        for d in aws("rds", "describe-db-instances", "--db-instance-identifier", db_id)["DBInstances"]]
keep = ("DBSnapshotIdentifier", "DBInstanceIdentifier", "SnapshotType", "Status", "Encrypted")
snap["db_snapshots"] = [{k: s.get(k) for k in keep}
                        for s in aws("rds", "describe-db-snapshots", "--db-instance-identifier", db_id)["DBSnapshots"]]
t = aws("dynamodb", "describe-table", "--table-name", table)["Table"]
pitr = aws("dynamodb", "describe-continuous-backups", "--table-name", table)["ContinuousBackupsDescription"]
snap["tables"].append({
    "name": table,
    "billing_mode": t.get("BillingModeSummary", {}).get("BillingMode", "PROVISIONED"),
    "pitr": pitr["PointInTimeRecoveryDescription"]["PointInTimeRecoveryStatus"] == "ENABLED",
    "deletion_protection": bool(t.get("DeletionProtectionEnabled")),
})
with open(dest, "w") as fh:
    json.dump(snap, fh, indent=1)
PY
}
