#!/usr/bin/env bash

# Adjust if your list is elsewhere
DOMAIN_LIST="$PWD/domains.txt"

# Base paths (adjust if your layout differs)
BASE="$PWD/"
RECON_SCRIPT="$BASE/reconftw.sh"
RECON_DIR="$BASE/Recon"
OUT_DIR="$BASE/data"
CONFIG_FILE="$BASE/script.config"

# Create default config file if it doesn't exist
if [[ ! -f "$CONFIG_FILE" ]]; then
    cat > "$CONFIG_FILE" << 'EOF'
# Script Configuration - Edit this file while the script is running
# Changes will take effect on the next domain iteration

# ============================================
# WORKFLOW CONTROL - Enable/Disable Tools
# ============================================
# Set to "true" to enable, "false" to disable
RUN_RECONFTW="true"
RUN_HTTPX="false"
RUN_KATANA="false"
RUN_NUCLEI_CREDENTIALS="false"
RUN_NUCLEI_FULL="false"

# ============================================
# CUSTOM TOOLS (Add your own!)
# ============================================
# Set to "true" to enable custom tools
RUN_CUSTOM_TOOL_1="false"
RUN_CUSTOM_TOOL_2="false"
RUN_CUSTOM_TOOL_3="false"

# Custom tool 1: Example - Run nmap on live hosts
CUSTOM_TOOL_1_NAME="Nmap Scan"
CUSTOM_TOOL_1_CMD='cat "$BASE/bugs/$domain.httpx" | cut -d " " -f 1 | cut -d "/" -f 3 | nmap -iL - -oN "$BASE/bugs/nmap.txt"'
CUSTOM_TOOL_1_NOTIFY_ID="nmap"
CUSTOM_TOOL_1_OUTPUT="$BASE/bugs/nmap.txt"

# Custom tool 2: Example - Run waybackurls
CUSTOM_TOOL_2_NAME="Wayback URLs"
CUSTOM_TOOL_2_CMD='cat "$out_new" | waybackurls | tee "$BASE/bugs/waybackurls.txt"'
CUSTOM_TOOL_2_NOTIFY_ID="wayback"
CUSTOM_TOOL_2_OUTPUT="$BASE/bugs/waybackurls.txt"

# Custom tool 3: Example - Your custom tool here
CUSTOM_TOOL_3_NAME="Custom Tool 3"
CUSTOM_TOOL_3_CMD='echo "Add your command here"'
CUSTOM_TOOL_3_NOTIFY_ID="custom3"
CUSTOM_TOOL_3_OUTPUT="$BASE/bugs/custom3.txt"

# ============================================
# TOOL PARAMETERS
# ============================================

# ReconFTW Options
RECONFTW_OPTS="-s"

# HTTPX Parameters
HTTPX_TIMEOUT=5
HTTPX_EXTRA_OPTS="-sc -title -cl -wc -td -nc"

# Katana Parameters
KATANA_DEPTH=1
KATANA_REGEX="\.js$"
KATANA_EXTRA_OPTS="-nc -silent"

# Nuclei Parameters
NUCLEI_TEMPLATES="/opt/nuclei-templates/"
NUCLEI_STATS_INTERVAL=60
NUCLEI_EXCLUDE_TAGS="ssl"
NUCLEI_EXCLUDE_SEVERITY="info"
NUCLEI_EXCLUDE_IDS="wp-user-enum,erlang-daemon,CVE-2017-5487,git-mailmap,missing-csp,dns-rebinding,self-signed-ssl,mismatched-ssl,expired-ssl,weak-cipher-suites,unauthenticated-varnish-cache-purge"
NUCLEI_EXTRA_OPTS="-silent -stats -nc"

# Notify IDs
NOTIFY_ID_BUGS="bugs"
EOF
    echo "Created default config file: $CONFIG_FILE"
fi

mkdir -p "$BASE/bugs" || { echo "ERROR: Cannot create bugs directory" >&2; exit 1; }

# safety: must exist
if [[ ! -f "$DOMAIN_LIST" ]]; then
  echo "ERROR: domain list not found: $DOMAIN_LIST" >&2
  exit 1
fi
mkdir -p "$OUT_DIR" || { echo "ERROR: Cannot create output directory" >&2; exit 1; }

