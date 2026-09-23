# Red Hat Errata Monitor

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

```
=== satellite-releases (2 new errata) ===
  RHBA-2026:51087        Bug Fix Advisory              None         2026-08-06  Satellite 6 Client Bug Fix Update
                         https://access.redhat.com/errata/RHBA-2026:51087
  RHSA-2024:2010         Security Advisory             Important    2024-04-23  Important: Satellite 6.15.0 release
                         https://access.redhat.com/errata/RHSA-2024:2010

=== aap-setup-bundle (1 new erratum) ===
  RHBA-2026:67611        Bug Fix Advisory              None         2026-09-15  Red Hat Ansible Automation Platform 2.7 Setup Bundle Release Update
                         https://access.redhat.com/errata/RHBA-2026:67611

Total: 3 new errata across 2 filters
```

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
| `--format {text,json,csv}` | Output format | `text` |
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

# Reset a specific filter and re-check from a date
python3 rh_errata_monitor.py monitor --reset-filters satellite-releases --reset-after 2024-01-01

# Reset all filters
./rh_errata_monitor.sh monitor --reset-filters all --reset-after 2026-01-01

# Use in CI -- exits 2 if new errata found
python3 rh_errata_monitor.py --exit-code monitor

# Dry run -- preview queries
./rh_errata_monitor.sh --dry-run monitor
```

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
