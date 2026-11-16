"""Unit tests for scripts/storage_review.py. Run: python3 -m unittest discover -s tests -v"""
import copy
import io
import json
import os
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
import storage_review as sr  # noqa: E402


def load(name):
    with open(os.path.join(HERE, "fixtures", name), encoding="utf-8") as fh:
        return json.load(fh)


def rules(findings):
    return [f.rule for f in findings]


class Fixtures(unittest.TestCase):
    def setUp(self):
        self.baseline = load("baseline.json")
        self.hardened = load("hardened.json")
        self.site = copy.deepcopy(self.hardened["buckets"][0])
        self.data = copy.deepcopy(self.hardened["buckets"][1])
        self.db = copy.deepcopy(self.hardened["db_instances"][0])
        self.snaps = copy.deepcopy(self.hardened["db_snapshots"])
        self.table = copy.deepcopy(self.hardened["tables"][0])


class WholeDesigns(Fixtures):
    def test_baseline_needs_changes(self):
        found = sr.review(self.baseline)
        self.assertEqual(rules(sr.needs_fixing(found)), ["S3-01", "RDS-04", "S3-03", "S3-04", "S3-05", "S3-07"])

    def test_baseline_names_every_exposed_object(self):
        exposed = next(f for f in sr.review(self.baseline) if f.rule == "S3-01")
        self.assertEqual(exposed.severity, "HIGH")
        self.assertIn("5 internal object(s)", exposed.message)
        self.assertIn("documents/customer-export.csv", exposed.message)
        self.assertNotIn("index.html", exposed.message)

    def test_hardened_has_nothing_to_fix(self):
        found = sr.review(self.hardened)
        self.assertEqual(sr.needs_fixing(found), [])
        self.assertEqual(rules(found), ["DDB-02", "RDS-05", "RDS-06", "S3-08"])

    def test_findings_are_sorted_most_severe_first(self):
        severities = [f.severity for f in sr.review(self.baseline)]
        self.assertEqual(severities, sorted(severities, key=sr.SEVERITIES.index))

    def test_empty_snapshot_is_clean(self):
        self.assertEqual(sr.review({}), [])


