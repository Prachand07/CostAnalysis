#!/usr/bin/env bash
# Sets up CUR 2.0 with Athena from the CLI: the S3 bucket, the Data Export, a Glue
# database, an Athena workgroup and a table with partition projection.
# Dry run by default; pass --apply to create. Existing resources are left untouched.
# See README.md for usage.

set -euo pipefail

REGION=ap-south-1
PREFIX=cur2
EXPORT_NAME=cur2-daily
DATABASE=cur
TABLE=cur2
WORKGROUP=cur
RESULTS=""
GRANULARITY=DAILY
SCAN_LIMIT_GB=100
RANGE_START=$(date -u +%Y-%m)
TAGS=""
BUCKET=""
APPLY=false

usage() {
  cat <<'EOF'
Usage: AWS_PROFILE=<payer-profile> ./general.sh --bucket <name> [options] [--apply]

  --bucket NAME         S3 bucket for the export (required); created if missing
  --region REGION       Region for the bucket, Glue and Athena   [ap-south-1]
  --prefix PREFIX       S3 prefix inside the bucket              [cur2]
  --export NAME         Export name                              [cur2-daily]
  --database NAME       Glue database                            [cur]
  --table NAME          Athena table                             [cur2]
  --workgroup NAME      Athena workgroup                         [cur]
  --results S3URI       Athena results location                  [s3://<bucket>/athena-results/]
  --granularity G       DAILY or HOURLY                          [DAILY]
  --scan-limit-gb N     Per-query data-scanned limit in GB       [100]
  --range-start YYYY-MM First month the table reads              [current month]
  --tags k1,k2          Cost allocation tag keys to activate
  --apply               Create the resources (default is a dry run)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)        BUCKET=$2; shift 2 ;;
    --region)        REGION=$2; shift 2 ;;
    --prefix)        PREFIX=$2; shift 2 ;;
    --export)        EXPORT_NAME=$2; shift 2 ;;
    --database)      DATABASE=$2; shift 2 ;;
    --table)         TABLE=$2; shift 2 ;;
    --workgroup)     WORKGROUP=$2; shift 2 ;;
    --results)       RESULTS=$2; shift 2 ;;
    --granularity)   GRANULARITY=$2; shift 2 ;;
    --scan-limit-gb) SCAN_LIMIT_GB=$2; shift 2 ;;
    --range-start)   RANGE_START=$2; shift 2 ;;
    --tags)          TAGS=$2; shift 2 ;;
    --apply)         APPLY=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
# run: execute with --apply, otherwise print the command.
run()  { if $APPLY; then "$@"; else printf '    [dry run] '; printf '%q ' "$@"; echo; fi; }

# ── Validate input ────────────────────────────────────────────────────────────
[[ -n "$BUCKET" ]] || die "--bucket is required"
[[ "$GRANULARITY" == DAILY || "$GRANULARITY" == HOURLY ]] || die "--granularity must be DAILY or HOURLY"
[[ "$RANGE_START" =~ ^[0-9]{4}-[0-9]{2}$ ]] || die "--range-start must be YYYY-MM"
# Athena identifiers: lowercase letters, digits, underscore. A hyphen breaks unquoted SQL.
for n in "$DATABASE" "$TABLE"; do
  [[ "$n" =~ ^[a-z0-9_]+$ ]] || die "Glue database/table names must be lowercase letters, digits or _: '$n'"
done
command -v aws >/dev/null     || die "aws CLI not found"
command -v python3 >/dev/null || die "python3 not found"

