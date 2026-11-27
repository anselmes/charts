#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0
# Copyright (c) 2026 Schubert Anselme <schubert@anselm.es>
"""Lint and render every chart in the repository.

For each chart this runs ``helm lint`` and ``helm template`` with the chart's
default values, then again with the values of every HelmRelease under
``hack/samples`` that installs the chart (its ``.spec.values``), and with each
``<chart>/ci/*-values.yaml`` file (the chart-testing convention). Shell scripts
embedded in rendered workloads (``command: [bash, -c, <script>]``) are checked
with ``shellcheck``, and manifests they write through heredocs must parse as
YAML.

Requires ``helm``, ``yq`` (mikefarah, v4) and ``shellcheck`` on ``PATH``.

Usage::

    hack/ci/check_charts.py                  # every chart
    hack/ci/check_charts.py service/gwapi    # selected charts
    hack/ci/check_charts.py --offline        # skip remote dependencies
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Iterable, Iterator, Sequence
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

REPO_ROOT = Path(__file__).resolve().parents[2]
SAMPLES_DIR = REPO_ROOT / "hack" / "samples"
EXCLUDED_DIRS = frozenset({".git", "upstream", "charts"})
SHELLS = {"sh": "sh", "ash": "sh", "bash": "bash", "dash": "dash", "ksh": "ksh"}
WORKLOAD_KINDS = frozenset(
    {"Job", "CronJob", "Pod", "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet"}
)
SHELLCHECK_SEVERITY = "warning"
# SC2034: retry loops such as ``for i in {1..60}`` never read their counter.
SHELLCHECK_EXCLUDE = "SC2034"
IDENTIFIER = re.compile(r"[A-Za-z][A-Za-z0-9]*")
HEREDOC = re.compile(
    r"""<<-?[ \t]*(['"]?)(?P<tag>\w+)\1[^\n]*\n(?P<body>.*?)\n[ \t]*(?P=tag)[ \t]*$""",
    re.DOTALL | re.MULTILINE,
)


@dataclass(frozen=True)
class Chart:
    path: Path
    name: str
    library: bool


@dataclass(frozen=True)
class Sample:
    """Values taken from one HelmRelease in ``hack/samples``."""

    label: str
    release: str
    namespace: str
    values: dict[str, object]


@dataclass(frozen=True)
class Script:
    source: str
    container: str
    shell: str
    body: str


@dataclass
class Report:
    failures: list[str] = field(default_factory=list)

    def fail(self, message: str) -> None:
        self.failures.append(message)
        print(f"::error::{message}", flush=True)


# --- YAML helpers ---------------------------------------------------------------


def yaml_docs(text: str) -> list[object]:
    """Parse a multi-document YAML string into JSON values using yq."""
    out = run(["yq", "-o=json", "-I=0", "."], stdin=text, check=True).stdout
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def split_rendered(text: str) -> Iterator[tuple[str, str]]:
    """Split ``helm template`` output into ``(source, document)`` pairs."""
    for chunk in text.split("\n---"):
        chunk = chunk.removeprefix("---")
        source = ""
        for line in chunk.splitlines():
            if line.startswith("# Source: "):
                source = line.removeprefix("# Source: ").strip()
                break
        if chunk.strip():
            yield source, chunk


# --- discovery ------------------------------------------------------------------


def discover_charts(root: Path) -> list[Chart]:
    charts: list[Chart] = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if d not in EXCLUDED_DIRS)
        if "Chart.yaml" not in filenames:
            continue
        path = Path(dirpath)
        meta = yaml_docs((path / "Chart.yaml").read_text())[0]
        assert isinstance(meta, dict)
        charts.append(
            Chart(
                path=path,
                name=str(meta["name"]),
                library=meta.get("type") == "library",
            )
        )
    return charts


def samples_from_docs(label: str, docs: Iterable[object]) -> dict[str, list[Sample]]:
    """Group HelmRelease values by the chart name they install."""
    found: dict[str, list[Sample]] = {}
    for doc in docs:
        if not isinstance(doc, dict) or doc.get("kind") != "HelmRelease":
            continue
        spec = doc.get("spec") or {}
        chart = (((spec.get("chart") or {}).get("spec")) or {}).get("chart")
        if not chart:
            continue
        meta = doc.get("metadata") or {}
        release = spec.get("releaseName") or meta.get("name") or chart
        namespace = spec.get("targetNamespace") or meta.get("namespace") or "default"
        found.setdefault(chart, []).append(
            Sample(
                label=f"{label}#{meta.get('name', release)}",
                release=release,
                namespace=namespace,
                values=spec.get("values") or {},
            )
        )
    return found


