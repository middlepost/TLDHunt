#!/usr/bin/env bash

# Color definitions
: "${blue:=\033[0;34m}"
: "${cyan:=\033[0;36m}"
: "${reset:=\033[0m}"
: "${red:=\033[0;31m}"
: "${green:=\033[0;32m}"
: "${orange:=\033[0;33m}"
: "${bold:=\033[1m}"
: "${b_green:=\033[1;32m}"
: "${b_red:=\033[1;31m}"
: "${b_orange:=\033[1;33m}"

# Default values
nreg=false
update_tld=false
quiet=false
tld_file="tlds.txt"
tld_url="https://data.iana.org/TLD/tlds-alpha-by-domain.txt"

# Check if whois is installed
command -v whois &> /dev/null || { echo "whois not installed. You must install whois to use this tool." >&2; exit 1; }

# Check if curl is installed (needed for TLD update)
command -v curl &> /dev/null || { echo "curl not installed. You must install curl to use this tool." >&2; exit 1; }

usage() {
    echo "Usage: $0 -k <keyword> [-e <tld> | -E <tld-file>] [-x] [-q] [--update-tld]"
    echo "Example: $0 -k linuxsec -E tlds.txt"
    echo "       : $0 --update-tld"
    echo "       : $0 -k test -e .ai -q"
    exit 1
}

# Argument parsing
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -k|--keyword) keyword="$2"; shift ;;
        -e|--tld) tld="$2"; shift ;;
        -E|--tld-file) exts="$2"; shift ;;
        -x|--not-registered) nreg=true ;;
        -q|--quiet) quiet=true ;;
        --update-tld) update_tld=true ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Banner (only if not quiet) - print after argument parsing
if [[ "$quiet" = false ]]; then
    cat << "EOF"
 _____ _    ___  _  _          _   
|_   _| |  |   \| || |_  _ _ _| |_ 
  | | | |__| |) | __ | || | ' \  _|
  |_| |____|___/|_||_|\_,_|_||_\__|
        Domain Availability Checker
EOF
fi

# Validate arguments
if [[ "$update_tld" = true ]]; then
    [[ -n $keyword || -n $tld || -n $exts || "$nreg" = true ]] && { echo "--update-tld cannot be used with other flags."; usage; }
    echo "Fetching TLD data from $tld_url..."
    curl -s "$tld_url" | \
        grep -v '^#' | \
        tr '[:upper:]' '[:lower:]' | \
        sed 's/^/./' > "$tld_file"
    echo "TLDs have been saved to $tld_file."
    exit 0
fi

# Validate arguments
[[ -z $keyword ]] && { echo "Keyword is required."; usage; }
[[ -n $tld && -n $exts ]] && { echo "You can only specify one of -e or -E options."; usage; }
[[ -z $tld && -z $exts ]] && { echo "Either -e or -E option is required."; usage; }
[[ -n $exts && ! -f $exts ]] && { echo "TLD file $exts not found."; usage; }

# Load TLDs
tlds=()
if [[ -n $exts ]]; then
    readarray -t tlds < "$exts"
else
    tlds=("$tld")
fi