PREFIX=${PREFIX#/}; PREFIX=${PREFIX%/}
RESULTS=${RESULTS:-s3://$BUCKET/athena-results/}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
info "Account $ACCOUNT · region $REGION · $([[ $APPLY == true ]] && echo APPLY || echo 'DRY RUN (nothing is created)')"

PAYER=$(aws organizations describe-organization --query Organization.MasterAccountId --output text 2>/dev/null || echo "")
if [[ -n "$PAYER" && "$PAYER" != "$ACCOUNT" ]]; then
  echo "    WARNING: this is not the payer account ($PAYER). The export will hold only this account's spend."
fi

# The export writes to s3://<bucket>/<prefix>/<export-name>/data/BILLING_PERIOD=YYYY-MM/
DATA_PATH="${PREFIX:+$PREFIX/}$EXPORT_NAME/data"
LOCATION="s3://$BUCKET/$DATA_PATH/"

# The bucket policy Data Exports needs to write the export.
cat > "$WORK/policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "EnableAWSDataExportsToWriteToS3AndCheckPolicy",
    "Effect": "Allow",
    "Principal": {"Service": ["billingreports.amazonaws.com", "bcm-data-exports.amazonaws.com"]},
    "Action": ["s3:PutObject", "s3:GetBucketPolicy"],
    "Resource": ["arn:aws:s3:::$BUCKET", "arn:aws:s3:::$BUCKET/*"],
    "Condition": {"StringLike": {
      "aws:SourceAccount": "$ACCOUNT",
      "aws:SourceArn": ["arn:aws:cur:us-east-1:$ACCOUNT:definition/*",
                        "arn:aws:bcm-data-exports:us-east-1:$ACCOUNT:export/*"]
    }}
  }]
}
EOF

# The export definition and the Athena table, both built from the export's own schema.
TABLE_PROPS="INCLUDE_RESOURCES=TRUE,INCLUDE_SPLIT_COST_ALLOCATION_DATA=TRUE,INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY=FALSE,TIME_GRANULARITY=$GRANULARITY"

# The export's SQL must name every column; get-table returns them for these settings.
aws bcm-data-exports get-table --region us-east-1 --table-name COST_AND_USAGE_REPORT \
    --table-properties "$TABLE_PROPS" --output json > "$WORK/schema.json"

python3 - "$WORK" "$EXPORT_NAME" "$BUCKET" "$PREFIX" "$REGION" "$GRANULARITY" \
          "$DATABASE" "$TABLE" "$DATA_PATH" "$RANGE_START" <<'PY'
import json, sys
work, export, bucket, prefix, region, gran, db, table, data_path, start = sys.argv[1:]
cols = json.load(open(f"{work}/schema.json"))["Schema"]

# The export definition.
export_def = {"Export": {
    "Name": export,
    "Description": "CUR 2.0 for Athena",
    "DataQuery": {
        "QueryStatement": "SELECT " + ", ".join(c["Name"] for c in cols)
                          + " FROM COST_AND_USAGE_REPORT",
        "TableConfigurations": {"COST_AND_USAGE_REPORT": {
            "INCLUDE_RESOURCES": "TRUE",
            "INCLUDE_SPLIT_COST_ALLOCATION_DATA": "TRUE",
            "INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY": "FALSE",
            "TIME_GRANULARITY": gran}}},
    "DestinationConfigurations": {"S3Destination": {
        "S3Bucket": bucket, "S3Prefix": prefix, "S3Region": region,
        "S3OutputConfigurations": {"OutputType": "CUSTOM", "Format": "PARQUET",
                                   "Compression": "PARQUET", "Overwrite": "OVERWRITE_REPORT"}}},
    "RefreshCadence": {"Frequency": "SYNCHRONOUS"}}}
json.dump(export_def, open(f"{work}/export.json", "w"), indent=1)

# The Athena table. get-table reports String/Number/Timestamp/Map; these columns are
# written with a different type than that simple mapping gives (checked against an export's
# manifest), and a wrong type fails any query that reads the column.
base = {"String": "string", "Number": "double", "Timestamp": "timestamp",
        "Map": "map<string,string>"}
override = {"savings_plan_savings_plan_rate": "double",
            "savings_plan_amortized_upfront_commitment_for_billing_period": "double",
            "discount": "map<string,double>"}
lines = ",\n".join(f"  `{c['Name']}` {override.get(c['Name'], base[c['Type']])}" for c in cols)
loc = f"s3://{bucket}/{data_path}/"   # same as $LOCATION
ddl = f"""CREATE EXTERNAL TABLE IF NOT EXISTS {db}.{table} (
{lines}
)
PARTITIONED BY (billing_period string)
STORED AS PARQUET
LOCATION '{loc}'
TBLPROPERTIES (
  'projection.enabled' = 'true',
  'projection.billing_period.type' = 'date',
  'projection.billing_period.format' = 'yyyy-MM',
  'projection.billing_period.range' = '{start},NOW',
  'projection.billing_period.interval' = '1',
  'projection.billing_period.interval.unit' = 'MONTHS',
  'storage.location.template' = '{loc}BILLING_PERIOD=${{billing_period}}/'
)"""
open(f"{work}/table.sql", "w").write(ddl)
# What an existing table is checked against.
json.dump({"columns": {c["Name"]: override.get(c["Name"], base[c["Type"]]) for c in cols},
           "template": f"{loc}BILLING_PERIOD=${{billing_period}}/"},
          open(f"{work}/expected_table.json", "w"))
