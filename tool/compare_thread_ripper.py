#!/usr/bin/env python3
"""Compare pinned public VOD proxies against the working tree on local HTTP."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent
BASELINE = "5e4971a3676493f1e222f8015db76c8747178e96"
REFERENCE = "014cdd38318a41c78aa61254d6adab96d831fcd4"


def source(commit, path):
    return subprocess.check_output(
        ["git", "show", f"{commit}:{path}"], cwd=ROOT, text=True
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(tempfile.gettempdir()) / "piliplus-thread-ripper-comparison.json",
    )
    args = parser.parse_args()
    for commit in (BASELINE, REFERENCE):
        exists = subprocess.run(
            ["git", "cat-file", "-e", f"{commit}^{{commit}}"],
            cwd=ROOT,
            capture_output=True,
        )
        if exists.returncode:
            remote = "origin" if commit == BASELINE else "https://github.com/lemonteaau/PiliPlus.git"
            parser.error(
                f"Missing {commit}. Fetch it first: "
                f"git fetch --no-tags {remote} {commit}"
            )
    output = args.output.resolve()
    with tempfile.TemporaryDirectory(prefix="piliplus-ripper-comparison-") as temp:
        directory = Path(temp)
        before = directory / "ours-before"
        reference = directory / "lemonteaau"
        before.mkdir()
        reference.mkdir()
        for name in ("proxy.dart", "live.dart"):
            text = source(BASELINE, f"lib/services/thread_ripper/{name}")
            text = text.replace(
                "import 'package:PiliPlus/models/common/video/thread_ripper.dart';",
                "import 'models.dart';",
            )
            (before / name).write_text(text)
        (before / "models.dart").write_text(
            source(BASELINE, "lib/models/common/video/thread_ripper.dart")
        )
        # Export only transport code; no signing or account files are copied.
        for name in ("range_proxy.dart", "cdn_resolver.dart", "auto_concurrency.dart"):
            text = source(REFERENCE, f"lib/services/thread_ripper/{name}")
            for dependency in ("auto_concurrency.dart", "cdn_resolver.dart"):
                text = text.replace(
                    f"import 'package:PiliPlus/services/thread_ripper/{dependency}';",
                    f"import '{dependency}';",
                )
            (reference / name).write_text(text)
        test = directory / "compare_test.dart"
        test.write_text(
            (ROOT / "tool/thread_ripper_comparison.dart.template").read_text()
        )
        env = os.environ.copy()
        env["RIPPER_BENCHMARK_OUTPUT"] = str(output)
        subprocess.run(
            ["flutter", "test", "--no-pub", str(test), "--reporter", "expanded"],
            cwd=ROOT,
            env=env,
            check=True,
        )
    measurements = json.loads(output.read_text())
    sources = [
        ROOT / "lib/models/common/video/thread_ripper.dart",
        *sorted((ROOT / "lib/services/thread_ripper").glob("*.dart")),
    ]
    report = {
        "date": datetime.now(timezone.utc).date().isoformat(),
        "baseline_commit": BASELINE,
        "reference_commit": REFERENCE,
        "configuration": {
            "connection_limit": 8,
            "http_response_delay_ms": 80,
            "download_fixture_bytes": 2097152,
            "download_repetitions": 3,
            "disconnect_fixture_bytes": 6291456,
            "disconnect_observation_ms": 500,
            "transport": "local HTTP, no bandwidth cap, one media track",
        },
        "combined_source_sha256": {
            str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sources
        },
        "results": measurements,
    }
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Saved comparison: {output}")


if __name__ == "__main__":
    main()
