# Querying AWS Cost and Usage Reports with Athena — a CLI Setup

AWS gives you a detailed bill as data: the **Cost and Usage Report (CUR) 2.0**, one row per line item, per resource, per day or hour, delivered to S3 as Parquet. Query it with SQL in Athena, no spreadsheet needed.

This post covers a single Bash script that sets up the entire pipeline — S3 bucket, CUR 2.0 export, Glue database, Athena workgroup, and a partition-projected table — from the CLI, on any account.

## What the script does

It creates five things, in order, and skips anything that already exists:

1. **An S3 bucket** for the export, with a bucket policy that lets AWS Data Exports write to it.
2. **A CUR 2.0 export** — daily, with resource IDs and split cost allocation data, in Parquet.
3. **A Glue database** for Athena's table metadata.
4. **An Athena workgroup** with a results location and a per-query data-scanned limit (so a runaway query can't rack up charges).
5. **An Athena table** with **partition projection** on `billing_period`, so new months appear automatically without adding partitions.

Optionally, it also activates cost allocation tags.

## Before you run it

You need:

- The **AWS CLI** installed and a named profile configured (`aws configure --profile <name>`).
- **Python 3** on your PATH (the script uses it to build the export definition and table DDL from the export's own schema).
- Run it in the **payer (management) account** to get every member account's spend in one table.

## Running it

The script is a **dry run by default** — it prints every command it would run without creating anything:

```bash
AWS_PROFILE=<payer-profile> ./general.sh --bucket <export-bucket>
```

When the output looks right, add `--apply` to create the resources:

```bash
AWS_PROFILE=<payer-profile> ./general.sh --bucket <export-bucket> --apply
```

The bucket name must be globally unique across all of S3. A common pattern is to append your account number:

```bash
AWS_PROFILE=1 ./general.sh --bucket cur2-export-123456789012 --apply
```

### Options

| Flag | Default | What it does |
|---|---|---|
| `--bucket` | *(required)* | S3 bucket for the export; created if missing |
| `--region` | `ap-south-1` | Region for the bucket, Glue database and Athena |
| `--prefix` | `cur2` | S3 prefix inside the bucket |
| `--export` | `cur2-daily` | Export name |
| `--database` | `cur` | Glue database name |
| `--table` | `cur2` | Athena table name |
| `--workgroup` | `cur` | Athena workgroup name |
| `--results` | `s3://<bucket>/athena-results/` | Athena results location |
| `--granularity` | `DAILY` | `DAILY` or `HOURLY` |
| `--scan-limit-gb` | `100` | Per-query data-scanned limit in GB |
| `--range-start` | current month | First month the table reads (`YYYY-MM`) |
| `--tags` | *(none)* | Comma-separated cost allocation tag keys to activate |
| `--apply` | *(flag)* | Create the resources (default is a dry run) |

## Safety checks

Before creating anything, the script verifies that anything already existing matches this run. It stops with an error if:

- The bucket has a policy that doesn't let this export write to it (it prints the statement to merge; it never replaces an existing policy).
- An export with the same name writes to a different bucket, prefix, region, or with different settings.
- A table with the same name reads a different S3 location, is missing a column, has a wrong column type, or doesn't use the same partition projection.

An existing Athena workgroup is kept as-is, with a warning if its results location or scan limit differs from what you asked for.

## After setup

**One step has no CLI.** For ECS or EKS split cost allocation, turn on **Billing and Cost Management → Cost Management Preferences → Split cost allocation data**. The export setting alone is not enough.

**First data delivery takes up to 24 hours.** Data starts from the day the export is created; earlier months need a backfill request to AWS Support.

**Check delivery:**

```bash
aws bcm-data-exports list-exports --region us-east-1
aws bcm-data-exports list-executions --region us-east-1 --export-arn <export-arn>
```

**Verify in Athena** (make sure your workgroup is set to the one the script created):

```sql
SELECT billing_period, COUNT(*) FROM <database>.<table> GROUP BY 1 ORDER BY 1;
```

## How the table works

The table uses **partition projection** on `billing_period`. Athena calculates the partition values from a date range (`YYYY-MM` to `NOW`), so new months appear without running `ALTER TABLE ADD PARTITION`. Each query should filter on `billing_period` to read only one month's data — Athena charges by data scanned.

The table's columns and types come from the export's own schema, fetched at setup time via `aws bcm-data-exports get-table`. A few columns need type overrides (savings plan rate, amortized upfront commitment, discount) that differ from the simple type mapping; the script handles these.

## Cost basis for queries

- **S3, SSM:** unblended cost, `Usage` rows only. These services aren't covered by Savings Plans or RIs, so unblended equals amortized.
- **ECS on EC2:** SCAD's split cost (amortized). Use the `split_line_item_net_*` columns for the figure after negotiated discounts.
- **Fargate, EC2:** amortized. Savings Plan usage counts at the plan's effective cost; RI usage at the reservation's effective cost. `SavingsPlanNegation` rows are excluded.

To verify a result, compare with Cost Explorer using the same service, accounts, and charge type, on days at least two days old (the newest days are still being updated).

## Teardown

To remove everything the script creates:

```bash
# Delete the Athena table
aws athena start-query-execution --region <region> --work-group <workgroup> \
    --query-string "DROP TABLE <database>.<table>"

# Delete the workgroup
aws athena delete-work-group --region <region> --work-group <workgroup>

# Delete the Glue database
aws glue delete-database --region <region> --name <database>

# Delete the export
aws bcm-data-exports delete-export --region us-east-1 \
    --export-arn <export-arn>

# Empty and delete the bucket
aws s3 rm s3://<bucket> --recursive
aws s3api delete-bucket --bucket <bucket>
```
