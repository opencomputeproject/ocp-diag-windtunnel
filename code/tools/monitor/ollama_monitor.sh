#!/bin/bash

# Ollama Monitor Script
# Monitors Ollama container and GPU usage specifically

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

CONTAINER_NAME="h100-ollama"

# Function to check Ollama status
check_ollama_status() {
    echo -e "${BLUE}=== Ollama Status ===${NC}"
    
    # Check container status
    if docker ps | grep -q "$CONTAINER_NAME"; then
        echo -e "${GREEN}✓ Ollama container is running${NC}"
        
        # Get container stats
        local container_stats=$(docker stats $CONTAINER_NAME --no-stream --format "table {{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}")
        echo "Container Stats:"
        echo "$container_stats" | tail -n +2 | while read cpu mem net; do
            echo "  CPU: $cpu, Memory: $mem, Network: $net"
        done
    else
        echo -e "${RED}✗ Ollama container is not running${NC}"
        echo "Available containers:"
        docker ps -a | grep ollama || echo "  No ollama containers found"
    fi
    echo ""
}

# Function to check Ollama API
check_ollama_api() {
    echo -e "${BLUE}=== Ollama API Status ===${NC}"
    
    # Test API endpoint
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:11434/api/tags | grep -q "200"; then
        echo -e "${GREEN}✓ Ollama API is responding${NC}"
        
        # Get loaded models
        echo "Loaded models:"
        curl -s http://localhost:11434/api/tags | jq -r '.models[]?.name // "No models loaded"' 2>/dev/null || echo "  Unable to parse model list"
    else
        echo -e "${RED}✗ Ollama API is not responding${NC}"
    fi
    echo ""
}

# Function to monitor GPU usage for Ollama
monitor_ollama_gpu() {
    echo -e "${BLUE}=== GPU Usage (Ollama Related) ===${NC}"
    
    # Check for GPU processes
    local ollama_processes=$(nvidia-smi --query-compute-apps=pid,process_name,gpu_name,used_memory --format=csv,noheader | grep -i ollama || true)
    
    if [ ! -z "$ollama_processes" ]; then
        echo "Ollama GPU processes:"
        echo "$ollama_processes" | while IFS=',' read -r pid name gpu mem; do
            echo "  PID $pid on $gpu: ${mem}MB VRAM"
        done
    else
        echo "No Ollama processes using GPU"
    fi
    
    # Show GPU summary
    echo ""
    echo "GPU VRAM Usage:"
    nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader | \
    while IFS=',' read -r name used total util; do
        local percent=$(echo "scale=1; $used*100/$total" | bc)
        printf "  %-20s: %5s/%5s MB (%5.1f%%) - %s%% util\n" "$name" "$used" "$total" "$percent" "$util"
    done
    echo ""
}

# Function to show Ollama logs
show_ollama_logs() {
    echo -e "${BLUE}=== Recent Ollama Logs ===${NC}"
    
    if docker ps | grep -q "$CONTAINER_NAME"; then
        echo "Last 10 log entries:"
        docker logs --tail 10 $CONTAINER_NAME 2>/dev/null | sed 's/^/  /' || echo "  Unable to fetch logs"
    else
        echo "Container not running - no logs available"
    fi
    echo ""
}

# Function to show performance metrics
show_performance_metrics() {
    echo -e "${BLUE}=== Performance Metrics ===${NC}"
    
    # Temperature check
    echo "GPU Temperatures:"
    nvidia-smi --query-gpu=name,temperature.gpu --format=csv,noheader | \
    while IFS=',' read -r name temp; do
        printf "  %-20s: %s°C\n" "$name" "$temp"
    done
    
    echo ""
    
    # Power consumption
    echo "GPU Power Usage:"
    nvidia-smi --query-gpu=name,power.draw,power.limit --format=csv,noheader | \
    while IFS=',' read -r name power limit; do
        printf "  %-20s: %sW / %sW\n" "$name" "$power" "$limit"
    done
    echo ""
}

# Real-time monitoring function
realtime_monitor() {
    local interval=${1:-2}
    
    echo "Starting real-time Ollama monitoring (Ctrl+C to stop)"
    echo "Refresh interval: ${interval}s"
    sleep 2
    
    while true; do
        clear
        echo -e "${YELLOW}=== Ollama Real-time Monitor - $(date) ===${NC}"
        echo ""
        
        check_ollama_status
        check_ollama_api
        monitor_ollama_gpu
        show_performance_metrics
        
        echo -e "${YELLOW}Press Ctrl+C to stop monitoring${NC}"
        sleep $interval
    done
}

# Function to restart Ollama
restart_ollama() {
    echo -e "${YELLOW}Restarting Ollama container...${NC}"
    docker restart $CONTAINER_NAME
    echo -e "${GREEN}Ollama container restarted${NC}"
    
    # Wait for API to be ready
    echo "Waiting for API to be ready..."
    for i in {1..30}; do
        if curl -s -o /dev/null http://localhost:11434/api/tags; then
            echo -e "${GREEN}API is ready${NC}"
            break
        fi
        sleep 1
    done
}

# Main function
main() {
    case "${1:-status}" in
        "status"|"")
            check_ollama_status
            check_ollama_api
            monitor_ollama_gpu
            show_performance_metrics
            ;;
        "monitor"|"watch")
            realtime_monitor ${2:-2}
            ;;
        "logs")
            show_ollama_logs
            ;;
        "restart")
            restart_ollama
            ;;
        "help"|"-h"|"--help")
            echo "Ollama Monitor Script"
            echo "Usage: $0 [command] [options]"
            echo ""
            echo "Commands:"
            echo "  status          Show current status (default)"
            echo "  monitor [sec]   Real-time monitoring (default: 2s interval)"
            echo "  logs           Show recent container logs"
            echo "  restart        Restart Ollama container"
            echo "  help           Show this help"
            echo ""
            echo "Examples:"
            echo "  $0              # Show status"
            echo "  $0 monitor      # Real-time monitoring"
            echo "  $0 monitor 1    # Monitor with 1s intervals"
            echo "  $0 logs         # Show logs"
            ;;
        *)
            echo "Unknown command: $1"
            echo "Use '$0 help' for usage information"
            exit 1
            ;;
    esac
}

# Check dependencies
for cmd in docker nvidia-smi curl bc; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd not found"
        exit 1
    fi
done

# Trap Ctrl+C for real-time monitoring
trap 'echo -e "\n${RED}Monitoring stopped${NC}"; exit 0' INT

main "$@"