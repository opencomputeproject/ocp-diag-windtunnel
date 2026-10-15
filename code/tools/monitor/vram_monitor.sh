#!/bin/bash

# Simple VRAM Usage Monitor
# Lightweight script to monitor VRAM usage in real-time

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function to get VRAM usage percentage
get_vram_usage() {
    nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits | \
    awk -F',' '{printf "%.1f", ($1/$2)*100}'
}

# Function to display VRAM bar
show_vram_bar() {
    local gpu_id=$1
    local used=$2
    local total=$3
    local percent=$4
    
    # Create progress bar (50 characters wide)
    local bar_length=50
    local filled=$(echo "$percent" | awk '{printf "%.0f", $1/100*50}')
    local empty=$((bar_length - filled))
    
    # Choose color based on usage
    local color=$GREEN
    if (( $(echo "$percent > 80" | bc -l) )); then
        color=$RED
    elif (( $(echo "$percent > 60" | bc -l) )); then
        color=$YELLOW
    fi
    
    printf "GPU %d [" $gpu_id
    printf "%s" "$(printf "%*s" $filled | tr ' ' '█')"
    printf "%s" "$(printf "%*s" $empty | tr ' ' '░')"
    printf "] %s%5.1f%%%s (%s/%s MB)\n" "$color" "$percent" "$NC" "$used" "$total"
}

# Main function
main() {
    local interval=${1:-1}
    
    echo "VRAM Usage Monitor (Ctrl+C to stop, interval: ${interval}s)"
    echo ""
    
    while true; do
        clear
        echo -e "${BLUE}=== VRAM Usage Monitor ===${NC}"
        echo -e "${YELLOW}$(date)${NC}"
        echo ""
        
        # Get GPU count
        local gpu_count=$(nvidia-smi --list-gpus | wc -l)
        
        # Monitor each GPU
        for ((i=0; i<gpu_count; i++)); do
            local gpu_info=$(nvidia-smi -i $i --query-gpu=name,memory.used,memory.total --format=csv,noheader,nounits)
            local name=$(echo "$gpu_info" | cut -d',' -f1 | xargs)
            local used=$(echo "$gpu_info" | cut -d',' -f2 | xargs)
            local total=$(echo "$gpu_info" | cut -d',' -f3 | xargs)
            local percent=$(echo "scale=1; $used*100/$total" | bc)
            
            echo -e "${GREEN}$name${NC}"
            show_vram_bar $i $used $total $percent
            echo ""
        done
        
        # Show processes if any
        local process_count=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader | wc -l)
        if [ $process_count -gt 0 ]; then
            echo -e "${GREEN}=== Active GPU Processes ===${NC}"
            nvidia-smi --query-compute-apps=gpu_name,pid,process_name,used_memory --format=csv,noheader | \
            while IFS=',' read -r gpu_name pid process_name mem; do
                echo "  PID $pid: $process_name (${mem}MB) on $gpu_name"
            done
            echo ""
        fi
        
        echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
        sleep $interval
    done
}

# Handle arguments
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "VRAM Usage Monitor"
    echo "Usage: $0 [interval_seconds]"
    echo "  interval_seconds: Refresh interval (default: 1)"
    exit 0
fi

# Check dependencies
if ! command -v nvidia-smi &> /dev/null; then
    echo -e "${RED}Error: nvidia-smi not found${NC}"
    exit 1
fi

if ! command -v bc &> /dev/null; then
    echo -e "${RED}Error: bc calculator not found. Install with: sudo apt install bc${NC}"
    exit 1
fi

# Trap Ctrl+C
trap 'echo -e "\n${RED}VRAM monitoring stopped${NC}"; exit 0' INT

main "$@"