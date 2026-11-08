#!/usr/bin/env python3
"""Read-only live VPN probe. Never changes VPNs, PAC settings, or user app sessions."""
import argparse
import concurrent.futures
import ipaddress
import json
import socket
import subprocess
import tempfile
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("binary")
parser.add_argument("--interface", default="en0")
parser.add_argument("--label", default="current VPN state")
args = parser.parse_args()

def request(url, mode, port):
    command = ["/usr/bin/curl", "--silent", "--show-error", "--connect-timeout", "6", "--max-time", "12"]
    if mode == "proxy":
        command += ["--noproxy", "", "--proxy", "http://127.0.0.1:" + str(port)]
    else:
        command += ["--noproxy", "*"]
        if mode == "physical":
            command += ["--interface", args.interface]
    check_ip = "ipify.org" in url
    if not check_ip:
        command += ["--head", "--output", "/dev/null", "--write-out", "%{http_code}"]
    run = subprocess.run(command + [url], capture_output=True, text=True)
    value = run.stdout.strip()
    if check_ip and run.returncode == 0:
        try:
            value = str(ipaddress.ip_address(value))
        except ValueError:
            value = "invalid-ip-response"
    return {"ok": run.returncode == 0, "value": value, "error": run.stderr.strip()}

with tempfile.TemporaryDirectory(prefix="pointswoman-probe-") as temp:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    command = [str(Path(args.binary).resolve()), "serve", "--interface", args.interface, "--port", str(port), "--config", str(Path(temp) / "config.json")]
    for domain in ["api.ipify.org", "chat.example.com", "app.example.com"]:
        command += ["--domain", domain]
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        for _ in range(50):
            if process.poll() is not None:
                raise RuntimeError(process.communicate()[1])
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.1)
        tasks = [(url, mode) for url in ["https://api.ipify.org", "https://chat.example.com", "https://app.example.com"] for mode in ["normal", "physical", "proxy"]]
        with concurrent.futures.ThreadPoolExecutor(max_workers=9) as pool:
            runs = list(pool.map(lambda pair: request(*pair, port), tasks))
        results = dict(zip(tasks, runs))
        report = {"label": args.label, "interface": args.interface, "settings_changed": False, "results": []}
        for (url, mode), value in results.items():
            item = {"url": url, "mode": mode, "ok": value["ok"]}
            if "ipify.org" not in url:
                item["http_status"] = value["value"]
            elif value["ok"]:
                item["valid_ip"] = value["value"] != "invalid-ip-response"
            if not value["ok"]:
                # Avoid recording addresses, tokens, or private response data.
                item["error"] = "Request failed or timed out (curl)."
            report["results"].append(item)
        normal, physical, proxy = [results[("https://api.ipify.org", mode)] for mode in ["normal", "physical", "proxy"]]
        valid = all(value["ok"] and value["value"] != "invalid-ip-response" for value in [normal, physical, proxy])
        report["egress_comparison_available"] = valid
        if valid:
            report["proxy_matches_physical"] = proxy["value"] == physical["value"]
            report["proxy_differs_from_normal"] = proxy["value"] != normal["value"]
            report["address_families_match"] = len({ipaddress.ip_address(value["value"]).version for value in [normal, physical, proxy]}) == 1
        print(json.dumps(report, indent=2))
    finally:
        process.terminate()
        process.communicate(timeout=5)
