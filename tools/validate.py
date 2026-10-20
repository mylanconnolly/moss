#!/usr/bin/env python3
"""Run the host tests or both OS ports, retaining each run's evidence."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import time
import tomllib

ROOT = Path(__file__).resolve().parents[1]
SMOKE = "panic,fault,domain,ipc,pan,smmu,comp,fs+rs"


def capture(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def run(command, log):
    started = time.monotonic()
    with log.open("w") as output:
        process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True,
                                   start_new_session=True)
        try:
            for line in process.stdout:
                output.write(line)
                output.flush()
                print(line, end="", flush=True)
            code = process.wait()
        finally:
            # A crashed runner can leave QEMUs alive on the next run's ports.
            # Only this command's newly-created process group is signalled.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            process.wait()
    return {"command": command, "exit_code": code,
            "seconds": round(time.monotonic() - started, 2)}


def save_evidence(destination, since):
    source = ROOT / "zig-out/check"
    if source.exists():
        for path in source.iterdir():
            if (path.is_file() and path.stat().st_mtime_ns >= since
                    and path.suffix in (".log", ".txt", ".ppm", ".pcap")):
                shutil.copy2(path, destination / path.name)


def preflight(mode):
    pinned = tomllib.loads((ROOT / "mise.toml").read_text())["tools"]["zig"]
    version = capture("zig", "version")
    if version != pinned:
        raise RuntimeError(f"Zig {pinned} required; found {version}")
    info = {"zig": version, "host": platform.platform(),
            "revision": capture("git", "rev-parse", "HEAD"),
            "working_tree": capture("git", "status", "--short")}
    if mode == "host":
        return info, []
    for executable in ("qemu-system-x86_64", "qemu-system-aarch64", "openssl"):
        info[executable] = capture(executable, "version" if executable == "openssl" else "--version").splitlines()[0]
    properties = capture("qemu-system-x86_64", "-device", "intel-iommu,help")
    if "x-scalable-mode=" not in properties or "x-flts=" not in properties:
        raise RuntimeError("QEMU lacks the VT-d properties this port supports; see ROADMAP")
    share = Path("/opt/homebrew/share" if sys.platform == "darwin" else "/usr/share")
    files = {
        "limine": Path(os.environ.get("MOSS_LIMINE", share / "limine")) / "BOOTX64.EFI",
        "ovmf": Path(os.environ.get("MOSS_OVMF", share / "qemu/edk2-x86_64-code.fd")),
        "ovmf-vars": Path(os.environ.get("MOSS_OVMF_VARS", share / "qemu/edk2-i386-vars.fd")),
    }
    for label, path in files.items():
        info[label] = {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    if mode == "full":
        if not os.access("/dev/kvm", os.R_OK | os.W_OK):
            raise RuntimeError("full validation requires accessible KVM; smoke uses TCG")
        nested = Path("/sys/module/kvm_amd/parameters/nested").read_text().strip()
        if nested.lower() not in ("1", "y"):
            raise RuntimeError("full validation requires nested AMD-V")
        # Require real acceleration instead of relying on QEMU's fallback.
        commands = '\n'.join(json.dumps(q) for q in (
            {"execute": "qmp_capabilities"}, {"execute": "query-kvm"}, {"execute": "quit"}))
        probe = subprocess.run(["qemu-system-x86_64", "-machine", "q35,accel=kvm",
                                "-cpu", "host", "-nodefaults", "-display", "none",
                                "-S", "-qmp", "stdio"], input=commands + '\n',
                               capture_output=True, text=True, timeout=15, check=True)
        replies = [json.loads(line).get("return", {}) for line in probe.stdout.splitlines()]
        if not any(reply.get("enabled") is True for reply in replies):
            raise RuntimeError("KVM probe did not confirm acceleration")
        info["kvm"] = {"enabled": True, "nested_amd_v": nested}
    options = [f"-Dlimine={files['limine'].parent}", f"-Dovmf={files['ovmf']}",
               f"-Dovmf-vars={files['ovmf-vars']}"]
    return info, options


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("host", "smoke", "full"))
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 8:
        parser.error("--jobs must be between 1 and 8")
    archive = ROOT / "zig-out/validation"
    archive.mkdir(parents=True, exist_ok=True)
    with (archive / ".lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("another validation is running; the gates share ports")
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        out = archive / f"{stamp}-{args.mode}"
        out.mkdir()
        print(f"Validation artifacts: {out}", flush=True)
        report = {"mode": args.mode, "runs": {}}
        try:
            info, firmware = preflight(args.mode)
            report.update(info)
            # Keep preflight evidence even if the machine/job dies mid-gate.
            (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")
            (out / "working-tree.patch").write_text(capture("git", "diff", "HEAD"))
            if args.mode == "host":
                phases = [("host-debug", []), ("host-release-safe", ["-Doptimize=ReleaseSafe"])]
            else:
                phases = [("amd64-kvm" if args.mode == "full" else "amd64-tcg", ["-Darch=x86_64", *firmware, *(["-Drequire-kvm"] if args.mode == "full" else [])]),
                          ("aarch64-tcg", [])]
            for label, options in phases:
                dest = out / label
                dest.mkdir()
                since = time.time_ns()
                command = ["zig", "build", "test" if args.mode == "host" else "check", *options]
                if args.mode != "host":
                    command += [f"-Djobs={args.jobs}"]
                if args.mode == "smoke":
                    command += [f"-Donly={SMOKE}"]
                    if label == "amd64-tcg":
                        command += ["-Dtcg"]
                result = run(command, dest / "build.log")
                report["runs"][label] = result
                if args.mode != "host":
                    save_evidence(dest, since)
                (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")
            return int(any(r["exit_code"] != 0 for r in report["runs"].values()))
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            report["error"] = str(error)
            print(f"Validation failed: {error}", file=sys.stderr)
            return 1
        finally:
            (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    sys.exit(main())