print(f"    export schema: {len(cols)} columns")
PY

# ── 0. Check existing resources ───────────────────────────────────────────────
# Anything that already exists must match this run, or the table would point somewhere the
# export doesn't write. Stop before creating anything if it doesn't.
info "0. Checking existing resources"
EXISTING_EXPORT=$(aws bcm-data-exports list-exports --region us-east-1 \
    --query "Exports[?ExportName=='$EXPORT_NAME'].ExportArn | [0]" --output text)
[[ "$EXISTING_EXPORT" == "None" ]] && EXISTING_EXPORT=""
BUCKET_EXISTS=false
aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 && BUCKET_EXISTS=true

if $BUCKET_EXISTS && aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text \
     > "$WORK/existing_policy.json" 2>/dev/null; then
  # put-bucket-policy replaces the whole policy, so an existing one is never overwritten.
  # The export's ARN: the real one if it exists, else the shape a new one will have.
  EXPORT_ARN_FOR_CHECK=${EXISTING_EXPORT:-arn:aws:bcm-data-exports:us-east-1:$ACCOUNT:export/$EXPORT_NAME-00000000-0000-0000-0000-000000000000}
  if ! python3 - "$WORK/existing_policy.json" "$BUCKET" "$DATA_PATH" "$ACCOUNT" "$EXPORT_ARN_FOR_CHECK" <<'PY'
import json, sys
from fnmatch import fnmatchcase
pol, bucket, data_path, account, export_arn = json.load(open(sys.argv[1])), *sys.argv[2:]
as_list = lambda v: v if isinstance(v, list) else [v]
obj = f"arn:aws:s3:::{bucket}/{data_path}/BILLING_PERIOD=2000-01/file.parquet"
context = {"aws:sourceaccount": account, "aws:sourcearn": export_arn}

def conditions_allow(cond):
    # Every operator and key must be satisfied. Only the conditions Data Exports' requests
    # can be judged on are understood; anything else can't be verified, so it doesn't count.
    for op, keys in (cond or {}).items():
        for key, values in keys.items():
            have = context.get(key.lower())
            if have is None:
                return False
            if op in ("StringEquals", "ArnEquals"):
                ok = have in as_list(values)
            elif op == "StringEqualsIgnoreCase":
                ok = have.lower() in [v.lower() for v in as_list(values)]
            elif op in ("StringLike", "ArnLike"):
                ok = any(fnmatchcase(have, v) for v in as_list(values))
            else:
                return False
            if not ok:
                return False
    return True

def grants(s):
    if s.get("Effect") != "Allow":
        return False
    p = s.get("Principal", {})
    services = as_list(p.get("Service", [])) if isinstance(p, dict) else []
    return ("bcm-data-exports.amazonaws.com" in services
            and any(fnmatchcase("s3:PutObject", a) for a in as_list(s.get("Action", [])))
            and any(fnmatchcase(obj, r) for r in as_list(s.get("Resource", [])))
            and conditions_allow(s.get("Condition")))

sys.exit(0 if any(grants(s) for s in as_list(pol.get("Statement", []))) else 1)
PY
  then
    sed 's/^/      /' "$WORK/policy.json"
    die "Bucket $BUCKET has a policy that doesn't let this export write to it (no Allow for
       bcm-data-exports.amazonaws.com on s3:PutObject whose resource and SourceAccount /
       SourceArn conditions match). Merge the statement above into the policy, then re-run."
  fi
fi

if [[ -n "$EXISTING_EXPORT" ]]; then
  aws bcm-data-exports get-export --region us-east-1 --export-arn "$EXISTING_EXPORT" \
      --output json > "$WORK/existing_export.json"
  python3 - "$WORK/existing_export.json" "$BUCKET" "$PREFIX" "$REGION" "$GRANULARITY" <<'PY' \
    || die "Export '$EXPORT_NAME' already exists with different settings (above). Use another --export name, or match its settings."
