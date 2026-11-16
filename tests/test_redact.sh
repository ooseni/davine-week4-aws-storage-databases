#!/usr/bin/env bash
# Tests for the redact() filter in scripts/lib.sh: no account ID, signed-in user or public
# address may reach a transcript, the lab's own 10.40 addresses must stay readable, and nothing
# else may be mangled. Run: bash tests/test_redact.sh
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source <(sed -n '/^redact()/,/^}/p' "$here/scripts/lib.sh")

failures=0
expect() {
    local input=$1 want=$2 got
    got=$(redact <<<"$input")
    if [[ "$got" == "$want" ]]; then
        echo "  PASS  $want"
    else
        echo "  FAIL  $input -> $got (wanted $want)"; failures=$((failures + 1))
    fi
}
expect "arn:aws:iam::123456789012:role/x" "arn:aws:iam::<ACCOUNT_ID>:role/x"
expect "owners 123456789012,123456789012" "owners <ACCOUNT_ID>,<ACCOUNT_ID>"
expect "arn:aws:rds:us-east-1:123456789012:snapshot:davine-wk4-postgres-review" "arn:aws:rds:us-east-1:<ACCOUNT_ID>:snapshot:davine-wk4-postgres-review"
expect "arn:aws:dynamodb:us-east-1:123456789012:table/davine-wk4-carts/backup/01763200000123-0a1b2c3d" "arn:aws:dynamodb:us-east-1:<ACCOUNT_ID>:table/davine-wk4-carts/backup/01763200000123-0a1b2c3d"
expect "epoch-ms 1763200000123 stays" "epoch-ms 1763200000123 stays"
expect "sg-0ff08272ab2054f231080289494 stays" "sg-0ff08272ab2054f231080289494 stays"
expect "[id=123456789012]" "[id=<ACCOUNT_ID>]"
expect "s3://davine-wk4-site-a1b2c3 and 10.40.11.25" "s3://davine-wk4-site-a1b2c3 and 10.40.11.25"
expect "range 10.40.0.0/16, subnets 10.40.11.0/24,10.40.12.0/24" "range 10.40.0.0/16, subnets 10.40.11.0/24,10.40.12.0/24"
expect "172.31.20.7 10.0.3.4 192.168.1.1" "<PRIVATE_IP> <PRIVATE_IP> <PRIVATE_IP>"
expect "no (52.94.236.248)" "no (<PUBLIC_IP>)"
expect "110.40.1.1 is public" "<PUBLIC_IP> is public"
expect "0.0.0.0/0 127.0.0.1" "0.0.0.0/0 127.0.0.1"
expect "assumed-role/AWSReservedSSO_AdministratorAccess_0abc/someone@example.com x" "assumed-role/<ROLE>/<USER> x"
expect "Terraform v1.17.1, aws-cli/2.39.7, postgres 17.4" "Terraform v1.17.1, aws-cli/2.39.7, postgres 17.4"
expect "2 x Electric kettle 24.99 49.98" "2 x Electric kettle 24.99 49.98"
echo "== redact: $failures failures"
[[ "$failures" -eq 0 ]]
