#!/usr/bin/env python3
"""Review a snapshot of S3, RDS and DynamoDB settings and list what should change.

The week 4 hands-on asks for a review of the storage setup that finds a security or reliability
improvement. This does the review the same way every time, so "before" and "after" can be
compared: it reads one JSON snapshot (written by scripts/lib.sh from read-only AWS calls) and
prints findings by severity.

    python3 scripts/storage_review.py .live/snapshot.json
    python3 scripts/storage_review.py --json .live/snapshot.json

Exit status: 0 when there is nothing to fix (notes are allowed), 1 when there are findings,
2 when the snapshot cannot be read.

Standard library only. It never calls AWS.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import sys
from dataclasses import asdict, dataclass

SEVERITIES = ("HIGH", "MEDIUM", "LOW", "NOTE")  # NOTE = accepted in a lab, listed for production
BPA_KEYS = ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")


@dataclass(frozen=True)
class Finding:
    rule: str
    severity: str
    resource: str
    message: str
    fix: str


# --- S3 bucket policy evaluation, for an anonymous caller ---------------------------------------


def _as_list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def _is_everyone(principal) -> bool:
    """True when a statement's Principal means "anyone, signed in or not"."""
    if principal == "*":
        return True
    if isinstance(principal, dict):
        return "*" in _as_list(principal.get("AWS"))
    return False


def _matches(patterns, value: str, ignore_case: bool = False) -> bool:
    for pattern in _as_list(patterns):
        if ignore_case and fnmatch.fnmatchcase(value.lower(), pattern.lower()):
            return True
        if not ignore_case and fnmatch.fnmatchcase(value, pattern):
            return True
    return False


def _condition_holds(condition, secure_transport: bool):
    """True or False when the condition can be decided, None when it cannot.

    Only aws:SecureTransport is understood. Any other condition key (a source IP, a VPC
    endpoint, an organisation ID) narrows the statement in a way this review cannot check.
    """
    if not condition:
        return True
    if list(condition) != ["Bool"] or [k.lower() for k in condition["Bool"]] != ["aws:securetransport"]:
        return None
    wanted = str(next(iter(condition["Bool"].values()))).lower() == "true"
    return wanted == secure_transport


def anonymous_can(bucket: dict, action: str, key: str | None = None, secure_transport: bool = True) -> bool:
    """Would S3 let an anonymous request do `action` on this bucket (key=None) or object?

    Follows S3's order: Block Public Access first, then an explicit Deny, then an Allow.
    A statement with a condition this review cannot decide is skipped: an undecidable Allow is
    not counted as public, and an undecidable Deny is not counted as protection.
    """
    policy = bucket.get("policy") or {}
    statements = _as_list(policy.get("Statement"))
    arn = "arn:aws:s3:::" + bucket["name"] + ("/" + key if key is not None else "")

    def applies(statement) -> bool:
        return (
            _is_everyone(statement.get("Principal"))
            and _matches(statement.get("Action"), action, ignore_case=True)
            and _matches(statement.get("Resource"), arn)
            and _condition_holds(statement.get("Condition"), secure_transport) is True
        )

    if any(s.get("Effect") == "Deny" and applies(s) for s in statements):
        return False
    allowed = any(s.get("Effect") == "Allow" and applies(s) for s in statements)
    if allowed and (bucket.get("public_access_block") or {}).get("RestrictPublicBuckets"):
        return False  # S3 ignores a public policy for anonymous callers when this is on
    return allowed


def _denies_plain_http(bucket: dict, key: str) -> bool:
    """True when a bucket policy statement refuses s3:GetObject on `key` over plain HTTP."""
    arn = "arn:aws:s3:::%s/%s" % (bucket["name"], key)
    for statement in _as_list((bucket.get("policy") or {}).get("Statement")):
        if (
            statement.get("Effect") == "Deny"
            and _is_everyone(statement.get("Principal"))
            and _matches(statement.get("Action"), "s3:GetObject", ignore_case=True)
            and _matches(statement.get("Resource"), arn)
            and statement.get("Condition")
            and _condition_holds(statement["Condition"], secure_transport=False) is True
            and _condition_holds(statement["Condition"], secure_transport=True) is False
        ):
            return True
    return False


# --- Rules --------------------------------------------------------------------------------------