import json, sys
e, bucket, prefix, region, gran = json.load(open(sys.argv[1]))["Export"], *sys.argv[2:]
d = e["DestinationConfigurations"]["S3Destination"]
c = e["DataQuery"].get("TableConfigurations", {}).get("COST_AND_USAGE_REPORT", {})
checks = {
    "S3 bucket": (d.get("S3Bucket"), bucket),
    "S3 prefix": ((d.get("S3Prefix") or "").strip("/"), prefix),
    "S3 region": (d.get("S3Region"), region),
    "format": (d.get("S3OutputConfigurations", {}).get("Format"), "PARQUET"),
    "granularity": (c.get("TIME_GRANULARITY"), gran),
    "resource IDs": (c.get("INCLUDE_RESOURCES"), "TRUE"),
    "split cost allocation data": (c.get("INCLUDE_SPLIT_COST_ALLOCATION_DATA"), "TRUE"),
}
bad = {k: v for k, v in checks.items() if v[0] != v[1]}
for k, (have, want) in bad.items():
    print(f"    {k}: existing export has {have!r}, this run expects {want!r}")
sys.exit(1 if bad else 0)
PY
fi

if aws glue get-table --region "$REGION" --database-name "$DATABASE" --name "$TABLE" \
     --output json > "$WORK/existing_table.json" 2>/dev/null; then
  python3 - "$WORK/existing_table.json" "$LOCATION" "$WORK/expected_table.json" <<'PY' \
    || die "Table $DATABASE.$TABLE already exists and doesn't match this export (above). Use another --table name, or fix the table."
import json, sys
tbl, want_loc = json.load(open(sys.argv[1]))["Table"], sys.argv[2]
expected = json.load(open(sys.argv[3]))
norm = lambda s: s.replace(" ", "").lower()
bad = []
have_loc = tbl.get("StorageDescriptor", {}).get("Location", "").rstrip("/") + "/"
if have_loc != want_loc:
    bad.append(f"location: existing table reads {have_loc}, this run's export writes {want_loc}")
parts = [k["Name"] for k in tbl.get("PartitionKeys", [])]
if parts != ["billing_period"]:
    bad.append(f"partitions: existing table has {parts}, expected ['billing_period']")
have_cols = {c["Name"].lower(): c["Type"] for c in tbl.get("StorageDescriptor", {}).get("Columns", [])}
for name, typ in expected["columns"].items():
    if name.lower() not in have_cols:
        bad.append(f"column {name}: missing from the existing table")
    elif norm(have_cols[name.lower()]) != norm(typ):
        bad.append(f"column {name}: existing type {have_cols[name.lower()]}, the export writes {typ}")
params = tbl.get("Parameters", {})
for key, want in {"projection.enabled": "true",
                  "projection.billing_period.type": "date",
                  "projection.billing_period.format": "yyyy-MM",
                  "storage.location.template": expected["template"]}.items():
    if params.get(key) != want:
        bad.append(f"table property {key}: existing {params.get(key)!r}, expected {want!r}")
for line in bad:
    print("    " + line)
extra = sorted(set(have_cols) - {n.lower() for n in expected["columns"]})
if extra and not bad:
    print(f"    note: the existing table has {len(extra)} extra column(s) this export doesn't write: {', '.join(extra)}")
sys.exit(1 if bad else 0)
PY
fi
echo "    ok"

# ── 1. Bucket + policy ────────────────────────────────────────────────────────
info "1. S3 bucket s3://$BUCKET"
if $BUCKET_EXISTS; then
  if [[ -s "$WORK/existing_policy.json" ]]; then
    echo "    exists, and its policy lets Data Exports write — left as is."
  else
    echo "    exists, with no bucket policy."
    run aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$WORK/policy.json"
  fi
else
  if [[ "$REGION" == us-east-1 ]]; then
    run aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    run aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=$REGION"
  fi
  run aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  run aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$WORK/policy.json"
fi

# ── 2. CUR 2.0 export ─────────────────────────────────────────────────────────
info "2. CUR 2.0 export '$EXPORT_NAME' ($GRANULARITY, resource IDs, split cost allocation data)"
if [[ -n "$EXISTING_EXPORT" ]]; then
  echo "    exists with matching settings — left as is."
else
  run aws bcm-data-exports create-export --region us-east-1 --cli-input-json "file://$WORK/export.json"
fi

# ── 3. Glue database ──────────────────────────────────────────────────────────
info "3. Glue database '$DATABASE'"
if aws glue get-database --region "$REGION" --name "$DATABASE" >/dev/null 2>&1; then
  echo "    exists — left as is."