def discover_samples(samples_dir: Path) -> dict[str, list[Sample]]:
    found: dict[str, list[Sample]] = {}
    for path in sorted(samples_dir.rglob("*.yaml")):
        label = str(path.relative_to(REPO_ROOT))
        for chart, samples in samples_from_docs(label, yaml_docs(path.read_text())).items():
            found.setdefault(chart, []).extend(samples)
    return found


# --- scripts --------------------------------------------------------------------


def pod_spec(doc: dict[str, object]) -> dict[str, object] | None:
    spec = doc.get("spec")
    if not isinstance(spec, dict):
        return None
    match doc.get("kind"):
        case "Pod":
            return spec
        case "CronJob":
            spec = ((spec.get("jobTemplate") or {}).get("spec")) or {}
    template = spec.get("template")
    if isinstance(template, dict) and isinstance(template.get("spec"), dict):
        return template["spec"]
    return None


def container_script(container: dict[str, object]) -> tuple[str, str] | None:
    """Return ``(shell, script)`` when a container runs ``<shell> -c <script>``."""
    argv = [*(container.get("command") or []), *(container.get("args") or [])]
    if len(argv) < 3 or not all(isinstance(a, str) for a in argv):
        return None
    shell = SHELLS.get(PurePosixPath(argv[0]).name)
    if shell is None:
        return None
    flags = argv[1:-1]
    if not flags or any(not f.startswith("-") for f in flags) or "c" not in flags[-1]:
        return None
    return shell, argv[-1]


def extract_scripts(source: str, doc: object) -> list[Script]:
    if not isinstance(doc, dict) or doc.get("kind") not in WORKLOAD_KINDS:
        return []
    spec = pod_spec(doc)
    if spec is None:
        return []
    scripts: list[Script] = []
    for key in ("initContainers", "containers"):
        for container in spec.get(key) or []:
            if not isinstance(container, dict):
                continue
            found = container_script(container)
            if found:
                shell, body = found
                scripts.append(Script(source, str(container.get("name", "?")), shell, body))
    return scripts


# --- helm -----------------------------------------------------------------------


def run(
    argv: Sequence[str],
    *,
    stdin: str | None = None,
    check: bool = False,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv, input=stdin, text=True, capture_output=True, check=check, cwd=cwd
    )


def add_repositories(charts: Iterable[Chart]) -> None:
    """Register every HTTP(S) dependency repository so dependency update finds it."""
    urls: set[str] = set()
    for chart in charts:
        meta = yaml_docs((chart.path / "Chart.yaml").read_text())[0]
        assert isinstance(meta, dict)
        for dep in meta.get("dependencies") or []:
            repo = str(dep.get("repository") or "")
            if repo.startswith(("http://", "https://")):
                urls.add(repo.rstrip("/"))
    for url in sorted(urls):
        name = "ci-" + hashlib.sha256(url.encode()).hexdigest()[:12]
        run(["helm", "repo", "add", "--force-update", name, url], check=True)
    if urls:
        run(["helm", "repo", "update"], check=True)


def offline_copy(chart: Chart, workdir: Path) -> Path:
    """Copy a chart and drop every dependency that is not vendored in charts/."""
    dest = workdir / chart.path.relative_to(REPO_ROOT)
    shutil.copytree(chart.path, dest, symlinks=True)
    vendored = sorted(p.name for p in (dest / "charts").glob("*") if p.is_dir())
    keep = json.dumps(vendored)
    run(
        ["yq", "-i", f"del(.dependencies[] | select(.name as $n | {keep} | contains([$n]) | not))",
         str(dest / "Chart.yaml")],
        check=True,
    )
    return dest


