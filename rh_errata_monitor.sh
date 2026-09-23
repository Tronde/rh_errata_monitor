#!/usr/bin/env bash
# rh_errata_monitor.sh -- Monitor Red Hat Errata Search API for new errata.
#
# Queries the public Solr-backed endpoint at
# https://access.redhat.com/hydra/rest/search/kcs (no authentication required)
# for errata matching user-defined product and synopsis filters.
#
# Dependencies: curl, jq
#
# Usage:
#   ./rh_errata_monitor.sh [global-flags] <command> [command-flags]
#
# Commands:
#   monitor        Check for new errata per filter (default)
#   list-products  List available product names from the API
#   search         One-off stateless errata search
#
# Run with --help for full usage.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly API_URL="https://access.redhat.com/hydra/rest/search/kcs"
readonly USER_AGENT="rh-errata-monitor-bash/1.0"
readonly ROWS_PER_PAGE=500
readonly MAX_RETRIES=1
readonly RETRY_DELAY=3
readonly FIELD_LIST="id,portal_severity,portal_advisory_type,portal_product_names,portal_publication_date,portal_update_date,portal_synopsis,view_uri"

# Defaults
FILTERS_FILE="filters.conf"
FILTERS_EXPLICIT=false
STATE_FILE=".errata_state.json"
INITIAL_DAYS=30
OUTPUT_FORMAT="text"
OUTPUT_FILE=""
EXIT_CODE_MODE=false
DRY_RUN=false
VERBOSE=false

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_debug() { $VERBOSE && echo "DEBUG: $*" >&2 || true; }
log_warn()  { echo "WARNING: $*" >&2; }
log_error() { echo "ERROR: $*" >&2; }

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

check_deps() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v jq   >/dev/null 2>&1 || missing+=(jq)
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------

api_get() {
    local url="$1"
    local attempt

    for (( attempt=0; attempt<=MAX_RETRIES; attempt++ )); do
        local http_code body
        body=$(curl -s -w "\n%{http_code}" \
            -H "User-Agent: ${USER_AGENT}" \
            --max-time 30 \
            "$url") || true

        http_code=$(echo "$body" | tail -1)
        body=$(echo "$body" | sed '$d')

        if [[ "$http_code" == "200" ]]; then
            echo "$body"
            return 0
        fi

        if [[ "$http_code" -ge 500 ]] && [[ $attempt -lt $MAX_RETRIES ]]; then
            log_debug "Server error $http_code, retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
            continue
        fi

        log_warn "API returned HTTP $http_code"
        return 1
    done

    return 1
}

urlencode() {
    printf '%s' "$1" | python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.stdin.read(), safe=''))"
}

solr_escape() {
    # Escape Solr special characters: + - ! ( ) { } [ ] ^ " ~ * ? : \ /
    # and two-character operators && ||
    local val="$1"
    val="${val//\\/\\\\}"
    val="${val//+/\\+}"
    val="${val//-/\\-}"
    val="${val//\!/\\!}"
    val="${val//\(/\\(}"
    val="${val//\)/\\)}"
    val="${val//\{/\\\{}"
    val="${val//\}/\\\}}"
    val="${val//\[/\\[}"
    val="${val//\]/\\]}"
    val="${val//^/\\^}"
    val="${val//\"/\\\"}"
    val="${val//\~/\\~}"
    val="${val//\*/\\*}"
    val="${val//\?/\\?}"
    val="${val//:/\\:}"
    val="${val////\\/}"
    val="${val//&&/\\&\\&}"
    val="${val//||/\\|\\|}"
    printf '%s' "$val"
}