else
  run aws glue create-database --region "$REGION" --database-input "Name=$DATABASE"
fi

# ── 4. Athena workgroup ───────────────────────────────────────────────────────
info "4. Athena workgroup '$WORKGROUP' (results $RESULTS, limit ${SCAN_LIMIT_GB} GB per query)"
CUTOFF=$((SCAN_LIMIT_GB * 1024 * 1024 * 1024))
if aws athena get-work-group --region "$REGION" --work-group "$WORKGROUP" \
     --output json > "$WORK/existing_workgroup.json" 2>/dev/null; then
  echo "    exists — left as is."
  python3 - "$WORK/existing_workgroup.json" "$RESULTS" "$CUTOFF" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))["WorkGroup"].get("Configuration", {})
want_out, want_cutoff = sys.argv[2], int(sys.argv[3])
have_out = cfg.get("ResultConfiguration", {}).get("OutputLocation")
if (have_out or "").rstrip("/") != want_out.rstrip("/"):
    print(f"    WARNING: its results location is {have_out!r}, not {want_out!r}")
if not cfg.get("EnforceWorkGroupConfiguration"):
    print("    WARNING: it doesn't enforce its settings, so a query can override the results location")
have_cutoff = cfg.get("BytesScannedCutoffPerQuery")
if have_cutoff != want_cutoff:
    shown = f"{have_cutoff / 1024**3:g} GB" if have_cutoff else "none"
    print(f"    WARNING: its per-query scan limit is {shown}, not {want_cutoff / 1024**3:g} GB")
PY
else
  run aws athena create-work-group --region "$REGION" --name "$WORKGROUP" --configuration \
      "ResultConfiguration={OutputLocation=$RESULTS},EnforceWorkGroupConfiguration=true,BytesScannedCutoffPerQuery=$CUTOFF,PublishCloudWatchMetricsEnabled=true"
fi

# ── 5. Athena table ───────────────────────────────────────────────────────────
info "5. Athena table $DATABASE.$TABLE over $LOCATION"
if [[ -s "$WORK/existing_table.json" ]]; then
  echo "    exists and reads the same location — left as is."
elif $APPLY; then
  QID=$(aws athena start-query-execution --region "$REGION" --work-group "$WORKGROUP" \
        --query-string "$(cat "$WORK/table.sql")" --query QueryExecutionId --output text)
  while :; do
    STATE=$(aws athena get-query-execution --region "$REGION" --query-execution-id "$QID" \
            --query QueryExecution.Status.State --output text)
    [[ "$STATE" == SUCCEEDED || "$STATE" == FAILED || "$STATE" == CANCELLED ]] && break
    sleep 2
  done
  [[ "$STATE" == SUCCEEDED ]] || die "CREATE TABLE $STATE: $(aws athena get-query-execution --region "$REGION" \
      --query-execution-id "$QID" --query QueryExecution.Status.StateChangeReason --output text)"
  echo "    created."
else
  cp "$WORK/table.sql" "./${TABLE}_create_table.sql"
  echo "    [dry run] would run the CREATE TABLE written to ./${TABLE}_create_table.sql"
fi

# ── 6. Cost allocation tags ───────────────────────────────────────────────────
if [[ -n "$TAGS" ]]; then
  info "6. Activate cost allocation tags: $TAGS"
  ARGS=()
  IFS=',' read -ra KEYS <<< "$TAGS"
  for k in "${KEYS[@]}"; do ARGS+=("TagKey=$k,Status=Active"); done
  # A tag key can only be activated after it has appeared in billing data (up to 24h after
  # first use). Activation applies from that day on.
  run aws ce update-cost-allocation-tags-status --region us-east-1 --cost-allocation-tags-status "${ARGS[@]}"
fi

# ── Console-only step + next steps ────────────────────────────────────────────
cat <<EOF

==> Manual step (no CLI): turn on Split cost allocation data for ECS/EKS in
    Billing and Cost Management -> Cost Management Preferences.

==> After the first delivery (up to 24 hours), check it:
    aws bcm-data-exports list-executions --region us-east-1 --export-arn <export arn>
    SELECT billing_period, COUNT(*) FROM $DATABASE.$TABLE GROUP BY 1;   -- in workgroup $WORKGROUP
EOF
