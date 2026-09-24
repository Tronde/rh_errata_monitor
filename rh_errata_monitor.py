#!/usr/bin/env python3
"""Monitor the Red Hat Errata Search API for new errata matching configurable filters.

Queries the public Solr-backed endpoint at
https://access.redhat.com/hydra/rest/search/kcs (no authentication required)
for errata matching user-defined product and synopsis filters.  Tracks which
errata have already been reported so each run only shows what is new since
the last check.

Filter configuration:
    An INI-style file (default: filters.conf) where each section defines a
    named filter with optional ``product`` and ``synopsis`` keys.

State tracking:
    A JSON state file stores the timestamp of the last fully successful run
    and a set of previously reported errata IDs per filter for deduplication.
"""

from __future__ import annotations

import argparse
import configparser
import csv
import io
import json
import logging
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote

import requests

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

API_URL = "https://access.redhat.com/hydra/rest/search/kcs"
ERRATA_URL_TEMPLATE = "https://access.redhat.com/errata/{errata_id}"
ROWS_PER_PAGE = 500
MAX_RETRIES = 1
RETRY_DELAY = 3
REQUEST_DELAY = 0.5
USER_AGENT = "rh-errata-monitor/1.0"

FIELD_LIST = (
    "id,portal_severity,portal_advisory_type,portal_product_names,"
    "portal_publication_date,portal_update_date,portal_synopsis,view_uri"
)

ADVISORY_TYPE_MAP = {
    "security": "Security Advisory",
    "bugfix": "Bug Fix Advisory",
    "enhancement": "Product Enhancement Advisory",
}

SEVERITY_MAP = {
    "critical": "Critical",
    "important": "Important",
    "moderate": "Moderate",
    "low": "Low",
}

logging.basicConfig(format="%(levelname)s: %(message)s")
log = logging.getLogger(__name__)

SESSION = requests.Session()
SESSION.headers["User-Agent"] = USER_AGENT

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------


def _valid_date(value: str) -> str:
    """Argparse type: validate YYYY-MM-DD format."""
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"invalid date format: '{value}' (expected YYYY-MM-DD)"
        )
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Monitor Red Hat Errata Search API for new errata.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
examples:
  %(prog)s monitor
  %(prog)s list-products
  %(prog)s list-products --search satellite
  %(prog)s search --product "Red Hat Satellite" --after 2024-01-01
  %(prog)s search --synopsis '"Ansible Automation Platform" "Setup Bundle"'
  %(prog)s monitor --format json --output /tmp/errata.json