build_url() {
    local query="${1:-*:*}"
    local product="${2:-}"
    local after_date="${3:-}"
    local advisory_type="${4:-}"
    local severity="${5:-}"
    local rows="${6:-$ROWS_PER_PAGE}"
    local start="${7:-0}"
    local sort="${8:-portal_publication_date desc}"
    local synopsis_field="${9:-false}"

    # When synopsis_field is true, wrap query in allTitle:() for precise
    # synopsis matching instead of broad full-text search.
    local effective_q="$query"
    if [[ "$synopsis_field" == "true" ]] && [[ "$query" != "*:*" ]]; then
        effective_q="allTitle:(${query})"
    fi

    local url="${API_URL}?"
    url+="q=$(urlencode "$effective_q")"
    url+="&start=${start}"
    url+="&rows=${rows}"
    url+="&fl=$(urlencode "$FIELD_LIST")"
    url+="&sort=$(urlencode "$sort")"

    # Always filter for Errata documents
    url+="&fq=$(urlencode 'documentKind:("Errata")')"

    if [[ -n "$product" ]]; then
        local escaped_product
        escaped_product=$(solr_escape "$product")
        url+="&fq=$(urlencode "portal_product_names:(\"${escaped_product}\")")"
    fi

    if [[ -n "$after_date" ]]; then
        url+="&fq=$(urlencode "portal_publication_date:[${after_date}T00:00:00Z TO *]")"
    fi

    if [[ -n "$advisory_type" ]]; then
        local mapped
        case "$advisory_type" in
            security)    mapped="Security Advisory" ;;
            bugfix)      mapped="Bug Fix Advisory" ;;
            enhancement) mapped="Product Enhancement Advisory" ;;
            *)           mapped="$advisory_type" ;;
        esac
        url+="&fq=$(urlencode "portal_advisory_type:(\"$(solr_escape "$mapped")\")")"
    fi

    if [[ -n "$severity" ]]; then
        local mapped
        case "$severity" in
            critical)  mapped="Critical" ;;
            important) mapped="Important" ;;
            moderate)  mapped="Moderate" ;;
            low)       mapped="Low" ;;
            *)         mapped="$severity" ;;
        esac
        url+="&fq=$(urlencode "portal_severity:(\"$(solr_escape "$mapped")\")")"
    fi

    echo "$url"
}

fetch_errata() {
    local query="${1:-*:*}"
    local product="${2:-}"
    local after_date="${3:-}"
    local advisory_type="${4:-}"
    local severity="${5:-}"
    local max_rows="${6:-0}"
    local synopsis_field="${7:-false}"

    local all_docs="[]"
    local start=0
    local page_size=$ROWS_PER_PAGE
    if [[ "$max_rows" -gt 0 ]] && [[ "$max_rows" -lt "$page_size" ]]; then
        page_size=$max_rows
    fi

    while true; do
        local url
        url=$(build_url "$query" "$product" "$after_date" "$advisory_type" "$severity" "$page_size" "$start" "portal_publication_date desc" "$synopsis_field")

        log_debug "GET $url"

        local body
        if ! body=$(api_get "$url"); then
            echo "$all_docs"
            return 1
        fi

        local docs num_found
        docs=$(echo "$body" | jq -r '.response.docs // []')
        num_found=$(echo "$body" | jq -r '.response.numFound // 0')
        local doc_count
        doc_count=$(echo "$docs" | jq 'length')

        if [[ "$doc_count" -eq 0 ]]; then
            break
        fi

        all_docs=$(echo "$all_docs $docs" | jq -s '.[0] + .[1]')

        local total
        total=$(echo "$all_docs" | jq 'length')

        if [[ "$max_rows" -gt 0 ]] && [[ "$total" -ge "$max_rows" ]]; then
            all_docs=$(echo "$all_docs" | jq ".[:${max_rows}]")
            break
        fi

        if [[ "$doc_count" -lt "$page_size" ]]; then
            break
        fi

        start=$((start + doc_count))
        if [[ "$start" -ge "$num_found" ]]; then
            break
        fi
    done

    echo "$all_docs"
    return 0
}

# ---------------------------------------------------------------------------
# INI parser
# ---------------------------------------------------------------------------

