#!/bin/bash

# GPU Monitor Script for ML Cluster
# Monitors VRAM usage, GPU utilization, and processes in real-time

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display header
show_header() {
    clear
    echo -e "${BLUE}=== ML Cluster GPU Monitor ===${NC}"
    echo -e "${YELLOW}$(date)${NC}"
    echo ""
}

# Function to show basic GPU stats
show_basic_stats() {
    echo -e "${GREEN}=== GPU Overview ===${NC}"
    nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw --format=csv,noheader,nounits | \
    awk -F',' '{printf "GPU: %-20s | VRAM: %5s/%5s MB (%3.0f%%) | Util: %3s%% | Temp: %2s°C | Power: %3sW\n", 
        $1, $2, $3, ($2/$3)*100, $4, $5, $6}'
    echo ""
}

# Function to show running processes
show_processes() {
    echo -e "${GREEN}=== GPU Processes ===${NC}"
    nvidia-smi --query-compute-apps=pid,process_name,gpu_uuid,used_memory --format=csv,noheader,nounits | \
    while IFS=',' read -r pid name gpu_uuid mem; do
        if [ ! -z "$pid" ]; then
            gpu_id=$(nvidia-smi --query-gpu=uuid,index --format=csv,noheader | grep "$gpu_uuid" | cut -d',' -f2)
            echo "GPU $gpu_id: PID $pid - $name (${mem}MB)"
        fi
    done
    
    if [ $(nvidia-smi --query-compute-apps=pid --format=csv,noheader | wc -l) -eq 0 ]; then
        echo "No GPU processes running"
    fi
    echo ""
}

# Function to show Docker containers
show_docker_status() {
    echo -e "${GREEN}=== Docker Containers ===${NC}"
    if command -v docker &> /dev/null; then
        docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | grep -E "(ollama|nvidia|gpu)" || echo "No GPU-related containers found"
    else
        echo "Docker not available"
    fi
    echo ""
}

# Main monitoring loop
main() {
    local interval=${1:-2}  # Default 2 seconds
    
    echo "Starting GPU monitoring (Ctrl+C to stop, interval: ${interval}s)"
    echo "Usage: $0 [interval_seconds]"
    sleep 2
    
    while true; do
        show_header
        show_basic_stats
        show_processes
        show_docker_status
        
        echo -e "${YELLOW}Press Ctrl+C to stop monitoring${NC}"
        sleep $interval
    done
}

# Handle command line arguments
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "GPU Monitor Script"
    echo "Usage: $0 [interval_seconds]"
    echo "  interval_seconds: Refresh interval (default: 2)"
    echo ""
    echo "Examples:"
    echo "  $0        # Monitor with 2 second intervals"
    echo "  $0 1      # Monitor with 1 second intervals"
    echo "  $0 5      # Monitor with 5 second intervals"
    exit 0
fi

# Trap Ctrl+C
trap 'echo -e "\n${RED}Monitoring stopped${NC}"; exit 0' INT

# Check if nvidia-smi is available
if ! command -v nvidia-smi &> /dev/null; then
    echo -e "${RED}Error: nvidia-smi not found. Please install NVIDIA drivers.${NC}"
    exit 1
fi

main "$@"