# Unofficial Red Hat Errata Monitor

> **Disclaimer:** This is an independent, community project. It is **not** official
> software supported by, endorsed by, or affiliated with Red Hat, Inc. It is
> provided "as is", without warranty of any kind. Use it entirely at your own
> risk. See the [LICENCE](LICENCE) file for details.

Two independent CLI tools (Python and bash) that monitor the [Red Hat Errata Search](https://access.redhat.com/errata-search/) API for new errata matching configurable filters. No authentication required.

> **Transparency:** This project is developed with AI assistance.

Use cases:

- Track new releases of Red Hat Satellite, Ansible Automation Platform, or any other product
- Monitor for security, bug-fix, or enhancement advisories
- Get notified when new errata are published for products you care about
- Run it on demand to prepare your TAM calls with your customers to proactively notify them about new releases (the author's use case)

## Status of this project

- It's brand new and still in testing
- I'm not sure filters work correctly, there might be false positives
- Please submit any issues via the issue tracker of this repo

## Requirements

### Python version

- Python 3.9+ (tested on RHEL 9 / Fedora)
- `requests` library

### Bash version

- Bash 4+
- `curl`
- `jq`

## Installation

```bash
git clone <repo-url> rh_errata_monitor
cd rh_errata_monitor
pip install -r requirements.txt  # Python version only
cp filters.conf.example filters.conf
```

## Running in containers

Both versions include a Containerfile. With Podman installed, build the images
from the repository root (the final `.` supplies the build context):

```bash
# Python version
podman build -f Containerfile-python -t localhost/rh_errata_monitor:python .

# Bash version
podman build -f Containerfile-shell -t localhost/rh_errata_monitor:shell .
```

The images include the script and its dependencies, but require your filter
configuration at runtime. Prepare a dedicated directory for configuration and
persistent state:

```bash
mkdir -p container-data
cp filters.conf.example container-data/filters.conf
# Edit container-data/filters.conf to match your products and synopsis filters.
```

Run either image with rootless Podman (without `sudo`):

```bash
# Python version
podman run --rm --userns=keep-id:uid=65534,gid=65534 \
  -v "$(pwd)/container-data:/app:Z" \
  localhost/rh_errata_monitor:python \
  --filters /app/filters.conf --state-file /app/.errata_state.json monitor

# Bash version
podman run --rm --userns=keep-id:uid=65534,gid=65534 \
  -v "$(pwd)/container-data:/app:Z" \
  localhost/rh_errata_monitor:shell \
  --filters /app/filters.conf --state-file /app/.errata_state.json monitor
```

Both images use `/app` as their working directory and run as UID 65534. The
`--userns=keep-id:uid=65534,gid=65534` option maps your host user to that container
user so the monitor can write to the mounted directory. See the
[Podman user namespace documentation](https://docs.podman.io/en/latest/markdown/podman-run.1.html#userns-mode).
The `:Z` suffix relabels the directory for container access on SELinux systems.

Configuration and `.errata_state.json` remain in `container-data` after `--rm`
removes the container. Reuse this directory on subsequent runs to retain the
last-run timestamp and previously reported errata. To continue from an existing
installation, copy its `filters.conf` and `.errata_state.json` into this directory
before the first container run.

Each image starts its monitor script directly. Put global options before the
command, as shown above; replace `monitor` with `list-products` or `search` to use
those commands. To save a report on the host, add `--output /app/report.md` before
`monitor`; it will appear as `container-data/report.md`.

## Quick start

1. Copy and edit the filter configuration:

```bash
cp filters.conf.example filters.conf
```

2. Discover available product names:

```bash
# Python
python3 rh_errata_monitor.py list-products --search satellite

# Bash
./rh_errata_monitor.sh list-products --search satellite
```

3. Run the monitor:

```bash
# Python
python3 rh_errata_monitor.py monitor

# Bash
./rh_errata_monitor.sh monitor
```

On the first run it looks back 30 days by default. Subsequent runs only show errata published since the last successful execution.

### Example output

The default format is `md` (Markdown), which is convenient for pasting into wiki pages, PR comments, or chat:

```markdown
### satellite-releases (2 new errata since 2026-08-20)

  - [RHBA-2026:51087 - Satellite 6 Client Bug Fix Update](https://access.redhat.com/errata/RHBA-2026:51087) - None - Max CVSS v3: unavailable
  - [RHSA-2024:2010 - Important: Satellite 6.15.0 release](https://access.redhat.com/errata/RHSA-2024:2010) - Important - Max CVSS v3: unavailable

### aap-setup-bundle (1 new erratum since 2026-08-20)

  - [RHBA-2026:67611 - Red Hat Ansible Automation Platform 2.7 Setup Bundle Release Update](https://access.redhat.com/errata/RHBA-2026:67611) - None - Max CVSS v3: unavailable

**Total: 3 new errata since 2026-08-20 across 2 filters**

[Explaining Red Hat Errata (RHSA, RHBA, and RHEA)](https://access.redhat.com/articles/explaining_redhat_errata)
```

The `since DATE` suffix always appears for `monitor` (it always queries from a known date) and only appears for `search` when `--after` was explicitly passed. Filters with no results render as a single `  - none` line.

The example illustrates unavailable scores. When scores are available, each
erratum instead shows a value such as `Max CVSS v3: 7.5`. See
[CVE scores](#cve-scores) for scoring and failure behavior.

## Filter configuration

The file `filters.conf` uses INI syntax. Each `[section]` defines a named filter:

```ini
[satellite-releases]
product = Red Hat Satellite
synopsis = Satellite 6

[aap-setup-bundle]
synopsis = "Ansible Automation Platform" "Setup Bundle"

[aap-all]
product = Red Hat Ansible Automation Platform
```

| Key | Description | API mapping |
|-----|-------------|-------------|
| `product` | Exact product name (use `list-products` to discover valid names) | `fq=portal_product_names:("...")` |
| `synopsis` | Free-text search terms; use quotes for phrases | `q=...` |

- Both keys are optional
- If both are set, results must match **both** (AND logic)
- If neither is set, all errata are returned (not recommended)

## CLI reference

Both tools share the same interface.

### Commands

| Command | Description |
|---------|-------------|
| `monitor` | Check for new errata per filter (default) |
| `list-products` | List available product names from the API |
| `search` | One-off stateless errata search |

### Global flags

| Flag | Description | Default |
|------|-------------|---------|
| `--filters FILE` | Path to INI filter config | `filters.conf` |
| `--state-file FILE` | Path to JSON state file | `.errata_state.json` |
| `--initial-days N` | On first run, look back N days | `30` |
| `--format {json,csv,md}` | Output format | `md` |
| `--no-cvss` | Skip CVE score lookups and omit CVSS report fields | _(off; scores enabled)_ |
| `--output FILE` | Write report to file in addition to stdout | _(none)_ |
| `--exit-code` | Exit with code 2 when new errata are found | _(off)_ |
| `--dry-run` | Show queries without hitting the API | _(off)_ |
| `-v` / `--verbose` | Enable debug logging | _(off)_ |

### Monitor flags

| Flag | Description |
|------|-------------|
| `--reset-filters FILTER [...]` | Clear seen-errata cache for filters (or `all`) and exit |
| `--reset-after YYYY-MM-DD` | When resetting, also rewind the query window to this date |

### List-products flags

| Flag | Description |
|------|-------------|
| `--search TEXT` / `-s TEXT` | Filter products by name (case-insensitive) |

### Search flags

| Flag | Description | Default |
|------|-------------|---------|
| `--product NAME` | Filter by exact product name | _(none)_ |
| `--synopsis TEXT` | Search terms for synopsis/content | _(none)_ |
| `--after YYYY-MM-DD` | Errata published after this date | _(none)_ |
| `--type {security,bugfix,enhancement}` | Advisory type | _(all)_ |
| `--severity {critical,important,moderate,low}` | Severity filter | _(all)_ |
| `--rows N` | Max results | `50` |

### Examples

```bash
# Discover products matching "ansible"
python3 rh_errata_monitor.py list-products --search ansible

# One-off search for Satellite errata since 2024-01-01
python3 rh_errata_monitor.py search --product "Red Hat Satellite" --after 2024-01-01

# Search for AAP bundled installer releases
python3 rh_errata_monitor.py search --synopsis '"Ansible Automation Platform" "Setup Bundle"'

# Monitor with JSON output
python3 rh_errata_monitor.py --format json monitor

# Generate CSV report to file
./rh_errata_monitor.sh --format csv --output /tmp/errata.csv monitor

# Generate a Markdown report (e.g. to paste into a wiki page or PR comment)
python3 rh_errata_monitor.py --format md monitor

# Reset a specific filter and re-check from a date
python3 rh_errata_monitor.py monitor --reset-filters satellite-releases --reset-after 2024-01-01

# Reset all filters
./rh_errata_monitor.sh monitor --reset-filters all --reset-after 2026-01-01

# Use in CI -- exits 2 if new errata found
python3 rh_errata_monitor.py --exit-code monitor

# Dry run -- preview queries
./rh_errata_monitor.sh --dry-run monitor

# Skip CVE lookups and use the original report fields
python3 rh_errata_monitor.py --no-cvss monitor
./rh_errata_monitor.sh --no-cvss search --product "Red Hat Satellite"
```

## CVE scores

Both tools enrich `monitor` and `search` reports by default with the highest
available **Red Hat CVSS v3 base score** among the CVEs associated with each
advisory. Scores come from the
[Red Hat Security Data CVE API](https://docs.redhat.com/en/documentation/red_hat_security_data_api/1.0/security_data_api-cve),
using its advisory filter and all result pages. These scores describe associated
CVEs; they are separate from Red Hat's advisory severity and are not a
product-specific risk assessment. CVSS v2 scores are not used as a fallback.
All advisory types are checked, including RHBA and RHEA.

Markdown adds `Max CVSS v3: 7.5` to an erratum's bullet. If only some associated
CVEs have valid scores, it shows the highest available value with `(partial)`.
JSON and CSV append `max_cvss3` and `cvss3_status` fields:

- `ok`: all returned CVEs have valid scores; `max_cvss3` is their maximum.
- `partial`: some scores are missing or invalid; the maximum covers only the
  valid scores and may be lower than the true maximum.
- `no_cves`: a successful lookup returned no associated CVEs. Markdown shows
  `no associated CVEs`.
- `unavailable`: no valid scores were returned, or the lookup failed. Markdown
  shows `unavailable`. A failed result page invalidates the entire lookup.

Missing maximum scores are JSON `null` or empty CSV cells, never a substitute
zero. A valid score of `0.0` is retained.

Enrichment requires an extra request per unique reported advisory, plus requests
for additional pages. Results, including failures, are reused across filters
within a run; they are not cached between runs. Monitor lookups happen only for
new errata. `--dry-run` makes no requests, and `list-products` is unchanged.
Use global `--no-cvss` before the command to skip these lookups and retain the
original Markdown, JSON, and CSV report fields.

Lookup failures produce warnings without stopping the report or changing normal
monitor state updates and exit codes. Consequently, a missing score does not
cause an erratum to be reported again. Use a subsequent stateless `search` to
retrieve scores that were previously unavailable. Reports saved with `--output`
contain the same score information as the report printed to stdout.

## State file

The monitor stores its state in `.errata_state.json` (configurable via `--state-file`). This file contains:

- `last_run` -- ISO 8601 timestamp of the last fully successful run (only updated when every filter query succeeds)
- `seen_errata` -- per-filter list of errata IDs already reported, used for deduplication across runs

Delete this file or use `--reset-filters all` to start fresh.

## Running on a schedule

### Option A: cron

Run the monitor daily at 07:00:

```bash
crontab -e
```

Add:

```
0 7 * * * cd /opt/rh_errata_monitor && /usr/bin/python3 rh_errata_monitor.py --output /var/log/errata_report.txt 2>&1 | logger -t errata-monitor
```

To receive email notifications when new errata are found:

```
MAILTO=admin@example.com
0 7 * * * cd /opt/rh_errata_monitor && /usr/bin/python3 rh_errata_monitor.py --exit-code 2>&1
```

### Option B: systemd timer

**/etc/systemd/system/errata-monitor.service**

```ini
[Unit]
Description=Red Hat Errata Monitor
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/opt/rh_errata_monitor
ExecStart=/usr/bin/python3 rh_errata_monitor.py --output /var/log/errata_report.txt
User=errata-monitor
Group=errata-monitor
```

**/etc/systemd/system/errata-monitor.timer**

```ini
[Unit]
Description=Run Red Hat Errata Monitor daily

[Timer]
OnCalendar=*-*-* 07:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now errata-monitor.timer
```

## How it works

1. Reads filter definitions from the INI config file.
2. Loads state from the JSON state file (last run timestamp + previously seen errata IDs).
3. For each filter, queries `GET https://access.redhat.com/hydra/rest/search/kcs` with:
   - `q=<synopsis>` for text search
   - `fq=portal_product_names:("<product>")` for product filtering
   - `fq=portal_publication_date:[<after_date>T00:00:00Z TO *]` for date range
   - Automatic pagination (up to 500 results per page)
4. Filters out errata already reported in prior runs (deduplication by errata ID).
5. Prints the report in the requested format.
6. Updates the state file (timestamp advances only if all filter queries succeeded).

Before formatting, both tools look up CVSS v3 scores for the reported errata
unless `--no-cvss` is set. Failures of this optional enrichment do not prevent
the state timestamp from advancing.

## API reference

This tool uses the public search endpoint that powers the [Red Hat Errata Search](https://access.redhat.com/errata-search/) web UI. No authentication is required.

**Endpoint:** `GET https://access.redhat.com/hydra/rest/search/kcs`

Key parameters (Solr query syntax):

| Parameter | Description |
|-----------|-------------|
| `q` | Full-text query (default `*:*`) |
| `fq` | Filter query (repeatable): `documentKind:("Errata")`, product, date range |
| `fl` | Field list to return |
| `rows` | Results per page (max ~500) |
| `start` | Pagination offset |
| `sort` | Sort order |
| `facet` | Enable faceting for product discovery |

## Security considerations

- **`--output` flag:** The `--output` flag writes the report to any path the
  current user can write to. When running the tool as a privileged user (e.g. a
  root cron job), ensure the output path points to a dedicated report directory.
  Do not pass untrusted input as the `--output` value in automated pipelines.

## Issues

- This tool is a personal project; expect rough edges
- Please report issues and feature requests via the issue tracker
