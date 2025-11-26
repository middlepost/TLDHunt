#!/usr/bin/env bash
# Test all words from wordlist with .ai domain and save to checked.txt
# Optimized for parallel processing

WORDLIST="$1"
OUTPUT_FILE="checked.txt"
MAX_JOBS="${2:-20}"           # Default to 20 concurrent jobs (reduced to avoid rate limiting)
RATE_LIMIT_DELAY="${3:-0.2}"  # Delay between job starts in seconds (default 0.2s = 5 queries/sec)
RESET_OUTPUT="${4:-false}"    # Set to true to start from scratch instead of resuming
START_FROM="${5:-}"           # Optional: begin processing from this word onward

# Prepare output file (resume support)
declare -A processed_words
processed=0

if [[ "$RESET_OUTPUT" == "true" ]]; then
    > "$OUTPUT_FILE"
    echo "Starting fresh. Existing $OUTPUT_FILE has been cleared."
else
    if [[ -f "$OUTPUT_FILE" ]]; then
        while IFS= read -r line; do
            if [[ $line =~ ^Checking:\ (.+)\.ai$ ]]; then
                processed_words["${BASH_REMATCH[1]}"]=1
            fi
        done < "$OUTPUT_FILE"
        processed=${#processed_words[@]}
        echo "Resuming run: found $processed previously processed words in $OUTPUT_FILE"
    else
        > "$OUTPUT_FILE"
    fi
fi

# Count total words for progress
total_words=$(grep -v '^[[:space:]]*$' "$WORDLIST" 2>/dev/null | wc -l | tr -d ' ')
echo "Processing $total_words words with up to $MAX_JOBS concurrent checks..."
if [[ -n "$START_FROM" ]]; then
    echo "Starting from word: $START_FROM"
fi
echo "Rate limit delay: ${RATE_LIMIT_DELAY}s between job starts"
echo "Results will be saved to $OUTPUT_FILE"
echo ""

# Process words in parallel
job_count=0

start_reached=false
[[ -z "$START_FROM" ]] && start_reached=true

while IFS= read -r word || [ -n "$word" ]; do
    # Skip empty lines
    [[ -z "$word" ]] && continue
    
    # Remove any whitespace
    word=$(echo "$word" | tr -d '[:space:]')
    
    # Skip if word is empty after trimming
    [[ -z "$word" ]] && continue
    
    # Honor --start-from functionality
    if [[ "$start_reached" = false ]]; then
        if [[ "$word" == "$START_FROM" ]]; then
            start_reached=true
            echo "Reached start word: $START_FROM"
        else
            continue
        fi
    fi
    # Skip if already processed (resume support)
    if [[ -n "${processed_words["$word"]}" ]]; then
        continue
    fi
    
    # Run check in background
    (
        result=$(./tldhunt.sh -k "$word" -e .ai --quiet 2>&1)
        output="Checking: $word.ai
$result

"
        # Use flock for atomic file writing (if available) or append
        echo "$output" >> "$OUTPUT_FILE"
        echo "[$(date +%H:%M:%S)] $word.ai: $(echo "$result" | tr '\n' ' ')"
    ) &
    
    ((job_count++))
    
    # Rate limiting: add small delay between job starts to avoid overwhelming whois servers
    sleep "$RATE_LIMIT_DELAY"
    
    # Limit concurrent jobs
    while (( $(jobs -r -p | wc -l) >= MAX_JOBS )); do
        wait -n
        ((processed++))
        if (( processed % 100 == 0 )); then
            echo "[Progress] Processed $processed/$total_words words..."
        fi
    done
    
done < "$WORDLIST"

# Wait for all remaining jobs to complete
while (( $(jobs -r -p | wc -l) > 0 )); do
    wait -n
    ((processed++))
    if (( processed % 100 == 0 )); then
        echo "[Progress] Processed $processed/$total_words words..."
    fi
done

echo ""
echo "Done! Processed $total_words words. Results saved to $OUTPUT_FILE"