# Function to check domain availability
check_domain() {
    local domain="$1"
    local whois_output
    # Use timeout to prevent hanging (10 seconds default for reliability, configurable via WHOIS_TIMEOUT env var)
    # Try timeout (Linux), gtimeout (macOS via Homebrew coreutils), or fall back to no timeout
    local timeout_cmd=""
    local timeout_sec="${WHOIS_TIMEOUT:-10}"
    if command -v timeout &> /dev/null; then
        timeout_cmd="timeout $timeout_sec"
    elif command -v gtimeout &> /dev/null; then
        timeout_cmd="gtimeout $timeout_sec"
    fi
    
    # Increase timeout for .ai domains as they often require referral queries
    local actual_timeout="$timeout_sec"
    if [[ "$domain" == *.ai ]]; then
        actual_timeout=$((timeout_sec + 5))  # Add 5 seconds for .ai domains (total 15 seconds default)
    fi
    
    if [[ -n "$timeout_cmd" ]]; then
        # Rebuild timeout command with adjusted timeout value
        if command -v timeout &> /dev/null; then
            whois_output=$(timeout "$actual_timeout" whois "$domain" 2>/dev/null)
        elif command -v gtimeout &> /dev/null; then
            whois_output=$(gtimeout "$actual_timeout" whois "$domain" 2>/dev/null)
        else
            whois_output=$(whois "$domain" 2>/dev/null)
        fi
    else
        whois_output=$(whois "$domain" 2>/dev/null)
    fi
    
    # Check for patterns indicating domain is registered
    # Important: For .ai and similar TLDs, IANA returns TLD-level info (nserver for TLD, status for TLD)
    # We need to look for domain-specific info, not TLD-level info
    # Look for: "Domain Name: [actual domain]" (not just "domain: AI"), registrar info, registry domain ID
    local registered_patterns
    registered_patterns=$(echo "$whois_output" | grep -iE "Domain Name:\s+[^[:space:]]+\.ai|Registry Domain ID|Registrar WHOIS Server|Registrar:|Registry Registrant|Domain Status:")
    
    # Also check for name servers, but only if we also have domain-specific info (to avoid matching TLD nservers)
    local has_domain_name
    has_domain_name=$(echo "$whois_output" | grep -iE "Domain Name:\s+[^[:space:]]+\.ai" | wc -l | tr -d ' ')
    if [[ "$has_domain_name" -gt 0 ]]; then
        # If we have domain name, also check for name servers (these are domain-specific)
        local domain_nservers
        domain_nservers=$(echo "$whois_output" | grep -iE "Name Server:|nserver:" | grep -v "\.NIC\.AI" | wc -l | tr -d ' ')
        if [[ "$domain_nservers" -gt 0 ]]; then
            registered_patterns="${registered_patterns}
$(echo "$whois_output" | grep -iE "Name Server:|nserver:" | grep -v "\.NIC\.AI")"
        fi
    fi
    
    # Check for patterns indicating domain is available (not found)
    # For .ai domains, the registry returns "Domain not found." when available
    local available_patterns
    available_patterns=$(echo "$whois_output" | grep -iE "Domain not found|No match|NOT FOUND|No entries found|Status:\s*(free|available)|is available for registration|No Data Found|not registered|No such domain")
    
    # Special check: if output is very short or only contains IANA referral info, might be incomplete
    local output_lines
    output_lines=$(echo "$whois_output" | wc -l | tr -d ' ')
    local has_iana_only
    has_iana_only=$(echo "$whois_output" | grep -iE "IANA WHOIS|This query returned" | wc -l | tr -d ' ')
    
    # Check for rate limiting errors
    local rate_limit_error
    rate_limit_error=$(echo "$whois_output" | grep -iE "rate limit|too many requests|quota exceeded|connection refused|timeout|timed out" | wc -l | tr -d ' ')
    
    # If we only got IANA info and no domain-specific info, query might be incomplete
    # For .ai domains, explicitly query the registry server
    if [[ "$has_iana_only" -gt 0 && -z "$registered_patterns" && -z "$available_patterns" && "$rate_limit_error" -eq 0 ]]; then
        if [[ "$domain" == *.ai ]]; then
            # Add delay before retry to avoid rate limiting (exponential backoff)
            local retry_delay=2
            sleep $retry_delay
            
            # Query the registry directly
            local registry_output
            if command -v timeout &> /dev/null; then
                registry_output=$(timeout "$actual_timeout" whois -h whois.nic.ai "$domain" 2>/dev/null)
            elif command -v gtimeout &> /dev/null; then
                registry_output=$(gtimeout "$actual_timeout" whois -h whois.nic.ai "$domain" 2>/dev/null)
            else
                registry_output=$(whois -h whois.nic.ai "$domain" 2>/dev/null)
            fi
            
            # Check for rate limiting in registry response
            rate_limit_error=$(echo "$registry_output" | grep -iE "rate limit|too many requests|quota exceeded|connection refused" | wc -l | tr -d ' ')
            
            if [[ -n "$registry_output" && "$rate_limit_error" -eq 0 ]]; then
                # Combine IANA and registry output
                whois_output="$whois_output
$registry_output"
                # Re-check patterns with combined output
                registered_patterns=$(echo "$whois_output" | grep -iE "Domain Name:\s+[^[:space:]]+\.ai|Registry Domain ID|Registrar WHOIS Server|Registrar:|Registry Registrant|Domain Status:")
                available_patterns=$(echo "$whois_output" | grep -iE "Domain not found|No match|NOT FOUND|No entries found|Status:\s*(free|available)|is available for registration|No Data Found|not registered|No such domain")
            fi
        fi
    fi

    if [[ -n "$registered_patterns" ]]; then
        if [[ "$nreg" = false ]]; then
            local expiry_date
            expiry_date=$(echo "$whois_output" | grep -iE "Expiry Date|Expiration Date|Registry Expiry Date|Expiration Time|expires:" | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}' | uniq | head -1)
            if [[ -n $expiry_date ]]; then
                echo -e "[${b_red}taken${reset}] $domain - Exp Date: ${orange}$expiry_date${reset}"
            else
                echo -e "[${b_red}taken${reset}] $domain - No expiry date found"
            fi
        fi
    elif [[ -n "$available_patterns" ]]; then
        # Only mark as available if we have clear "not found" patterns
        echo -e "[${b_green}avail${reset}] $domain"
    else
        # No clear indicators - be conservative
        # If we got substantial output but no registered/available patterns, it's likely incomplete
        if [[ -n "$whois_output" ]]; then
            # Check if output looks like it might be incomplete (has IANA info but no domain details)
            local has_domain_info
            has_domain_info=$(echo "$whois_output" | grep -iE "domain name|registrant|registrar|name server" | wc -l | tr -d ' ')
            
            # Check for rate limiting errors in output
            if [[ "$rate_limit_error" -gt 0 ]]; then
                echo -e "[${b_orange}rate-limited${reset}] $domain - Rate limited by whois server (retry later)"
            elif [[ "$has_domain_info" -eq 0 && "$output_lines" -gt 10 ]]; then
                # Has output but no domain-specific info - likely incomplete query
                echo -e "[${b_orange}unknown${reset}] $domain - Incomplete query (may be rate-limited)"
            elif [[ -z "$whois_output" || "$output_lines" -lt 3 ]]; then
                # Very short or empty output - might be available, but be cautious
                echo -e "[${b_orange}unknown${reset}] $domain - Insufficient data"
            else
                # Some output but unclear - mark as unknown to be safe
                echo -e "[${b_orange}unknown${reset}] $domain - Unable to determine status"
            fi
        else
            # No output at all - could be timeout or error
            echo -e "[${b_orange}unknown${reset}] $domain - No response from whois"
        fi
    fi
}

# Process TLDs
for ext in "${tlds[@]}"; do
    domain="$keyword$ext"
    check_domain "$domain" &
    if (( $(jobs -r -p | wc -l) >= 30 )); then
        wait -n
    fi
done
wait