# Process domains from domains.txt
for domain in $(cat "$DOMAIN_LIST"); do

    # ============================================
    # RELOAD CONFIG AT START OF EACH DOMAIN
    # ============================================
    echo "----------------------------------------"
    echo "Loading configuration from: $CONFIG_FILE"
    source "$CONFIG_FILE"
    echo "Configuration loaded!"
    echo "----------------------------------------"

    echo "Working on $domain"

    # Clean up bug files at the START of each domain iteration
    rm -f "$BASE/bugs/$domain.httpx" "$BASE/bugs/$domain.nuclei" "$BASE/bugs/$domain.jsurls" "$BASE/bugs/$domain.tokens" 2>/dev/null || true

    # Remove .called_fn file
    called_fn="$RECON_DIR/$domain/.called_fn"
    rm -rf -- "$called_fn" 2>/dev/null || true

    # Run reconFTW
    if [[ "$RUN_RECONFTW" == "true" ]]; then
        echo -n "Running reconftw... "
        start_time=$(date +%s)
        LOG_FILE="/var/log/recon.log"
        # Fallback to local logs if we don't have sudo permissions
        if [[ ! -w /var/log ]]; then
            LOG_FILE="$BASE/logs/recon.log"
        fi
        echo "========================================" >> "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting reconftw for $domain" >> "$LOG_FILE"
        echo "========================================" >> "$LOG_FILE"
        bash "$RECON_SCRIPT" -d "$domain" $RECONFTW_OPTS >> "$LOG_FILE" 2>&1
        end_time=$(date +%s)
        elapsed=$((end_time - start_time))
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Completed in ${elapsed}s" >> "$LOG_FILE"
        echo "time took ${elapsed}s (log: $LOG_FILE)"
    else
        echo "⊘ Skipping reconftw (disabled in config)"
    fi

    # Get subdomains file
    subfile="$RECON_DIR/$domain/subdomains/subdomains.txt"

    # Check if subdomains file exists
    if [[ ! -f "$subfile" ]]; then
        echo "WARNING: Subdomains file not found: $subfile"
        echo "Skipping $domain..."
        continue
    fi

    echo -n "Checking for new subdomains... "
    out_all="$OUT_DIR/$domain.txt.all"
    out_new="$OUT_DIR/$domain.txt.new"
    start_time=$(date +%s)
    cat "$subfile" | anew "$out_all" > "$out_new"
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    new_count=$(wc -l < "$out_new" 2>/dev/null || echo 0)
    echo "found ${new_count} new subdomains (${elapsed}s)"

    # Skip if no new subdomains
    if [[ ! -s "$out_new" ]]; then
        echo "No new subdomains found for $domain, skipping..."
        continue
    fi

    # Run HTTPX
    if [[ "$RUN_HTTPX" == "true" ]]; then
        echo -n "Running httpx (timeout: ${HTTPX_TIMEOUT}s)... "
        start_time=$(date +%s)
        cat "$out_new" | httpx -silent -timeout "$HTTPX_TIMEOUT" $HTTPX_EXTRA_OPTS 2>/dev/null > "$BASE/bugs/$domain.httpx"
        end_time=$(date +%s)
        elapsed=$((end_time - start_time))
        alive_count=$(wc -l < "$BASE/bugs/$domain.httpx" 2>/dev/null || echo 0)
        echo "found ${alive_count} alive hosts - time took ${elapsed}s"
        if [[ -f "$BASE/bugs/$domain.httpx" && -s "$BASE/bugs/$domain.httpx" ]]; then
            notify -data "$BASE/bugs/$domain.httpx" -id "$NOTIFY_ID_HTTPX" -bulk
        fi
    else
        echo "⊘ Skipping httpx (disabled in config)"
    fi

    # Run Katana
    if [[ "$RUN_KATANA" == "true" ]]; then
        if [[ -f "$BASE/bugs/$domain.httpx" && -s "$BASE/bugs/$domain.httpx" ]]; then
            echo -n "Finding JS files with katana (depth: ${KATANA_DEPTH})... "
            start_time=$(date +%s)
            cat "$BASE/bugs/$domain.httpx" | cut -d " " -f 1 | katana $KATANA_EXTRA_OPTS -d "$KATANA_DEPTH" -mr "$KATANA_REGEX" 2>/dev/null | sort -u > "$BASE/bugs/$domain.jsurls"
            end_time=$(date +%s)
            elapsed=$((end_time - start_time))
            js_count=$(wc -l < "$BASE/bugs/$domain.jsurls" 2>/dev/null || echo 0)
            echo "found ${js_count} JS files - time took ${elapsed}s"
        else
            echo "⊘ Skipping katana (no httpx results)"
        fi
    else
        echo "⊘ Skipping katana (disabled in config)"
    fi

    # Run Nuclei Credentials Scan
    if [[ "$RUN_NUCLEI_CREDENTIALS" == "true" ]]; then
        if [[ -f "$BASE/bugs/$domain.jsurls" && -s "$BASE/bugs/$domain.jsurls" ]]; then
            echo "=========================================="
            echo "Scanning for credentials with nuclei..."
            echo "=========================================="
            start_time=$(date +%s)
            nuclei -silent -nc -l "$BASE/bugs/$domain.jsurls" -id credentials-disclosure | tee "$BASE/bugs/$domain.tokens"
            end_time=$(date +%s)
            elapsed=$((end_time - start_time))
            echo "=========================================="
            echo "Credentials scan completed - time took ${elapsed}s"
            echo "=========================================="
            if [[ -f "$BASE/bugs/$domain.tokens" && -s "$BASE/bugs/$domain.tokens" ]]; then
                notify -data "$BASE/bugs/$domain.tokens" -id "$NOTIFY_ID_TOKENS" -bulk
            fi
        else
            echo "⊘ Skipping credentials scan (no JS files found)"
        fi
    else
        echo "⊘ Skipping credentials scan (disabled in config)"
    fi

    # Run Full Nuclei Scan
    if [[ "$RUN_NUCLEI_FULL" == "true" ]]; then
        if [[ -f "$BASE/bugs/$domain.httpx" && -s "$BASE/bugs/$domain.httpx" ]]; then
            echo "=========================================="
            echo "Running full nuclei scan..."
            echo "=========================================="
            start_time=$(date +%s)
            cat "$BASE/bugs/$domain.httpx" | cut -d " " -f 1 | nuclei -t "$NUCLEI_TEMPLATES" $NUCLEI_EXTRA_OPTS -si "$NUCLEI_STATS_INTERVAL" -etags "$NUCLEI_EXCLUDE_TAGS" -es "$NUCLEI_EXCLUDE_SEVERITY" -eid "$NUCLEI_EXCLUDE_IDS" | tee "$BASE/bugs/$domain.nuclei"
            end_time=$(date +%s)
            elapsed=$((end_time - start_time))
            echo "=========================================="
            echo "Full nuclei scan completed - time took ${elapsed}s"
            echo "=========================================="
            if [[ -f "$BASE/bugs/$domain.nuclei" && -s "$BASE/bugs/$domain.nuclei" ]]; then
                notify -data "$BASE/bugs/$domain.nuclei" -id "$NOTIFY_ID_BUGS" -bulk
            fi
        else
            echo "⊘ Skipping full nuclei scan (no httpx results)"
        fi
    else
        echo "⊘ Skipping full nuclei scan (disabled in config)"
    fi

    # ============================================
    # CUSTOM TOOLS EXECUTION
    # ============================================

    # Custom Tool 1
    if [[ "$RUN_CUSTOM_TOOL_1" == "true" ]]; then
        echo -n "Running custom tool: $CUSTOM_TOOL_1_NAME... "
        start_time=$(date +%s)
        eval "$CUSTOM_TOOL_1_CMD" > /dev/null 2>&1
        end_time=$(date +%s)
        elapsed=$((end_time - start_time))
        echo "time took ${elapsed}s"
        if [[ -f "$CUSTOM_TOOL_1_OUTPUT" && -s "$CUSTOM_TOOL_1_OUTPUT" ]]; then
            notify -data "$CUSTOM_TOOL_1_OUTPUT" -id "$CUSTOM_TOOL_1_NOTIFY_ID" -bulk
        fi
    fi

    # Custom Tool 2
    if [[ "$RUN_CUSTOM_TOOL_2" == "true" ]]; then
        echo -n "Running custom tool: $CUSTOM_TOOL_2_NAME... "
        start_time=$(date +%s)
        eval "$CUSTOM_TOOL_2_CMD" > /dev/null 2>&1
        end_time=$(date +%s)
        elapsed=$((end_time - start_time))
        echo "time took ${elapsed}s"
        if [[ -f "$CUSTOM_TOOL_2_OUTPUT" && -s "$CUSTOM_TOOL_2_OUTPUT" ]]; then
            notify -data "$CUSTOM_TOOL_2_OUTPUT" -id "$CUSTOM_TOOL_2_NOTIFY_ID" -bulk
        fi
    fi

    # Custom Tool 3
    if [[ "$RUN_CUSTOM_TOOL_3" == "true" ]]; then
        echo -n "Running custom tool: $CUSTOM_TOOL_3_NAME... "
        start_time=$(date +%s)
        eval "$CUSTOM_TOOL_3_CMD" > /dev/null 2>&1
        end_time=$(date +%s)
        elapsed=$((end_time - start_time))
        echo "time took ${elapsed}s"
        if [[ -f "$CUSTOM_TOOL_3_OUTPUT" && -s "$CUSTOM_TOOL_3_OUTPUT" ]]; then
            notify -data "$CUSTOM_TOOL_3_OUTPUT" -id "$CUSTOM_TOOL_3_NOTIFY_ID" -bulk
        fi
    fi

done