class AnonymousAccess(Fixtures):
    def test_website_objects_are_public(self):
        self.assertTrue(sr.anonymous_can(self.site, "s3:GetObject", "index.html"))

    def test_website_bucket_cannot_be_listed_or_written(self):
        self.assertFalse(sr.anonymous_can(self.site, "s3:ListBucket"))
        self.assertFalse(sr.anonymous_can(self.site, "s3:PutObject", "defaced.html"))
        self.assertFalse(sr.anonymous_can(self.site, "s3:DeleteObject", "index.html"))

    def test_data_bucket_objects_are_not_public(self):
        self.assertFalse(sr.anonymous_can(self.data, "s3:GetObject", "documents/invoice-2026-08.txt"))

    def test_no_policy_means_no_anonymous_access(self):
        self.site["policy"] = None
        self.assertFalse(sr.anonymous_can(self.site, "s3:GetObject", "index.html"))

    def test_restrict_public_buckets_overrides_a_public_policy(self):
        self.site["public_access_block"]["RestrictPublicBuckets"] = True
        self.assertFalse(sr.anonymous_can(self.site, "s3:GetObject", "index.html"))

    def test_explicit_deny_beats_allow(self):
        self.site["policy"]["Statement"].append(
            {"Effect": "Deny", "Principal": "*", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::davine-wk4-site-a1b2c3/private/*"})
        self.assertFalse(sr.anonymous_can(self.site, "s3:GetObject", "private/a.txt"))
        self.assertTrue(sr.anonymous_can(self.site, "s3:GetObject", "index.html"))

    def test_prefix_scoped_allow_leaves_other_prefixes_private(self):
        self.site["policy"]["Statement"][0]["Resource"] = "arn:aws:s3:::davine-wk4-site-a1b2c3/public/*"
        self.assertTrue(sr.anonymous_can(self.site, "s3:GetObject", "public/a.css"))
        self.assertFalse(sr.anonymous_can(self.site, "s3:GetObject", "documents/a.txt"))

    def test_principal_forms(self):
        statement = self.site["policy"]["Statement"][0]
        for principal, expected in (({"AWS": "*"}, True), ({"AWS": ["*"]}, True),
                                    ({"AWS": "arn:aws:iam::111122223333:root"}, False),
                                    ({"Service": "cloudfront.amazonaws.com"}, False)):
            statement["Principal"] = principal
            self.assertEqual(sr.anonymous_can(self.site, "s3:GetObject", "index.html"), expected, principal)

    def test_action_wildcards_and_case(self):
        statement = self.site["policy"]["Statement"][0]
        for action in ("s3:*", "s3:Get*", "S3:getobject", ["s3:ListBucket", "s3:GetObject"]):
            statement["Action"] = action
            self.assertTrue(sr.anonymous_can(self.site, "s3:GetObject", "index.html"), action)

    def test_allow_with_an_unknown_condition_is_not_counted_as_public(self):
        self.site["policy"]["Statement"][0]["Condition"] = {"IpAddress": {"aws:SourceIp": "203.0.113.0/24"}}
        self.assertFalse(sr.anonymous_can(self.site, "s3:GetObject", "index.html"))

    def test_tls_only_allow_depends_on_the_transport(self):
        self.site["policy"]["Statement"][0]["Condition"] = {"Bool": {"aws:SecureTransport": "true"}}
        self.assertTrue(sr.anonymous_can(self.site, "s3:GetObject", "index.html", secure_transport=True))
        self.assertFalse(sr.anonymous_can(self.site, "s3:GetObject", "index.html", secure_transport=False))


class BucketRules(Fixtures):
    def test_anonymous_write_is_high(self):
        self.site["policy"]["Statement"][0]["Action"] = "s3:*"
        found = sr.review_bucket(self.site)
        self.assertIn("S3-02", rules(found))
        self.assertIn("s3:PutObject, s3:DeleteObject", next(f for f in found if f.rule == "S3-02").message)

    def test_anonymous_list_is_high(self):
        self.site["policy"]["Statement"].append(
            {"Effect": "Allow", "Principal": "*", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::davine-wk4-site-a1b2c3"})
        self.assertIn("S3-02", rules(sr.review_bucket(self.site)))

    def test_suspended_versioning_counts_as_off(self):
        self.data["versioning"] = "Suspended"
        self.assertEqual(rules(sr.needs_fixing(sr.review_bucket(self.data))), ["S3-03"])

    def test_missing_tls_deny_is_flagged(self):
        self.data["policy"] = None
        self.assertEqual(rules(sr.needs_fixing(sr.review_bucket(self.data))), ["S3-04"])

    def test_tls_deny_that_misses_a_folder_is_flagged(self):
        self.data["policy"]["Statement"][0]["Resource"] = "arn:aws:s3:::davine-wk4-data-a1b2c3/documents/*"
        self.assertEqual(rules(sr.needs_fixing(sr.review_bucket(self.data))), ["S3-04"])

    def test_a_deny_without_a_condition_is_not_a_tls_rule(self):
        del self.data["policy"]["Statement"][0]["Condition"]
        self.assertIn("S3-04", rules(sr.review_bucket(self.data)))

    def test_each_block_public_access_setting_matters(self):
        for key in sr.BPA_KEYS:
            bucket = copy.deepcopy(self.data)
            bucket["public_access_block"][key] = False
            found = sr.needs_fixing(sr.review_bucket(bucket))
            self.assertEqual(rules(found), ["S3-05"], key)
            self.assertIn(key, found[0].message)

    def test_missing_block_public_access_is_flagged(self):
        self.data["public_access_block"] = None
        self.assertEqual(rules(sr.needs_fixing(sr.review_bucket(self.data))), ["S3-05"])

    def test_missing_encryption_and_lifecycle_are_low(self):
        self.data["encryption"] = None
        self.data["lifecycle_rules"] = 0
        found = sr.needs_fixing(sr.review_bucket(self.data))
        self.assertEqual([(f.rule, f.severity) for f in found], [("S3-07", "LOW"), ("S3-06", "LOW")])

    def test_an_untagged_object_is_treated_as_internal(self):
        self.site["objects"].append({"key": "notes.txt", "storage_class": "STANDARD", "classification": None})
        self.assertIn("S3-01", rules(sr.review_bucket(self.site)))

    def test_website_only_bucket_gets_a_note_not_a_finding(self):
        found = sr.review_bucket(self.site)
        self.assertEqual([(f.rule, f.severity) for f in found], [("S3-08", "NOTE")])


class DatabaseRules(Fixtures):
    def test_public_database_is_high(self):
        self.db["PubliclyAccessible"] = True
        self.assertEqual(rules(sr.needs_fixing(sr.review_db_instance(self.db, self.snaps))), ["RDS-01"])

    def test_unencrypted_database_is_high(self):
        self.db["StorageEncrypted"] = False
        self.assertEqual(rules(sr.needs_fixing(sr.review_db_instance(self.db, self.snaps))), ["RDS-02"])

    def test_backups_off_is_high(self):
        self.db["BackupRetentionPeriod"] = 0
        self.assertEqual(rules(sr.needs_fixing(sr.review_db_instance(self.db, self.snaps))), ["RDS-03"])

    def test_no_manual_snapshot_is_medium(self):
        found = sr.needs_fixing(sr.review_db_instance(self.db, []))
        self.assertEqual([(f.rule, f.severity) for f in found], [("RDS-04", "MEDIUM")])

    def test_automated_or_other_instances_snapshots_do_not_count(self):
        snaps = [dict(self.snaps[0], SnapshotType="automated"), dict(self.snaps[0], DBInstanceIdentifier="another-db")]
        self.assertIn("RDS-04", rules(sr.review_db_instance(self.db, snaps)))

    def test_multi_az_and_deletion_protection_clear_the_notes(self):
        self.db.update(MultiAZ=True, DeletionProtection=True)
        self.assertEqual(sr.review_db_instance(self.db, self.snaps), [])

    def test_table_without_point_in_time_recovery_is_medium(self):
        self.table["pitr"] = False
        self.assertEqual(rules(sr.needs_fixing(sr.review_table(self.table))), ["DDB-01"])

    def test_protected_table_is_clean(self):
        self.table["deletion_protection"] = True
        self.assertEqual(sr.review_table(self.table), [])


class CommandLine(Fixtures):
    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = sr.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_baseline_exits_1_with_a_verdict(self):
        code, out, _ = self.run_cli(os.path.join(HERE, "fixtures", "baseline.json"))
        self.assertEqual(code, 1)
        self.assertIn("Verdict: CHANGES NEEDED (1 high, 4 medium, 1 low, 3 note)", out)

    def test_hardened_exits_0_with_a_verdict(self):
        code, out, _ = self.run_cli(os.path.join(HERE, "fixtures", "hardened.json"))
        self.assertEqual(code, 0)
        self.assertIn("Verdict: NOTHING TO FIX (0 high, 0 medium, 0 low, 4 note)", out)

    def test_json_output_parses(self):
        code, out, _ = self.run_cli("--json", os.path.join(HERE, "fixtures", "baseline.json"))
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(out)[0]["rule"], "S3-01")

    def test_unreadable_snapshot_exits_2(self):
        code, _, err = self.run_cli(os.path.join(HERE, "fixtures", "missing.json"))
        self.assertEqual(code, 2)
        self.assertIn("cannot read snapshot", err)


if __name__ == "__main__":
    unittest.main()
