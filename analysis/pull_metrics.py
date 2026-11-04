import csv
import logging
import statistics
from datetime import datetime
from pathlib import Path

import requests

logger = logging.getLogger("thesis")

PROMETHEUS_URL = "http://localhost:9090"
REPO_ROOT = Path(__file__).parent.parent
WINDOWS_CSV = REPO_ROOT / "bench" / "results" / "monitoring_windows.csv"
OUTPUT_CSV = REPO_ROOT / "bench" / "results" / "resource_usage.csv"

STEP_SECONDS = "5s"  # matches monitoring/prometheus.yml's scrape_interval

BACKEND_CONTAINERS = {
    "rustfs": ["rustfs"],
    "garage": ["garage"],
    "seaweedfs": ["seaweedfs-master", "seaweedfs-volume", "seaweedfs-filer", "seaweedfs-s3"],
    "juicefs": ["juicefs-redis", "juicefs-gateway"],
    "ceph": ["ceph-mon", "ceph-mgr", "ceph-osd", "ceph-rgw"],
    "minio": ["minio"],
}

def query_range(query: str, start: str, end: str) -> list:
    response = requests.get(
        f"{PROMETHEUS_URL}/api/v1/query_range",
        params={"query": query, "start": start, "end": end, "step": STEP_SECONDS},
    )
    response.raise_for_status()
    data = response.json()
    if data["status"] != "success":
        raise RuntimeError(f"Prometheus query failed: {data}")
    return data["data"]["result"]

def memory_values(container_name: str, start: str, end: str) -> list:
    query = f'container_memory_usage_bytes{{name="{container_name}"}}'
    result = query_range(query, start, end)
    if not result:
        return []
    return [float(value) for _, value in result[0]["values"]]

def swap_values(container_name: str, start: str, end: str) -> list:
    query = f'container_memory_swap{{name="{container_name}"}}'
    result = query_range(query, start, end)
    if not result:
        return []
    return [float(value) for _, value in result[0]["values"]]

def cpu_seconds(container_name: str, start: str, end: str) -> float:
    window = int((parse_time(end) - parse_time(start)).total_seconds())
    query = (
        f'increase(container_cpu_usage_seconds_total{{name="{container_name}"}}[{window}s])'
    )
    result = query_range(query, end, end)
    if not result or not result[0]["values"]:
        return 0.0
    return float(result[0]["values"][-1][1])

def parse_time(timestamp: str):
    return datetime.fromisoformat(timestamp.replace("Z", "+00:00"))

def cpu_values(container_name: str, start: str, end: str) -> list:
    query = f'rate(container_cpu_usage_seconds_total{{name="{container_name}"}}[15s])'
    result = query_range(query, start, end)
    if not result:
        return []
    return [float(value) for _, value in result[0]["values"]]

def sum_series(series_list: list) -> list:
    series_list = [s for s in series_list if s]
    if not series_list:
        return []
    shortest = min(len(s) for s in series_list)
    return [sum(s[i] for s in series_list) for i in range(shortest)]

def summarize_backend(backend: str, start: str, end: str) -> dict:
    logger.info(f"Querying Prometheus for {backend}, window {start} to {end}")
    containers = BACKEND_CONTAINERS[backend]

    memory_series = sum_series([memory_values(c, start, end) for c in containers])
    cpu_series = sum_series([cpu_values(c, start, end) for c in containers])
    total_cpu_seconds = sum(cpu_seconds(c, start, end) for c in containers)
    swap_series = sum_series([swap_values(c, start, end) for c in containers])
    window_seconds = int((parse_time(end) - parse_time(start)).total_seconds())

    if not memory_series or not cpu_series:
        logger.warning(f"  no data returned for {backend} -- was cAdvisor scraping it during this window?")
        return {
            "backend": backend,
            "mean_memory_MB": "",
            "peak_memory_MB": "",
            "mean_cpu_cores": "",
            "peak_cpu_cores": "",
            "cpu_seconds": "",
            "peak_swap_MB": "",
            "window_seconds": window_seconds,
            "memory_samples": 0,
            "cpu_samples": 0,
        }

    return {
        "backend": backend,
        "mean_memory_MB": round(statistics.mean(memory_series) / 1_000_000, 2),
        "peak_memory_MB": round(max(memory_series) / 1_000_000, 2),
        "mean_cpu_cores": round(statistics.mean(cpu_series), 4),
        "peak_cpu_cores": round(max(cpu_series), 4),
        "cpu_seconds": round(total_cpu_seconds, 2),
        "peak_swap_MB": round(max(swap_series) / 1_000_000, 2) if swap_series else 0.0,
        "window_seconds": window_seconds,
        "memory_samples": len(memory_series),
        "cpu_samples": len(cpu_series),
    }

def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )

    with open(WINDOWS_CSV) as f:
        windows = list(csv.DictReader(f))

    rows = [summarize_backend(w["backend"], w["start_time"], w["end_time"]) for w in windows]

    OUTPUT_CSV.parent.mkdir(exist_ok=True)
    with open(OUTPUT_CSV, "w", newline="") as f:
        fieldnames = [
            "backend",
            "mean_memory_MB",
            "peak_memory_MB",
            "mean_cpu_cores",
            "peak_cpu_cores",
            "cpu_seconds",
            "peak_swap_MB",
            "window_seconds",
            "memory_samples",
            "cpu_samples",
        ]
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    logger.info(f"Saved resource usage summary to {OUTPUT_CSV}")

if __name__ == "__main__":
    main()
