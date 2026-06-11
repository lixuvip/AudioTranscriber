import subprocess
import re
import shutil
import psutil
from pathlib import Path

def get_gpu_usage() -> float:
    try:
        # Run ioreg tool to fetch Apple Silicon GPU usage metrics
        res = subprocess.run(
            ["ioreg", "-n", "IOAccelerator", "-r", "-a"],
            capture_output=True,
            text=True,
            timeout=2.0
        )
        # Match "Device Utilization %" or "Device Utilization"
        matches = re.findall(r'"Device Utilization %"=(\d+)', res.stdout)
        if not matches:
            matches = re.findall(r'"Device Utilization"=(\d+)', res.stdout)
        if not matches:
            matches = re.findall(r'"GPU Core Utilization"=(\d+)', res.stdout)
        
        if matches:
            return max(float(m) / 100.0 for m in matches)
    except Exception:
        pass
    return 0.0

def get_system_stats(data_root: Path) -> dict:
    # CPU percentage usage (non-blocking call, returns instantly)
    cpu = psutil.cpu_percent(interval=None) / 100.0
    
    # Physical memory usage percentage
    mem_stats = psutil.virtual_memory()
    memory = mem_stats.percent / 100.0
    
    # GPU usage percentage
    gpu = get_gpu_usage()
    
    # Storage disk usage percentage
    try:
        usage = shutil.disk_usage(data_root)
        disk = (usage.used / usage.total)
    except Exception:
        disk = 0.0
        
    return {
        "cpu_usage": cpu,
        "memory_usage": memory,
        "gpu_usage": gpu,
        "disk_usage": disk
    }
