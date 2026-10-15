#!/bin/bash

# ML Cluster Stats Script
# Comprehensive overview of ML cluster hardware and status

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Function to show cluster overview
show_cluster_overview() {
    echo -e "${BLUE}=== ML Cluster Overview ===${NC}"
    echo -e "${YELLOW}Hostname: $(hostname)${NC}"
    echo -e "${YELLOW}Date: $(date)${NC}"
    echo ""
}

# Function to show GPU summary
show_gpu_summary() {
    echo -e "${GREEN}=== GPU Summary ===${NC}"
    
    # Get GPU count and types
    local gpu_count=$(nvidia-smi --list-gpus | wc -l)
    local gpu_models=$(nvidia-smi --query-gpu=name --format=csv,noheader | sort | uniq -c | awk '{print $1"x "$2}')
    
    echo "Total GPUs: $gpu_count"
    echo "GPU Models:"
    echo "$gpu_models" | sed 's/^/  /'
    
    # Total VRAM
    local total_vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{sum+=$1} END {printf "%.0f", sum/1024}')
    local used_vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | awk '{sum+=$1} END {printf "%.0f", sum/1024}')
    
    echo "Total VRAM: ${total_vram}GB"
    echo "Used VRAM: ${used_vram}GB"
    echo "Free VRAM: $((total_vram - used_vram))GB"
    echo ""
}

# Function to show detailed GPU stats
show_detailed_gpu_stats() {
    echo -e "${GREEN}=== Detailed GPU Stats ===${NC}"
    printf "%-3s %-20s %-12s %-12s %-8s %-6s %-8s\n" "ID" "Model" "VRAM Used" "VRAM Total" "Util%" "Temp°C" "Power W"
    echo "$(printf '%*s' 75 | tr ' ' '-')"
    
    nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw --format=csv,noheader,nounits | \
    while IFS=',' read -r index name mem_used mem_total util temp power; do
        # Truncate long GPU names
        short_name=$(echo "$name" | cut -c1-18)
        printf "%-3s %-20s %-12s %-12s %-8s %-6s %-8s\n" \
            "$index" "$short_name" "${mem_used}MB" "${mem_total}MB" "${util}%" "${temp}" "${power}W"
    done
    echo ""
}

# Function to show system resources
show_system_resources() {
    echo -e "${GREEN}=== System Resources ===${NC}"
    
    # CPU info
    local cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
    local cpu_cores=$(nproc)
    echo "CPU: $cpu_model ($cpu_cores cores)"
    
    # Memory info
    local mem_info=$(free -h | grep "Mem:")
    local total_mem=$(echo $mem_info | awk '{print $2}')
    local used_mem=$(echo $mem_info | awk '{print $3}')
    local avail_mem=$(echo $mem_info | awk '{print $7}')
    echo "Memory: $used_mem/$total_mem used, $avail_mem available"
    
    # Disk usage
    local disk_usage=$(df -h / | tail -1)
    local disk_used=$(echo $disk_usage | awk '{print $3}')
    local disk_total=$(echo $disk_usage | awk '{print $2}')
    local disk_avail=$(echo $disk_usage | awk '{print $4}')
    echo "Disk (/): $disk_used/$disk_total used, $disk_avail available"
    
    # Load average
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    echo "Load Average: $load_avg"
    echo ""
}

# Function to show running ML workloads
show_ml_workloads() {
    echo -e "${GREEN}=== ML Workloads ===${NC}"
    
    # GPU processes
    local gpu_processes=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader)
    if [ ! -z "$gpu_processes" ]; then
        echo "GPU Processes:"
        echo "$gpu_processes" | while IFS=',' read -r pid name mem; do
            echo "  PID $pid: $name (${mem}MB VRAM)"
        done
    else
        echo "No GPU processes running"
    fi
    
    # Docker containers
    if command -v docker &> /dev/null; then
        echo ""
        echo "ML Containers:"
        local ml_containers=$(docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep -E "(ollama|pytorch|tensorflow|nvidia|ml-|ai-)" || true)
        if [ ! -z "$ml_containers" ]; then
            echo "$ml_containers"
        else
            echo "No ML containers running"
        fi
    fi
    echo ""
}

# Function to show network info
show_network_info() {
    echo -e "${GREEN}=== Network Info ===${NC}"
    
    # Get primary network interface
    local primary_iface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ ! -z "$primary_iface" ]; then
        local ip_addr=$(ip addr show $primary_iface | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
        echo "Primary Interface: $primary_iface ($ip_addr)"
    fi
    
    # Check for InfiniBand
    if command -v ibstat &> /dev/null; then
        local ib_devices=$(ibstat -l 2>/dev/null | wc -l)
        if [ $ib_devices -gt 0 ]; then
            echo "InfiniBand Devices: $ib_devices"
        fi
    fi
    echo ""
}

# Function to show driver versions
show_driver_info() {
    echo -e "${GREEN}=== Driver Information ===${NC}"
    
    # NVIDIA driver
    local nvidia_version=$(nvidia-smi | grep "Driver Version" | awk '{print $3}')
    local cuda_version=$(nvidia-smi | grep "CUDA Version" | awk '{print $9}')
    echo "NVIDIA Driver: $nvidia_version"
    echo "CUDA Version: $cuda_version"
    
    # Docker version
    if command -v docker &> /dev/null; then
        local docker_version=$(docker --version | awk '{print $3}' | tr -d ',')
        echo "Docker Version: $docker_version"
    fi
    echo ""
}

# Main function
main() {
    clear
    show_cluster_overview
    show_gpu_summary
    show_detailed_gpu_stats
    show_system_resources
    show_ml_workloads
    show_network_info
    show_driver_info
    
    echo -e "${CYAN}=== Quick Commands ===${NC}"
    echo "  nvidia-smi -l 1    # Real-time GPU monitoring"
    echo "  ./vram_monitor.sh  # VRAM usage with progress bars"
    echo "  ./gpu_monitor.sh   # Comprehensive GPU monitoring"
    echo "  htop              # System resource monitoring"
}

# Handle help
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "ML Cluster Stats Script"
    echo "Usage: $0"
    echo ""
    echo "Displays comprehensive overview of ML cluster hardware and status"
    exit 0
fi

# Check if nvidia-smi is available
if ! command -v nvidia-smi &> /dev/null; then
    echo "Error: nvidia-smi not found. Please install NVIDIA drivers."
    exit 1
fi

main "$@"