""",
    )

    # Common flags
    parser.add_argument(
        "--filters",
        default=None,
        help="Path to INI filter config file (default: filters.conf)",
    )
    parser.add_argument(
        "--state-file",
        default=".errata_state.json",
        help="Path to JSON state file (default: .errata_state.json)",
    )
    parser.add_argument(
        "--initial-days",
        type=int,
        default=30,
        help="On first run (no state), look back this many days (default: 30)",
    )
    parser.add_argument(
        "--format",
        choices=["json", "csv", "md"],
        default="md",
        dest="output_format",
        help="Output format (default: md)",
    )
    parser.add_argument(
        "--output",
        help="Write report to file in addition to stdout",
    )
    parser.add_argument(
        "--exit-code",
        action="store_true",
        help="Exit with code 2 when new errata are found",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show queries without hitting the API",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Enable debug logging",
    )

    sub = parser.add_subparsers(dest="command")

    # -- monitor (default) --------------------------------------------------
    mon = sub.add_parser("monitor", help="Check for new errata per filter (default)")
    mon.add_argument(
        "--reset-filters",
        nargs="+",
        metavar="FILTER",
        help="Clear seen-errata state for these filters (use 'all' for every filter) and exit",
    )
    mon.add_argument(
        "--reset-after",
        type=_valid_date,
        metavar="YYYY-MM-DD",
        help="When resetting, also set last_run to this date",
    )

    # -- list-products -------------------------------------------------------
    lp = sub.add_parser("list-products", help="List available product names from the API")
    lp.add_argument(
        "--search", "-s",
        default="",
        help="Filter product names containing this text (case-insensitive)",
    )

    # -- search --------------------------------------------------------------
    sr = sub.add_parser(
        "search",
        help="One-off stateless errata search",
        description=(
            "Stateless errata search.  Without --filters, runs a single query "
            "using --product/--synopsis.  With --filters, runs each filter "
            "section and groups results by filter name."
        ),
    )
    sr.add_argument(
        "--filters",
        default=None,
        dest="search_filters",
        help="Path to INI filter config file; runs each section as a grouped search",
    )
    sr.add_argument("--product", help='Filter by product name (e.g. "Red Hat Satellite")')
    sr.add_argument("--synopsis", help="Search terms for synopsis/content")
    sr.add_argument(
        "--after",
        type=_valid_date,
        metavar="YYYY-MM-DD",
        help="Errata published after this date",
    )
    sr.add_argument(
        "--type",
        choices=list(ADVISORY_TYPE_MAP),
        dest="advisory_type",
        help="Advisory type filter",
    )
    sr.add_argument(
        "--severity",
        choices=list(SEVERITY_MAP),
        help="Severity filter",
    )
    sr.add_argument(
        "--rows",
        type=int,
        default=50,
        help="Max results to return (default: 50)",
    )

    return parser.parse_args()


# ---------------------------------------------------------------------------
# Filter config
# ---------------------------------------------------------------------------


def load_filters(path: str) -> dict[str, dict[str, str]]:
    """Load filter definitions from an INI file.

    Returns a dict mapping filter-name -> {product, synopsis}.
    """
    cfg_path = Path(path)
    if not cfg_path.is_file():
        log.error("Filters file not found: %s", path)
        sys.exit(1)

    cfg = configparser.RawConfigParser()
    cfg.read(cfg_path)

    filters: dict[str, dict[str, str]] = {}
    for section in cfg.sections():
        filters[section] = {
            "product": cfg.get(section, "product", fallback="").strip(),
            "synopsis": cfg.get(section, "synopsis", fallback="").strip(),
        }
    if not filters:
        log.error("No filter sections found in %s", path)
        sys.exit(1)

    return filters


# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------


def load_state(path: str) -> dict:
    state_path = Path(path)
    if state_path.is_file():
        try:
            return json.loads(state_path.read_text())
        except (json.JSONDecodeError, OSError) as exc:
            log.warning("Could not read state file (%s), starting fresh: %s", path, exc)
    return {}


def save_state(path: str, state: dict) -> None:
    Path(path).write_text(json.dumps(state, indent=2) + "\n")


def get_after_date(state: dict, initial_days: int) -> str:
    last_run = state.get("last_run")
    if last_run:
        return last_run[:10]
    fallback = datetime.now(timezone.utc) - timedelta(days=initial_days)
    return fallback.strftime("%Y-%m-%d")


def get_seen_errata(state: dict) -> dict[str, set[str]]:
    raw = state.get("seen_errata", {})
    return {name: set(ids) for name, ids in raw.items()}


# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------

# Characters with special meaning in Solr query syntax.
_SOLR_SPECIAL = r'+-&&||!(){}[]^"~*?:\/'


def _solr_escape(value: str) -> str:
    """Escape Solr special characters in a user-supplied value."""
    out: list[str] = []
    i = 0
    while i < len(value):
        # Two-character operators: && ||
        if i + 1 < len(value) and value[i : i + 2] in ("&&", "||"):
            out.append("\\")
            out.append(value[i])
            out.append("\\")
            out.append(value[i + 1])
            i += 2
            continue
        if value[i] in r'+-!(){}[]^"~*?:\/':
            out.append("\\")
        out.append(value[i])
        i += 1
    return "".join(out)


def _build_params(
    query: str = "*:*",
    product: str = "",
    after_date: str = "",
    advisory_type: str = "",
    severity: str = "",
    rows: int = ROWS_PER_PAGE,
    start: int = 0,
    sort: str = "portal_publication_date desc",
    synopsis_field: bool = False,
) -> dict[str, str | list[str]]:
    """Build query parameters for the KCS search endpoint.

    When *synopsis_field* is True the query targets the ``allTitle`` field
    (errata ID + synopsis) instead of the default full-text search.  This
    avoids false positives from matching content buried in release notes.
    """
    if synopsis_field and query != "*:*":
        effective_q = f"allTitle:({query})"
    else:
        effective_q = query

    params: dict[str, str | list[str]] = {
        "q": effective_q,
        "start": str(start),
        "rows": str(rows),
        "fl": FIELD_LIST,
        "sort": sort,
    }

    fq_list: list[str] = ['documentKind:("Errata")']

    if product:
        fq_list.append(f'portal_product_names:("{_solr_escape(product)}")')

    if after_date:
        fq_list.append(f"portal_publication_date:[{after_date}T00:00:00Z TO *]")

    if advisory_type:
        mapped = ADVISORY_TYPE_MAP.get(advisory_type, advisory_type)
        fq_list.append(f'portal_advisory_type:("{_solr_escape(mapped)}")')

    if severity:
        mapped = SEVERITY_MAP.get(severity, severity)
        fq_list.append(f'portal_severity:("{_solr_escape(mapped)}")')

    params["fq"] = fq_list
    return params


def _api_get(params: dict) -> dict | None:
    """GET request with one retry on transient errors."""
    for attempt in range(1 + MAX_RETRIES):
        try:
            resp = SESSION.get(API_URL, params=params, timeout=30)

            if resp.status_code == 200:
                return resp.json()

            if resp.status_code >= 500 and attempt < MAX_RETRIES:
                log.debug(
                    "Server error %d, retrying in %ds...",
                    resp.status_code, RETRY_DELAY,
                )
                time.sleep(RETRY_DELAY)
                continue

            log.warning("API returned HTTP %d", resp.status_code)
            return None

        except requests.RequestException as exc:
            if attempt < MAX_RETRIES:
                log.debug("Request failed (%s), retrying in %ds...", exc, RETRY_DELAY)
                time.sleep(RETRY_DELAY)
                continue
            log.warning("Request failed: %s", exc)
            return None

    return None


def fetch_errata(
    query: str = "*:*",
    product: str = "",
    after_date: str = "",
    advisory_type: str = "",
    severity: str = "",
    max_rows: int = 0,
    synopsis_field: bool = False,
) -> tuple[list[dict], bool]:
    """Fetch errata with automatic pagination.

    Returns (errata_list, success).
    """
    all_docs: list[dict] = []
    start = 0
    page_size = min(ROWS_PER_PAGE, max_rows) if max_rows else ROWS_PER_PAGE

    while True:
        params = _build_params(
            query=query,
            product=product,
            after_date=after_date,
            advisory_type=advisory_type,
            severity=severity,
            rows=page_size,
            start=start,
            synopsis_field=synopsis_field,
        )

        data = _api_get(params)
        if data is None:
            return all_docs, False

        docs = data.get("response", {}).get("docs", [])
        if not docs:
            break

        all_docs.extend(docs)

        if max_rows and len(all_docs) >= max_rows:
            all_docs = all_docs[:max_rows]
            break

        if len(docs) < page_size:
            break

        start += len(docs)

        num_found = data.get("response", {}).get("numFound", 0)
        if start >= num_found:
            break

    return all_docs, True


def fetch_products(search: str = "") -> list[tuple[str, int]]:
    """Fetch available product names via facets.

    Returns list of (product_name, count) sorted by count descending.
    """
    params: dict[str, str | list[str]] = {
        "q": "*:*",
        "start": "0",
        "rows": "0",
        "fq": ['documentKind:("Errata")'],
        "facet": "true",
        "facet.field": "portal_product_names",
        "facet.mincount": "1",
        "facet.limit": "1000",
    }

    data = _api_get(params)
    if data is None:
        return []

    raw = (
        data.get("facet_counts", {})
        .get("facet_fields", {})
        .get("portal_product_names", [])
    )

    products: list[tuple[str, int]] = []
    for i in range(0, len(raw), 2):
        name = raw[i]
        count = raw[i + 1]
        if search and search.lower() not in name.lower():
            continue
        products.append((name, count))

    return products


def _validate_products(products: list[str]) -> None:
    """Validate that every non-empty product name is a known product.

    Fetches the current product list from the API once and checks all given
    names against it (exact match).  Exits with an error listing any unknown
    names.  Besides catching typos early, this also guards against Solr
    query injection: since only names taken verbatim from the API's own
    facets are accepted, arbitrary quote/operator payloads in a `product`
    value can never reach the query unescaped.

    If the product list cannot be fetched (e.g. API unreachable), validation
    is skipped with a warning rather than blocking the run.
    """
    names = {p for p in products if p}
    if not names:
        return

    known = {name for name, _ in fetch_products()}
    if not known:
        log.warning(
            "Could not fetch product list to validate names; proceeding without validation"
        )
        return

    unknown = sorted(n for n in names if n not in known)
    if unknown:
        log.error(
            "Unknown product name(s): %s (run 'list-products' to see valid names)",
            ", ".join(repr(n) for n in unknown),
        )
        sys.exit(1)


# ---------------------------------------------------------------------------
# Formatters
# ---------------------------------------------------------------------------


def _errata_row(doc: dict) -> dict:
    """Normalize an errata doc into a flat row dict."""
    errata_id = doc.get("id", "N/A")
    return {
        "id": errata_id,
        "synopsis": doc.get("portal_synopsis", "N/A"),
        "type": doc.get("portal_advisory_type", "N/A"),
        "severity": doc.get("portal_severity", "None"),
        "date": (doc.get("portal_publication_date") or "N/A")[:10],
        "products": ", ".join(doc.get("portal_product_names", [])),
        "url": doc.get("view_uri", ERRATA_URL_TEMPLATE.format(errata_id=errata_id)),
    }


def format_json(results: dict[str, list[dict]] | list[dict]) -> str:
    if isinstance(results, list):
        rows = [_errata_row(doc) for doc in results]
    else:
        rows = []
        for name, docs in results.items():
            for doc in docs:
                row = _errata_row(doc)
                row["filter"] = name
                rows.append(row)
    return json.dumps(rows, indent=2)


def format_csv(results: dict[str, list[dict]] | list[dict]) -> str:
    buf = io.StringIO()
    is_grouped = isinstance(results, dict)
    fieldnames = ["id", "synopsis", "type", "severity", "date", "products", "url"]
    if is_grouped:
        fieldnames.insert(0, "filter")

    writer = csv.DictWriter(buf, fieldnames=fieldnames, lineterminator="\n")
    writer.writeheader()

    if is_grouped:
        for name, docs in results.items():
            for doc in docs:
                row = _errata_row(doc)
                row["filter"] = name
                writer.writerow(row)
    else:
        for doc in results:
            writer.writerow(_errata_row(doc))

    return buf.getvalue()


def format_report_md(
    results: dict[str, list[dict]],
    since_date: str = "",
    new: bool = True,
) -> str:
    """Markdown report grouped by filter name.

    One "### filter-name (...)" section per filter, followed by a bullet
    list of markdown links (or "- none" when empty).  When *since_date* is
    given, both the per-filter headers and the final total line include a
    "since {since_date}" suffix.  *new* controls whether the wording says
    "new errata" (monitor) or plain "errata" (stateless filtered search).
    """
    lines: list[str] = []
    total = 0
    label = "new errat" if new else "errat"
    since_suffix = f" since {since_date}" if since_date else ""

    for name, docs in results.items():
        count = len(docs)
        total += count
        unit = "um" if count == 1 else "a"
        lines.append(f"### {name} ({count} {label}{unit}{since_suffix})")
        lines.append("")

        if not docs:
            lines.append("  - none")
        else:
            for doc in docs:
                r = _errata_row(doc)
                lines.append(f"  - [{r['id']} - {r['synopsis']}]({r['url']}) - {r['severity']}")

        lines.append("")

    filter_count = sum(1 for docs in results.values() if docs)
    total_unit = "um" if total == 1 else "a"
    lines.append(
        f"**Total: {total} {label}{total_unit}{since_suffix} "
        f"across {filter_count} filter{'s' if filter_count != 1 else ''}**"
    )
    return "\n".join(lines)


def format_report_flat_md(docs: list[dict], since_date: str = "") -> str:
    """Markdown report for a flat (non-grouped) list of errata.

    Plain bullet list of markdown links (no "###" headers), followed by a
    bold total line.  When *since_date* is given, the total line includes a
    "since {since_date}" suffix.
    """
    lines: list[str] = []
    since_suffix = f" since {since_date}" if since_date else ""

    if not docs:
        lines.append("  - none")
    else:
        for doc in docs:
            r = _errata_row(doc)
            lines.append(f"  - [{r['id']} - {r['synopsis']}]({r['url']}) - {r['severity']}")

    lines.append("")
    lines.append(
        f"**Total: {len(docs)} errat{'um' if len(docs) == 1 else 'a'}{since_suffix}**"
    )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def cmd_monitor(args: argparse.Namespace) -> None:
    """Monitor command: check filters for new errata."""
    if not args.filters:
        args.filters = "filters.conf"

    # Handle reset
    reset_filters = getattr(args, "reset_filters", None)
    reset_after = getattr(args, "reset_after", None)
    if reset_after and not reset_filters:
        log.error("--reset-after requires --reset-filters")
        sys.exit(1)
    if reset_filters:
        _reset_state(args.state_file, reset_filters, reset_after)
        return

    filters = load_filters(args.filters)
    state = load_state(args.state_file)
    after_date = get_after_date(state, args.initial_days)
    seen_errata = get_seen_errata(state)

    if args.dry_run:
        print("Dry run -- the following queries would be made:")
        for name, filt in filters.items():
            q = filt.get("synopsis") or "*:*"
            product = filt.get("product", "")
            print(f"  [{name}]")
            print(f"    query:   {q}")
            if product:
                print(f"    product: {product}")
            print(f"    after:   {after_date}")
        return

    _validate_products([filt.get("product", "") for filt in filters.values()])

    log.debug("Querying errata published after %s for %d filter(s)", after_date, len(filters))

    results: dict[str, list[dict]] = {}
    all_succeeded = True

    for i, (name, filt) in enumerate(filters.items()):
        q = filt.get("synopsis") or "*:*"
        product = filt.get("product", "")

        log.debug("Querying filter: %s (q=%s, product=%s)", name, q, product)

        docs, success = fetch_errata(
            query=q,
            product=product,
            after_date=after_date,
            synopsis_field=True,
        )

        if not success:
            all_succeeded = False

        previously_seen = seen_errata.get(name, set())
        new_docs = [d for d in docs if d.get("id") not in previously_seen]
        results[name] = new_docs

        seen_errata.setdefault(name, set()).update(d.get("id", "") for d in docs)

        if i < len(filters) - 1:
            time.sleep(REQUEST_DELAY)

    # Format output
    formatters = {
        "json": format_json,
        "csv": format_csv,
        "md": lambda r: format_report_md(r, since_date=after_date, new=True),
    }
    report = formatters[args.output_format](results)
    print(report)

    if args.output:
        Path(args.output).write_text(report)
        print(f"Report written to {args.output}")

    # Update state
    if all_succeeded:
        state["last_run"] = datetime.now(timezone.utc).isoformat()
    else:
        log.warning(
            "Some filters failed; last_run timestamp NOT updated. "
            "Re-run to retry."
        )

    state["seen_errata"] = {name: sorted(ids) for name, ids in seen_errata.items()}
    save_state(args.state_file, state)

    if args.exit_code and any(results.values()):
        sys.exit(2)


def cmd_list_products(args: argparse.Namespace) -> None:
    """List available product names from the API."""
    if args.dry_run:
        print("Dry run -- would query product facets from the API")
        return

    search = getattr(args, "search", "")
    products = fetch_products(search=search)

    if not products:
        print("No products found.")
        return

    if args.output_format == "json":
        rows = [{"product": name, "errata_count": count} for name, count in products]
        output = json.dumps(rows, indent=2)
    elif args.output_format == "csv":
        buf = io.StringIO()
        writer = csv.writer(buf, lineterminator="\n")
        writer.writerow(["product", "errata_count"])
        for name, count in products:
            writer.writerow([name, count])
        output = buf.getvalue()
    else:  # md
        lines = []
        for name, count in products:
            lines.append(f"  - {name} ({count} errata)")
        lines.append("")
        filtered_suffix = f' (filtered by: "{search}")' if search else ""
        lines.append(f"**Total: {len(products)} products{filtered_suffix}**")
        output = "\n".join(lines)

    print(output)

    if args.output:
        Path(args.output).write_text(output)
        print(f"Written to {args.output}")


def cmd_search(args: argparse.Namespace) -> None:
    """One-off stateless errata search.

    When --filters is supplied, iterates over every filter section and groups
    results by filter name (same layout as monitor).  CLI flags --after,
    --type, --severity, and --rows are applied to every filter query.
    When --filters is *not* supplied, runs a single flat search using the
    CLI --product / --synopsis / etc. flags directly.
    """
    after = getattr(args, "after", None) or ""
    advisory_type = getattr(args, "advisory_type", None) or ""
    severity = getattr(args, "severity", None) or ""
    rows = getattr(args, "rows", 50)

    # --filters can come from the search subcommand or from the global parser
    filters_path = getattr(args, "search_filters", None) or getattr(args, "filters", None)
    use_filters = filters_path is not None

    if use_filters:
        if not Path(filters_path).is_file():
            log.error("Filters file not found: %s", filters_path)
            sys.exit(1)
        args.filters = filters_path
        _cmd_search_filters(args, after, advisory_type, severity, rows)
    else:
        _cmd_search_flat(args, after, advisory_type, severity, rows)


def _cmd_search_flat(
    args: argparse.Namespace,
    after: str,
    advisory_type: str,
    severity: str,
    rows: int,
) -> None:
    """Single flat (ungrouped) search driven by CLI flags."""
    q = getattr(args, "synopsis", None) or "*:*"
    product = getattr(args, "product", None) or ""

    if args.dry_run:
        print("Dry run -- the following query would be made:")
        print(f"  query:    {q}")
        if product:
            print(f"  product:  {product}")
        if after:
            print(f"  after:    {after}")
        if advisory_type:
            print(f"  type:     {advisory_type}")
        if severity:
            print(f"  severity: {severity}")
        print(f"  rows:     {rows}")
        return

    _validate_products([product])

    docs, success = fetch_errata(
        query=q,
        product=product,
        after_date=after,
        advisory_type=advisory_type,
        severity=severity,
        max_rows=rows,
    )

    if not success and not docs:
        print("Error: API request failed.")
        sys.exit(1)

    formatters_flat = {
        "json": lambda d: format_json(d),
        "csv": lambda d: format_csv(d),
        "md": lambda d: format_report_flat_md(d, since_date=after),
    }
    report = formatters_flat[args.output_format](docs)
    print(report)

    if args.output:
        Path(args.output).write_text(report)
        print(f"Report written to {args.output}")


def _cmd_search_filters(
    args: argparse.Namespace,
    after: str,
    advisory_type: str,
    severity: str,
    rows: int,
) -> None:
    """Search using filter definitions from the INI file, grouped by filter."""
    filters = load_filters(args.filters)

    if args.dry_run:
        print("Dry run -- the following queries would be made:")
        for name, filt in filters.items():
            q = filt.get("synopsis") or "*:*"
            product = filt.get("product", "")
            print(f"  [{name}]")
            print(f"    query:   {q}")
            if product:
                print(f"    product: {product}")
            if after:
                print(f"    after:   {after}")
            if advisory_type:
                print(f"    type:    {advisory_type}")
            if severity:
                print(f"    severity: {severity}")
            print(f"    rows:    {rows}")
        return

    _validate_products([filt.get("product", "") for filt in filters.values()])

    results: dict[str, list[dict]] = {}
    for i, (name, filt) in enumerate(filters.items()):
        q = filt.get("synopsis") or "*:*"
        product = filt.get("product", "")

        log.debug("Querying filter: %s (q=%s, product=%s)", name, q, product)

        docs, _success = fetch_errata(
            query=q,
            product=product,
            after_date=after,
            advisory_type=advisory_type,
            severity=severity,
            max_rows=rows,
            synopsis_field=True,
        )
        results[name] = docs

        if i < len(filters) - 1:
            time.sleep(REQUEST_DELAY)

    formatters = {
        "json": format_json,
        "csv": format_csv,
        "md": lambda r: format_report_md(r, since_date=after, new=False),
    }
    report = formatters[args.output_format](results)
    print(report)

    if args.output:
        Path(args.output).write_text(report)
        print(f"Report written to {args.output}")


def _reset_state(state_file: str, filter_names: list[str], reset_after: str | None) -> None:
    """Clear seen-errata state for given filters, optionally reset last_run."""
    state = load_state(state_file)
    seen = state.get("seen_errata", {})

    if "all" in filter_names:
        cleared = list(seen.keys()) or ["(none)"]
        seen.clear()
        print(f"Cleared seen errata for all filters: {', '.join(cleared)}")
    else:
        for name in filter_names:
            if name in seen:
                del seen[name]
                print(f"Cleared seen errata for: {name}")
            else:
                print(f"No state found for: {name} (nothing to clear)")

    state["seen_errata"] = seen

    if reset_after:
        state["last_run"] = reset_after + "T00:00:00+00:00"
        print(f"Reset last_run to: {reset_after}")

    save_state(state_file, state)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    args = parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    else:
        logging.getLogger().setLevel(logging.WARNING)

    command = args.command or "monitor"

    if command == "monitor":
        cmd_monitor(args)
    elif command == "list-products":
        cmd_list_products(args)
    elif command == "search":
        cmd_search(args)
    else:
        log.error("Unknown command: %s", command)
        sys.exit(1)


if __name__ == "__main__":
    main()