parse_filters() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_error "Filters file not found: $file"
        exit 1
    fi

    FILTER_NAMES=()
    declare -gA FILTER_PRODUCT=()
    declare -gA FILTER_SYNOPSIS=()

    local current_section=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && continue

        # Section header
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            FILTER_NAMES+=("$current_section")
            FILTER_PRODUCT["$current_section"]=""
            FILTER_SYNOPSIS["$current_section"]=""
            continue
        fi

        # Key = value
        if [[ -n "$current_section" ]] && [[ "$line" == *=* ]]; then
            local key="${line%%=*}"
            local value="${line#*=}"
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"

            case "$key" in
                product)  FILTER_PRODUCT["$current_section"]="$value" ;;
                synopsis) FILTER_SYNOPSIS["$current_section"]="$value" ;;
            esac
        fi
    done < "$file"

    if [[ ${#FILTER_NAMES[@]} -eq 0 ]]; then
        log_error "No filter sections found in $file"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        local raw
        raw=$(cat "$STATE_FILE")
        if echo "$raw" | jq '.' >/dev/null 2>&1; then
            echo "$raw"
        else
            log_warn "Could not read state file ($STATE_FILE), starting fresh."
            echo '{}'
        fi
    else
        echo '{}'
    fi
}

save_state() {
    local state="$1"
    echo "$state" | jq '.' > "$STATE_FILE"
}

get_after_date() {
    local state="$1"
    local last_run
    last_run=$(echo "$state" | jq -r '.last_run // empty')

    if [[ -n "$last_run" ]]; then
        echo "${last_run:0:10}"
    else
        date -u -d "-${INITIAL_DAYS} days" +%Y-%m-%d 2>/dev/null \
            || date -u -v-${INITIAL_DAYS}d +%Y-%m-%d 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# Formatters
# ---------------------------------------------------------------------------

format_errata_text() {
    local docs_json="$1"
    local filter_name="${2:-}"

    echo "$docs_json" | jq -r --arg name "$filter_name" '
        .[] | [
            .id // "N/A",
            (.portal_advisory_type // "N/A"),
            (.portal_severity // "None"),
            ((.portal_publication_date // "N/A") | .[:10]),
            (.portal_synopsis // "N/A"),
            (.view_uri // "N/A")
        ] | "  \(.[0] | . + " " * (22 - length)) \(.[1] | . + " " * (30 - length)) \(.[2] | . + " " * (12 - length)) \(.[3])  \(.[4])\n  \(" " * 22) \(.[5])"
    '
}

format_errata_json() {
    local docs_json="$1"
    local filter_name="${2:-}"

    if [[ -n "$filter_name" ]]; then
        echo "$docs_json" | jq --arg f "$filter_name" '[.[] | {
            filter: $f,
            id: .id,
            synopsis: .portal_synopsis,
            type: .portal_advisory_type,
            severity: (.portal_severity // "None"),
            date: ((.portal_publication_date // "N/A") | .[:10]),
            products: ((.portal_product_names // []) | join(", ")),
            url: (.view_uri // "N/A")
        }]'
    else
        echo "$docs_json" | jq '[.[] | {
            id: .id,
            synopsis: .portal_synopsis,
            type: .portal_advisory_type,
            severity: (.portal_severity // "None"),
            date: ((.portal_publication_date // "N/A") | .[:10]),
            products: ((.portal_product_names // []) | join(", ")),
            url: (.view_uri // "N/A")
        }]'
    fi
}

format_errata_csv_header() {
    local with_filter="${1:-false}"
    if $with_filter; then
        echo "filter,id,synopsis,type,severity,date,products,url"
    else
        echo "id,synopsis,type,severity,date,products,url"
    fi
}

format_errata_csv_rows() {
    local docs_json="$1"
    local filter_name="${2:-}"

    if [[ -n "$filter_name" ]]; then
        echo "$docs_json" | jq -r --arg f "$filter_name" '.[] |
            [$f, .id, .portal_synopsis, .portal_advisory_type,
             (.portal_severity // "None"),
             ((.portal_publication_date // "N/A") | .[:10]),
             ((.portal_product_names // []) | join(", ")),
             (.view_uri // "N/A")]
            | @csv'
    else
        echo "$docs_json" | jq -r '.[] |
            [.id, .portal_synopsis, .portal_advisory_type,
             (.portal_severity // "None"),
             ((.portal_publication_date // "N/A") | .[:10]),
             ((.portal_product_names // []) | join(", ")),
             (.view_uri // "N/A")]
            | @csv'
    fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_monitor() {
    local reset_filters=()
    local reset_after=""

    # Parse monitor-specific args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reset-filters)
                shift
                while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
                    reset_filters+=("$1")
                    shift
                done
                ;;
            --reset-after)
                shift
                reset_after="${1:-}"
                shift
                ;;
            *) shift ;;
        esac
    done

    # Handle reset
    if [[ ${#reset_filters[@]} -gt 0 ]]; then
        _reset_state "${reset_filters[@]}" "$reset_after"
        return
    fi

    parse_filters "$FILTERS_FILE"

    local state
    state=$(load_state)
    local after_date
    after_date=$(get_after_date "$state")

    if $DRY_RUN; then
        echo "Dry run -- the following queries would be made:"
        for name in "${FILTER_NAMES[@]}"; do
            local q="${FILTER_SYNOPSIS[$name]:-*:*}"
            [[ -z "$q" ]] && q="*:*"
            local product="${FILTER_PRODUCT[$name]:-}"
            echo "  [$name]"
            echo "    query:   $q"
            [[ -n "$product" ]] && echo "    product: $product"
            echo "    after:   $after_date"
        done
        return
    fi

    log_debug "Querying errata published after $after_date for ${#FILTER_NAMES[@]} filter(s)"

    local all_json_results="[]"
    local all_succeeded=true
    local total_new=0
    local filters_with_new=0
    local output=""

    # Text header / CSV header
    if [[ "$OUTPUT_FORMAT" == "csv" ]]; then
        output=$(format_errata_csv_header true)
        output+=$'\n'
    fi

    for (( i=0; i<${#FILTER_NAMES[@]}; i++ )); do
        local name="${FILTER_NAMES[$i]}"
        local q="${FILTER_SYNOPSIS[$name]:-}"
        [[ -z "$q" ]] && q="*:*"
        local product="${FILTER_PRODUCT[$name]:-}"

        log_debug "Querying filter: $name (q=$q, product=$product)"

        local docs
        if ! docs=$(fetch_errata "$q" "$product" "$after_date" "" "" "0" "true"); then
            all_succeeded=false
            docs="[]"
        fi

        # Get previously seen errata IDs for this filter
        local seen_ids
        seen_ids=$(echo "$state" | jq -r --arg n "$name" '.seen_errata[$n] // [] | .[]')

        # Filter out already-seen errata
        local new_docs
        if [[ -n "$seen_ids" ]]; then
            local seen_json
            seen_json=$(echo "$seen_ids" | jq -R -s 'split("\n") | map(select(. != ""))')
            new_docs=$(echo "$docs" | jq --argjson seen "$seen_json" '[.[] | select(.id as $id | $seen | index($id) | not)]')
        else
            new_docs="$docs"
        fi

        local new_count
        new_count=$(echo "$new_docs" | jq 'length')
        total_new=$((total_new + new_count))
        [[ "$new_count" -gt 0 ]] && filters_with_new=$((filters_with_new + 1))

        # Format per filter
        case "$OUTPUT_FORMAT" in
            text)
                output+="=== ${name} (${new_count} new errat"
                if [[ "$new_count" -eq 1 ]]; then
                    output+="um"
                else
                    output+="a"
                fi
                output+=") ==="$'\n'
                if [[ "$new_count" -eq 0 ]]; then
                    output+="  (none)"$'\n'
                else
                    output+=$(format_errata_text "$new_docs" "$name")
                    output+=$'\n'
                fi
                output+=$'\n'
                ;;
            json)
                local json_chunk
                json_chunk=$(format_errata_json "$new_docs" "$name")
                all_json_results=$(echo "$all_json_results $json_chunk" | jq -s '.[0] + .[1]')
                ;;
            csv)
                if [[ "$new_count" -gt 0 ]]; then
                    output+=$(format_errata_csv_rows "$new_docs" "$name")
                    output+=$'\n'
                fi
                ;;
        esac

        # Update seen errata in state
        local all_ids
        all_ids=$(echo "$docs" | jq '[.[].id] | sort')
        local existing_ids
        existing_ids=$(echo "$state" | jq --arg n "$name" '.seen_errata[$n] // []')
        local merged_ids
        merged_ids=$(echo "$existing_ids $all_ids" | jq -s '.[0] + .[1] | unique | sort')
        state=$(echo "$state" | jq --arg n "$name" --argjson ids "$merged_ids" '.seen_errata[$n] = $ids')

        if [[ $i -lt $((${#FILTER_NAMES[@]} - 1)) ]]; then
            sleep 0.5
        fi
    done

    # Final output
    case "$OUTPUT_FORMAT" in
        text)
            output+="Total: ${total_new} new errat"
            if [[ "$total_new" -eq 1 ]]; then
                output+="um"
            else
                output+="a"
            fi
            output+=" across ${filters_with_new} filter"
            [[ "$filters_with_new" -ne 1 ]] && output+="s"
            echo "$output"
            ;;
        json)
            echo "$all_json_results" | jq '.'
            ;;
        csv)
            echo -n "$output"
            ;;
    esac

    # Write to file
    if [[ -n "$OUTPUT_FILE" ]]; then
        case "$OUTPUT_FORMAT" in
            text) echo "$output" > "$OUTPUT_FILE" ;;
            json) echo "$all_json_results" | jq '.' > "$OUTPUT_FILE" ;;
            csv)  echo -n "$output" > "$OUTPUT_FILE" ;;
        esac
        echo "Report written to $OUTPUT_FILE"
    fi

    # Update last_run
    if $all_succeeded; then
        state=$(echo "$state" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" '.last_run = $ts')
    else
        log_warn "Some filters failed; last_run timestamp NOT updated. Re-run to retry."
    fi

    save_state "$state"

    if $EXIT_CODE_MODE && [[ "$total_new" -gt 0 ]]; then
        exit 2
    fi
}

cmd_list_products() {
    local search=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --search|-s)
                shift
                search="${1:-}"
                shift
                ;;
            *) shift ;;
        esac
    done

    if $DRY_RUN; then
        echo "Dry run -- would query product facets from the API"
        return
    fi

    local url="${API_URL}?"
    url+="q=$(urlencode '*:*')"
    url+="&start=0&rows=0"
    url+="&fq=$(urlencode 'documentKind:("Errata")')"
    url+="&facet=true"
    url+="&facet.field=portal_product_names"
    url+="&facet.mincount=1"
    url+="&facet.limit=1000"

    log_debug "GET $url"

    local body
    if ! body=$(api_get "$url"); then
        log_error "Failed to fetch product list"
        exit 1
    fi

    local products
    products=$(echo "$body" | jq '.facet_counts.facet_fields.portal_product_names // []')

    # Convert pairs to objects
    local products_list
    products_list=$(echo "$products" | jq '[range(0; length; 2) as $i | {name: .[$i], count: .[$i+1]}]')

    # Apply search filter
    if [[ -n "$search" ]]; then
        local search_lower
        search_lower=$(echo "$search" | tr '[:upper:]' '[:lower:]')
        products_list=$(echo "$products_list" | jq --arg s "$search_lower" '[.[] | select(.name | ascii_downcase | contains($s))]')
    fi

    local count
    count=$(echo "$products_list" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo "No products found."
        return
    fi

    case "$OUTPUT_FORMAT" in
        text)
            echo "$products_list" | jq -r '.[] | "  \(.name)  (\(.count) errata)"'
            echo ""
            echo "Total: ${count} products"
            if [[ -n "$search" ]]; then
                echo "(filtered by: \"$search\")"
            fi
            ;;
        json)
            echo "$products_list" | jq '[.[] | {product: .name, errata_count: .count}]'
            ;;
        csv)
            echo "product,errata_count"
            echo "$products_list" | jq -r '.[] | [.name, .count] | @csv'
            ;;
    esac

    if [[ -n "$OUTPUT_FILE" ]]; then
        case "$OUTPUT_FORMAT" in
            text)
                {
                    echo "$products_list" | jq -r '.[] | "  \(.name)  (\(.count) errata)"'
                    echo ""
                    echo "Total: ${count} products"
                } > "$OUTPUT_FILE"
                ;;
            json) echo "$products_list" | jq '[.[] | {product: .name, errata_count: .count}]' > "$OUTPUT_FILE" ;;
            csv)
                {
                    echo "product,errata_count"
                    echo "$products_list" | jq -r '.[] | [.name, .count] | @csv'
                } > "$OUTPUT_FILE"
                ;;
        esac
        echo "Written to $OUTPUT_FILE"
    fi
}

cmd_search() {
    local product="" synopsis="" after="" advisory_type="" severity=""
    local rows=50

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --filters)    shift; FILTERS_FILE="${1:-filters.conf}"; FILTERS_EXPLICIT=true; shift ;;
            --product)    shift; product="${1:-}"; shift ;;
            --synopsis)   shift; synopsis="${1:-}"; shift ;;
            --after)      shift; after="${1:-}"; shift ;;
            --type)       shift; advisory_type="${1:-}"; shift ;;
            --severity)   shift; severity="${1:-}"; shift ;;
            --rows)       shift; rows="${1:-50}"; shift ;;
            *) shift ;;
        esac
    done

    if $FILTERS_EXPLICIT; then
        if [[ ! -f "$FILTERS_FILE" ]]; then
            log_error "Filters file not found: $FILTERS_FILE"
            exit 1
        fi
        _cmd_search_filters "$after" "$advisory_type" "$severity" "$rows"
    else
        _cmd_search_flat "$product" "$synopsis" "$after" "$advisory_type" "$severity" "$rows"
    fi
}

_cmd_search_flat() {
    local product="$1" synopsis="$2" after="$3"
    local advisory_type="$4" severity="$5" rows="$6"
    local q="${synopsis:-*:*}"

    if $DRY_RUN; then
        echo "Dry run -- the following query would be made:"
        echo "  query:    $q"
        [[ -n "$product" ]]       && echo "  product:  $product"
        [[ -n "$after" ]]         && echo "  after:    $after"
        [[ -n "$advisory_type" ]] && echo "  type:     $advisory_type"
        [[ -n "$severity" ]]      && echo "  severity: $severity"
        echo "  rows:     $rows"
        return
    fi

    local docs
    if ! docs=$(fetch_errata "$q" "$product" "$after" "$advisory_type" "$severity" "$rows"); then
        local doc_count
        doc_count=$(echo "$docs" | jq 'length')
        if [[ "$doc_count" -eq 0 ]]; then
            echo "Error: API request failed."
            exit 1
        fi
    fi

    local doc_count
    doc_count=$(echo "$docs" | jq 'length')

    case "$OUTPUT_FORMAT" in
        text)
            if [[ "$doc_count" -gt 0 ]]; then
                format_errata_text "$docs"
            fi
            echo ""
            echo "Total: ${doc_count} errat$([ "$doc_count" -eq 1 ] && echo "um" || echo "a")"
            ;;
        json)
            format_errata_json "$docs"
            ;;
        csv)
            format_errata_csv_header false
            if [[ "$doc_count" -gt 0 ]]; then
                format_errata_csv_rows "$docs"
            fi
            ;;
    esac

    if [[ -n "$OUTPUT_FILE" ]]; then
        case "$OUTPUT_FORMAT" in
            text)
                {
                    [[ "$doc_count" -gt 0 ]] && format_errata_text "$docs"
                    echo ""
                    echo "Total: ${doc_count} errata"
                } > "$OUTPUT_FILE"
                ;;
            json) format_errata_json "$docs" > "$OUTPUT_FILE" ;;
            csv)
                {
                    format_errata_csv_header false
                    [[ "$doc_count" -gt 0 ]] && format_errata_csv_rows "$docs"
                } > "$OUTPUT_FILE"
                ;;
        esac
        echo "Report written to $OUTPUT_FILE"
    fi
}

_cmd_search_filters() {
    local after="$1" advisory_type="$2" severity="$3" rows="$4"

    parse_filters "$FILTERS_FILE"

    if $DRY_RUN; then
        echo "Dry run -- the following queries would be made:"
        for name in "${FILTER_NAMES[@]}"; do
            local q="${FILTER_SYNOPSIS[$name]:-*:*}"
            [[ -z "$q" ]] && q="*:*"
            local product="${FILTER_PRODUCT[$name]:-}"
            echo "  [$name]"
            echo "    query:   $q"
            [[ -n "$product" ]]       && echo "    product: $product"
            [[ -n "$after" ]]         && echo "    after:   $after"
            [[ -n "$advisory_type" ]] && echo "    type:    $advisory_type"
            [[ -n "$severity" ]]      && echo "    severity: $severity"
            echo "    rows:    $rows"
        done
        return
    fi

    local all_json_results="[]"
    local total=0
    local filters_with_results=0
    local output=""

    if [[ "$OUTPUT_FORMAT" == "csv" ]]; then
        output=$(format_errata_csv_header true)
        output+=$'\n'
    fi

    for (( i=0; i<${#FILTER_NAMES[@]}; i++ )); do
        local name="${FILTER_NAMES[$i]}"
        local q="${FILTER_SYNOPSIS[$name]:-}"
        [[ -z "$q" ]] && q="*:*"
        local product="${FILTER_PRODUCT[$name]:-}"

        log_debug "Querying filter: $name (q=$q, product=$product)"

        local docs
        if ! docs=$(fetch_errata "$q" "$product" "$after" "$advisory_type" "$severity" "$rows" "true"); then
            docs="[]"
        fi

        local doc_count
        doc_count=$(echo "$docs" | jq 'length')
        total=$((total + doc_count))
        [[ "$doc_count" -gt 0 ]] && filters_with_results=$((filters_with_results + 1))

        case "$OUTPUT_FORMAT" in
            text)
                output+="=== ${name} (${doc_count} errat"
                if [[ "$doc_count" -eq 1 ]]; then
                    output+="um"
                else
                    output+="a"
                fi
                output+=") ==="$'\n'
                if [[ "$doc_count" -eq 0 ]]; then
                    output+="  (none)"$'\n'
                else
                    output+=$(format_errata_text "$docs" "$name")
                    output+=$'\n'
                fi
                output+=$'\n'
                ;;
            json)
                local json_chunk
                json_chunk=$(format_errata_json "$docs" "$name")
                all_json_results=$(echo "$all_json_results $json_chunk" | jq -s '.[0] + .[1]')
                ;;
            csv)
                if [[ "$doc_count" -gt 0 ]]; then
                    output+=$(format_errata_csv_rows "$docs" "$name")
                    output+=$'\n'
                fi
                ;;
        esac

        if [[ $i -lt $((${#FILTER_NAMES[@]} - 1)) ]]; then
            sleep 0.5
        fi
    done

    case "$OUTPUT_FORMAT" in
        text)
            output+="Total: ${total} errat"
            if [[ "$total" -eq 1 ]]; then
                output+="um"
            else
                output+="a"
            fi
            output+=" across ${filters_with_results} filter"
            [[ "$filters_with_results" -ne 1 ]] && output+="s"
            echo "$output"
            ;;
        json)
            echo "$all_json_results" | jq '.'
            ;;
        csv)
            echo -n "$output"
            ;;
    esac

    if [[ -n "$OUTPUT_FILE" ]]; then
        case "$OUTPUT_FORMAT" in
            text) echo "$output" > "$OUTPUT_FILE" ;;
            json) echo "$all_json_results" | jq '.' > "$OUTPUT_FILE" ;;
            csv)  echo -n "$output" > "$OUTPUT_FILE" ;;
        esac
        echo "Report written to $OUTPUT_FILE"
    fi
}

_reset_state() {
    local state
    state=$(load_state)

    local reset_after=""
    local filter_names=()

    for arg in "$@"; do
        if [[ "$arg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            reset_after="$arg"
        elif [[ -n "$arg" ]]; then
            filter_names+=("$arg")
        fi
    done

    if [[ ${#filter_names[@]} -eq 0 ]]; then
        return
    fi

    local contains_all=false
    for name in "${filter_names[@]}"; do
        [[ "$name" == "all" ]] && contains_all=true
    done

    if $contains_all; then
        local cleared
        cleared=$(echo "$state" | jq -r '.seen_errata // {} | keys | join(", ")')
        [[ -z "$cleared" ]] && cleared="(none)"
        state=$(echo "$state" | jq '.seen_errata = {}')
        echo "Cleared seen errata for all filters: $cleared"
    else
        for name in "${filter_names[@]}"; do
            if echo "$state" | jq -e --arg n "$name" '.seen_errata[$n] != null' >/dev/null 2>&1; then
                state=$(echo "$state" | jq --arg n "$name" 'del(.seen_errata[$n])')
                echo "Cleared seen errata for: $name"
            else
                echo "No state found for: $name (nothing to clear)"
            fi
        done
    fi

    if [[ -n "$reset_after" ]]; then
        state=$(echo "$state" | jq --arg ts "${reset_after}T00:00:00+00:00" '.last_run = $ts')
        echo "Reset last_run to: $reset_after"
    fi

    save_state "$state"
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: rh_errata_monitor.sh [global-flags] <command> [command-flags]

Commands:
  monitor        Check for new errata per filter (default)
  list-products  List available product names from the API
  search         One-off stateless errata search
                 (with --filters: runs each filter section, grouped output)

Global flags:
  --filters FILE       Path to INI filter config (default: filters.conf)
  --state-file FILE    Path to JSON state file (default: .errata_state.json)
  --initial-days N     Lookback days on first run (default: 30)
  --format FORMAT      Output: text, json, csv (default: text)
  --output FILE        Write report to file
  --exit-code          Exit 2 when new errata found
  --dry-run            Show queries without hitting API
  -v, --verbose        Debug logging
  -h, --help           Show this help

Monitor flags:
  --reset-filters F..  Clear seen-errata for filters (use 'all' for all)
  --reset-after DATE   Rewind last_run to DATE (YYYY-MM-DD)

List-products flags:
  --search, -s TEXT    Filter products by name (case-insensitive)

Search flags:
  --filters FILE       Path to INI filter config (grouped output per filter)
  --product NAME       Filter by product name
  --synopsis TEXT      Search synopsis/content
  --after DATE         Errata after YYYY-MM-DD
  --type TYPE          security, bugfix, enhancement
  --severity SEV       critical, important, moderate, low
  --rows N             Max results (default: 50)
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    check_deps

    local command=""
    local cmd_args=()

    # Parse global flags first, then command and its args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --filters)       shift; FILTERS_FILE="${1:-filters.conf}"; FILTERS_EXPLICIT=true; shift ;;
            --state-file)    shift; STATE_FILE="${1:-.errata_state.json}"; shift ;;
            --initial-days)  shift; INITIAL_DAYS="${1:-30}"; shift ;;
            --format)        shift; OUTPUT_FORMAT="${1:-text}"; shift ;;
            --output)        shift; OUTPUT_FILE="${1:-}"; shift ;;
            --exit-code)     EXIT_CODE_MODE=true; shift ;;
            --dry-run)       DRY_RUN=true; shift ;;
            -v|--verbose)    VERBOSE=true; shift ;;
            -h|--help)       usage; exit 0 ;;
            monitor|list-products|search)
                command="$1"
                shift
                cmd_args=("$@")
                break
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    command="${command:-monitor}"

    case "$command" in
        monitor)        cmd_monitor "${cmd_args[@]+"${cmd_args[@]}"}" ;;
        list-products)  cmd_list_products "${cmd_args[@]+"${cmd_args[@]}"}" ;;
        search)         cmd_search "${cmd_args[@]+"${cmd_args[@]}"}" ;;
        *)
            log_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