def check_chart(
    chart: Chart,
    samples: Sequence[Sample],
    report: Report,
    *,
    offline: bool,
    workdir: Path,
) -> None:
    rel = chart.path.relative_to(REPO_ROOT)
    print(f"::group::{rel}", flush=True)
    try:
        path = offline_copy(chart, workdir) if offline else chart.path
        if not offline:
            result = run(["helm", "dependency", "update", "--skip-refresh", str(path)])
            if result.returncode:
                report.fail(f"{rel}: helm dependency update failed\n{result.stderr}")
                return

        variants: list[tuple[str, str, str, dict[str, object] | None]] = [
            ("default values", chart.name, "default", None)
        ]
        variants += [(s.label, s.release, s.namespace, s.values) for s in samples]
        for values_path in sorted((chart.path / "ci").glob("*-values.yaml")):
            label = str(values_path.relative_to(REPO_ROOT))
            values = yaml_docs(values_path.read_text())[0] or {}
            assert isinstance(values, dict)
            variants.append((label, chart.name, "default", values))

        seen: set[tuple[str, str, str]] = set()
        for label, release, namespace, values in variants:
            extra: list[str] = []
            if values is not None:
                values_file = workdir / f"{hashlib.sha256(label.encode()).hexdigest()}.yaml"
                values_file.write_text(json.dumps(values))
                extra = ["--values", str(values_file)]

            print(f"lint {rel} ({label})", flush=True)
            lint = run(["helm", "lint", str(path), "--namespace", namespace, *extra])
            if lint.returncode:
                report.fail(f"{rel} ({label}): helm lint failed\n{lint.stdout}{lint.stderr}")
            if chart.library:
                continue

            print(f"template {rel} ({label})", flush=True)
            rendered = run(
                ["helm", "template", release, str(path), "--namespace", namespace, *extra]
            )
            if rendered.returncode:
                report.fail(f"{rel} ({label}): helm template failed\n{rendered.stderr}")
                continue

            for source, text in split_rendered(rendered.stdout):
                if "command:" not in text and "args:" not in text:
                    continue
                for doc in yaml_docs(text):
                    for script in extract_scripts(source, doc):
                        key = (script.source, script.container, script.body)
                        if key in seen:
                            continue
                        seen.add(key)
                        check_script(script, label, report)
    finally:
        print("::endgroup::", flush=True)


def embedded_manifests(body: str) -> list[str]:
    """Return heredoc bodies in a script that hold Kubernetes manifests."""
    return [
        m.group("body")
        for m in HEREDOC.finditer(body)
        if re.search(r"^\s*apiVersion:", m.group("body"), re.MULTILINE)
    ]


def manifest_problems(docs: Iterable[object]) -> list[str]:
    """Find documents that are not Kubernetes objects.

    Object fields are plain identifiers, so a top-level key such as
    ``app.kubernetes.io/name`` means a nested block was mis-indented.
    """
    problems: list[str] = []
    for doc in docs:
        if doc is None:
            continue
        if not isinstance(doc, dict):
            problems.append(f"has a document that is not a mapping: {doc!r:.60}")
            continue
        name = f"{doc.get('kind', '?')}/{(doc.get('metadata') or {}).get('name', '?')}"
        if "apiVersion" not in doc or "kind" not in doc:
            problems.append(f"{name} is missing apiVersion or kind")
        if bad := sorted(k for k in doc if not IDENTIFIER.fullmatch(str(k))):
            problems.append(f"{name} has unexpected top-level keys {bad} (mis-indented?)")
    return problems


def check_script(script: Script, label: str, report: Report) -> None:
    where = f"{script.source} [{script.container}] ({label})"
    for manifest in embedded_manifests(script.body):
        parsed = run(["yq", "-o=json", "-I=0", "."], stdin=manifest)
        if parsed.returncode:
            report.fail(f"{where}: embedded manifest is not valid YAML\n{parsed.stderr}")
            continue
        docs = [json.loads(line) for line in parsed.stdout.splitlines() if line.strip()]
        for problem in manifest_problems(docs):
            report.fail(f"{where}: embedded manifest {problem}")

    result = run(
        ["shellcheck", "--shell", script.shell, "--severity", SHELLCHECK_SEVERITY,
         "--exclude", SHELLCHECK_EXCLUDE, "--format", "gcc", "-"],
        stdin=script.body,
    )
    if result.returncode:
        report.fail(
            f"{script.source} [{script.container}] ({label}): shellcheck failed\n"
            + result.stdout.replace("-:", "script:")
        )


# --- main -----------------------------------------------------------------------


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("charts", nargs="*", type=Path, help="chart directories to check")
    parser.add_argument(
        "--offline",
        action="store_true",
        help="drop dependencies that are not vendored instead of downloading them",
    )
    args = parser.parse_args(argv)

    charts = discover_charts(REPO_ROOT)
    if args.charts:
        wanted = {p.resolve() for p in args.charts}
        charts = [c for c in charts if c.path.resolve() in wanted]
        if missing := wanted - {c.path.resolve() for c in charts}:
            parser.error(f"not a chart: {', '.join(map(str, sorted(missing)))}")

    samples = discover_samples(SAMPLES_DIR)
    report = Report()
    if not args.offline:
        add_repositories(charts)

    with tempfile.TemporaryDirectory(prefix="check-charts-") as tmp:
        for chart in charts:
            check_chart(
                chart,
                samples.get(chart.name, []),
                report,
                offline=args.offline,
                workdir=Path(tmp),
            )

    print(f"\nchecked {len(charts)} charts, {len(report.failures)} failures")
    for failure in report.failures:
        print(f"  - {failure.splitlines()[0]}")
    return 1 if report.failures else 0


if __name__ == "__main__":
    sys.exit(main())
