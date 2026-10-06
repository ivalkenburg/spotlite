#!/usr/bin/env python3
"""Run fresh GUI processes sequentially; no changes to saved preferences or hotkeys."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]


def command(*args):
    return subprocess.run(args, capture_output=True, text=True)


def server_sample(pid):
    result = command("ps", "-p", str(pid), "-o", "rss=,time=")
    fields = result.stdout.split()
    if len(fields) != 2:
        return {}
    parts = fields[1].split(":")
    seconds = sum(float(part) * 60 ** i for i, part in enumerate(reversed(parts)))
    return {"rss_bytes": int(fields[0]) * 1024, "cpu_s": seconds}


def median(values):
    return statistics.median(values) if values else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--materials", nargs="+", choices=["glass", "hud", "popover", "solid"], default=["glass", "hud", "popover"])
    parser.add_argument("--themes", nargs="+", choices=["dark", "light"], default=["dark", "light"])
    parser.add_argument("--output", type=Path, default=ROOT / "build/material-benchmark")
    parser.add_argument("--capture", action="store_true", help="Capture panels in a separate run; avoid mixing capture overhead into timing comparisons")
    parser.add_argument("--vmmap", action="store_true", help="Save expanded-settled VM summaries; use separately from timing comparisons")
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("--repetitions must be positive")
    binary = ROOT / "build/Spotlite.app/Contents/MacOS/Spotlite"
    if not binary.exists():
        parser.error("Build first with make")
    args.output.mkdir(parents=True, exist_ok=True)
    server_pid = None
    for line in command("ps", "-axo", "pid=,comm=").stdout.splitlines():
        if line.strip().endswith("/WindowServer"):
            server_pid = int(line.split()[0])
            break
    server_footprint = command("footprint", "--noCategories", "-f", "bytes", str(server_pid)) if server_pid else None
    metadata = {
        "os": command("sw_vers").stdout.strip(),
        "hardware": command("sysctl", "-n", "hw.model", "machdep.cpu.brand_string", "hw.memsize").stdout.strip(),
        "git_revision": command("git", "-C", str(ROOT), "rev-parse", "HEAD").stdout.strip(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "captures": args.capture, "vmmap": args.vmmap,
        "windowserver_pid": server_pid,
        "windowserver_footprint": ((server_footprint.stdout + server_footprint.stderr).strip() if server_footprint else "unavailable"),
        "windowserver_metric": "RSS, shared desktop; excludes compressed and some GPU memory",
    }
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    samples = []
    for repetition in range(args.repetitions):
        # Rotate order to reduce warm-cache/order bias. Never compare concurrent panels.
        offset = repetition % len(args.materials)
        materials = args.materials[offset:] + args.materials[:offset]
        for theme in args.themes:
            for material in materials:
                name = f"{theme}-{material}-{repetition + 1}"
                env = os.environ.copy()
                for key in list(env):
                    if key.startswith("SPOTLITE_DEV_") or key == "SPOTLITE_SHOW_ON_LAUNCH":
                        del env[key]
                env.update(SPOTLITE_DEV_MATERIAL_BENCH="1", SPOTLITE_DEV_MATERIAL=material, SPOTLITE_DEV_THEME=theme)
                before = server_sample(server_pid) if server_pid else {}
                print(f"Running {name}", flush=True)
                process = subprocess.Popen([str(binary)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                phases = []
                try:
                    with (args.output / f"{name}.log").open("w") as log:
                        for line in process.stdout:
                            log.write(line)
                            log.flush()
                            if not line.startswith("MATERIAL_BENCH "):
                                continue
                            data = json.loads(line.removeprefix("MATERIAL_BENCH "))
                            data["repetition"] = repetition + 1
                            if server_pid:
                                server = server_sample(server_pid)
                                data["windowserver"] = server
                                if "rss_bytes" in server and "rss_bytes" in before:
                                    data["windowserver_rss_delta_bytes"] = server["rss_bytes"] - before["rss_bytes"]
                            phases.append(data["phase"])
                            samples.append(data)
                            if args.capture and data["phase"] in ["collapsed", "expanded-settled", "card"]:
                                rect = ",".join(str(round(value)) for value in data["capture_rect"])
                                capture = command("screencapture", "-x", "-R", rect, str(args.output / f"{name}-{data['phase']}.png"))
                                if capture.returncode:
                                    print(f"Capture failed: {capture.stderr.strip()}", flush=True)
                            if args.vmmap and data["phase"] == "expanded-settled":
                                vm = command("vmmap", "-summary", str(data["pid"]))
                                (args.output / f"{name}-vmmap.txt").write_text(vm.stdout + vm.stderr)
                    status = process.wait(timeout=10)
                    if status != 0 or "final-hidden" not in phases:
                        raise RuntimeError(f"{name} failed ({status}); see its log")
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=10)
                    (args.output / "samples.json").write_text(json.dumps(samples, indent=2) + "\n")
                settled = next(sample for sample in reversed(samples) if sample["phase"] == "visible-idle")
                print(f"  settled: {settled['footprint_bytes'] / 2**20:.1f} MiB footprint, {settled['resident_bytes'] / 2**20:.1f} MiB RSS", flush=True)
                time.sleep(1)
    summary = []
    for theme in args.themes:
        for material in args.materials:
            for phase in sorted({sample["phase"] for sample in samples}):
                group = [sample for sample in samples if (sample["theme"], sample["material"], sample["phase"]) == (theme, material, phase)]
                row = {"theme": theme, "material": material, "phase": phase, "runs": len(group)}
                keys = {key for sample in group for key, value in sample.items() if isinstance(value, (int, float))}
                for key in keys - {"pid", "repetition", "uptime_s"}:
                    row[key] = median([sample[key] for sample in group if key in sample])
                summary.append(row)
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Results: {args.output}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit(130)
