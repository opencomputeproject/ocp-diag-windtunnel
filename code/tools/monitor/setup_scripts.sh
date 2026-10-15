#!/bin/bash

# Make all monitoring scripts executable
chmod +x *.sh

echo "Making scripts executable..."
echo "✓ gpu_monitor.sh"
echo "✓ vram_monitor.sh" 
echo "✓ cluster_stats.sh"
echo "✓ ollama_monitor.sh"
echo ""
echo "Scripts are ready to use!"
echo ""
echo "Quick start:"
echo "  ./cluster_stats.sh      # Overall cluster overview"
echo "  ./vram_monitor.sh       # Real-time VRAM monitoring with progress bars"
echo "  ./gpu_monitor.sh        # Comprehensive GPU monitoring"
echo "  ./ollama_monitor.sh     # Ollama-specific monitoring"
echo ""
echo "For help on any script, use: ./script_name.sh --help"