def review_bucket(bucket: dict) -> list[Finding]:
    name = "s3://" + bucket["name"]
    objects = bucket.get("objects", [])
    internal = [o["key"] for o in objects if o.get("classification") != "public"]
    found: list[Finding] = []

    exposed = sorted(k for k in internal if anonymous_can(bucket, "s3:GetObject", k))
    if exposed:
        found.append(Finding(
            "S3-01", "HIGH", name,
            "%d internal object(s) can be downloaded by anyone on the internet: %s" % (len(exposed), ", ".join(exposed)),
            "Move internal objects to a bucket with no public policy and all four Block Public Access settings on.",
        ))

    writable = [a for a in ("s3:PutObject", "s3:DeleteObject") if anonymous_can(bucket, a, "any-key")]
    if anonymous_can(bucket, "s3:ListBucket"):
        writable.append("s3:ListBucket")
    if writable:
        found.append(Finding(
            "S3-02", "HIGH", name,
            "Anonymous callers are allowed: %s" % ", ".join(writable),
            "A public website needs s3:GetObject only. Remove every other anonymous action.",
        ))

    if internal:
        if bucket.get("versioning") != "Enabled":
            found.append(Finding(
                "S3-03", "MEDIUM", name,
                "Versioning is off, so an overwrite or delete of an internal object cannot be undone.",
                "Enable versioning, with a lifecycle rule that expires old versions.",
            ))
        if not all(_denies_plain_http(bucket, k) for k in internal):
            found.append(Finding(
                "S3-04", "MEDIUM", name,
                "Internal objects can be requested over plain HTTP.",
                "Add a bucket policy that denies every request where aws:SecureTransport is false.",
            ))
        block = bucket.get("public_access_block") or {}
        missing = [k for k in BPA_KEYS if not block.get(k)]
        if missing:
            found.append(Finding(
                "S3-05", "MEDIUM", name,
                "Block Public Access is not fully on for a bucket that holds internal objects (off: %s)." % ", ".join(missing),
                "Turn on all four Block Public Access settings.",
            ))
        if not bucket.get("lifecycle_rules"):
            found.append(Finding(
                "S3-07", "LOW", name,
                "No lifecycle rule: objects stay in their first storage class and old versions are kept for ever.",
                "Add transitions to cheaper classes and an expiry for noncurrent versions.",
            ))

    if not bucket.get("encryption"):
        found.append(Finding(
            "S3-06", "LOW", name,
            "No default encryption setting is recorded for the bucket.",
            "Set default encryption to SSE-S3 or SSE-KMS explicitly.",
        ))

    if bucket.get("website") and not internal:
        found.append(Finding(
            "S3-08", "NOTE", name,
            "Public website bucket: the S3 website endpoint serves HTTP only.",
            "In production, keep the bucket private behind CloudFront with origin access control and HTTPS.",
        ))
    return found


def review_db_instance(db: dict, snapshots: list[dict]) -> list[Finding]:
    name = "rds:" + db["DBInstanceIdentifier"]
    found: list[Finding] = []
    if db.get("PubliclyAccessible"):
        found.append(Finding("RDS-01", "HIGH", name, "The database has a public address.",
                             "Set PubliclyAccessible to false and keep it in private subnets."))
    if not db.get("StorageEncrypted"):
        found.append(Finding("RDS-02", "HIGH", name, "Storage is not encrypted at rest.",
                             "Encryption can only be chosen at creation: restore an encrypted copy of a snapshot."))
    if not db.get("BackupRetentionPeriod"):
        found.append(Finding("RDS-03", "HIGH", name, "Automated backups are off (retention is 0 days).",
                             "Set a backup retention period of at least 7 days."))
    mine = [s for s in snapshots
            if s.get("DBInstanceIdentifier") == db["DBInstanceIdentifier"] and s.get("SnapshotType") == "manual"]
    if not mine:
        found.append(Finding("RDS-04", "MEDIUM", name,
                             "No manual snapshot exists. Automated backups are deleted with the instance.",
                             "Take a manual snapshot: it is kept until someone deletes it."))
    if not db.get("MultiAZ"):
        found.append(Finding("RDS-05", "NOTE", name, "Single-AZ: an Availability Zone failure takes the database down.",
                             "In production, turn on Multi-AZ for a standby in a second zone."))
    if not db.get("DeletionProtection"):
        found.append(Finding("RDS-06", "NOTE", name, "Deletion protection is off, so the lab can be destroyed.",
                             "In production, turn deletion protection on."))
    return found


def review_table(table: dict) -> list[Finding]:
    name = "dynamodb:" + table["name"]
    found: list[Finding] = []
    if not table.get("pitr"):
        found.append(Finding("DDB-01", "MEDIUM", name, "Point-in-time recovery is off.",
                             "Enable point-in-time recovery to restore to any second of the last 35 days."))
    if not table.get("deletion_protection"):
        found.append(Finding("DDB-02", "NOTE", name, "Deletion protection is off, so the lab can be destroyed.",
                             "In production, turn deletion protection on."))
    return found


def review(snapshot: dict) -> list[Finding]:
    found: list[Finding] = []
    for bucket in snapshot.get("buckets", []):
        found += review_bucket(bucket)
    for db in snapshot.get("db_instances", []):
        found += review_db_instance(db, snapshot.get("db_snapshots", []))
    for table in snapshot.get("tables", []):
        found += review_table(table)
    return sorted(found, key=lambda f: (SEVERITIES.index(f.severity), f.rule, f.resource))


def needs_fixing(findings: list[Finding]) -> list[Finding]:
    return [f for f in findings if f.severity != "NOTE"]


# --- Output -------------------------------------------------------------------------------------


def render(findings: list[Finding]) -> str:
    lines = []
    for f in findings:
        lines.append("  %-6s %-7s %s" % (f.severity, f.rule, f.resource))
        lines.append("         %s" % f.message)
        lines.append("         fix: %s" % f.fix)
    counts = {s: sum(1 for f in findings if f.severity == s) for s in SEVERITIES}
    summary = ", ".join("%d %s" % (counts[s], s.lower()) for s in SEVERITIES)
    verdict = "CHANGES NEEDED" if needs_fixing(findings) else "NOTHING TO FIX"
    lines.append("Verdict: %s (%s)" % (verdict, summary))
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("snapshot", help="path to a snapshot JSON file")
    parser.add_argument("--json", action="store_true", help="print the findings as JSON")
    args = parser.parse_args(argv)
    try:
        with open(args.snapshot, encoding="utf-8") as fh:
            snapshot = json.load(fh)
    except (OSError, ValueError) as err:
        print("cannot read snapshot: %s" % err, file=sys.stderr)
        return 2
    findings = review(snapshot)
    if args.json:
        print(json.dumps([asdict(f) for f in findings], indent=1))
    else:
        print(render(findings))
    return 1 if needs_fixing(findings) else 0


if __name__ == "__main__":
    sys.exit(main())
