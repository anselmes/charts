# SPDX-License-Identifier: GPL-3.0
# Copyright (c) 2026 Schubert Anselme <schubert@anselm.es>
"""Unit tests for check_charts.py. Run with ``python3 -m unittest discover hack/ci``."""

from __future__ import annotations

import unittest

import check_charts as cc


def job(command: list[str], args: list[str] | None = None, kind: str = "Job") -> dict:
    container: dict = {"name": "kubectl", "command": command}
    if args is not None:
        container["args"] = args
    pod = {"spec": {"containers": [container]}}
    match kind:
        case "Pod":
            return {"kind": "Pod", **pod}
        case "CronJob":
            return {"kind": "CronJob", "spec": {"jobTemplate": {"spec": {"template": pod}}}}
        case _:
            return {"kind": kind, "spec": {"template": pod}}


class SamplesTests(unittest.TestCase):
    def test_groups_helmreleases_by_chart(self) -> None:
        docs = [
            {
                "kind": "HelmRelease",
                "metadata": {"name": "envoy", "namespace": "kube-system"},
                "spec": {
                    "releaseName": "envoy-gw",
                    "chart": {"spec": {"chart": "gwapi"}},
                    "values": {"a": 1},
                },
            },
            {
                "kind": "HelmRelease",
                "metadata": {"name": "trust"},
                "spec": {"targetNamespace": "certs", "chart": {"spec": {"chart": "ca"}}},
            },
            {"kind": "HelmRepository", "metadata": {"name": "repo"}},
            None,
        ]
        found = cc.samples_from_docs("s.yaml", docs)
        self.assertEqual(sorted(found), ["ca", "gwapi"])
        envoy = found["gwapi"][0]
        self.assertEqual(
            (envoy.label, envoy.release, envoy.namespace, envoy.values),
            ("s.yaml#envoy", "envoy-gw", "kube-system", {"a": 1}),
        )
        trust = found["ca"][0]
        self.assertEqual((trust.release, trust.namespace, trust.values), ("trust", "certs", {}))

    def test_skips_chart_ref_releases(self) -> None:
        docs = [{"kind": "HelmRelease", "spec": {"chartRef": {"kind": "OCIRepository"}}}]
        self.assertEqual(cc.samples_from_docs("s.yaml", docs), {})


class SubstitutionTests(unittest.TestCase):
    def test_parse_env(self) -> None:
        text = "# comment\nexport A=one\nB='two'\nexport EMPTY=\n\nnot a pair\n"
        self.assertEqual(cc.parse_env(text), {"A": "one", "B": "two", "EMPTY": ""})

    def test_substitute_like_flux(self) -> None:
        env = {"DOMAIN": "svc.local", "EMPTY": ""}
        self.assertEqual(
            cc.substitute("h: a.${DOMAIN} e: '${EMPTY}' u: '${UNSET}' k: $${KEEP}", env),
            "h: a.svc.local e: '' u: '' k: $${KEEP}",
        )


class ScriptTests(unittest.TestCase):
    def test_command_with_inline_script(self) -> None:
        self.assertEqual(
            cc.container_script({"command": ["/bin/bash", "-c", "echo hi"]}),
            ("bash", "echo hi"),
        )

    def test_script_split_across_command_and_args(self) -> None:
        self.assertEqual(
            cc.container_script({"command": ["sh"], "args": ["-ec", "true"]}),
            ("sh", "true"),
        )

    def test_ash_maps_to_sh(self) -> None:
        self.assertEqual(cc.container_script({"command": ["ash", "-c", "x"]}), ("sh", "x"))

    def test_ignores_non_shell_and_missing_c(self) -> None:
        self.assertIsNone(cc.container_script({"command": ["kubectl", "-c", "apply"]}))
        self.assertIsNone(cc.container_script({"command": ["bash", "-e", "script.sh"]}))
        self.assertIsNone(cc.container_script({"command": ["bash", "run", "x"]}))
        self.assertIsNone(cc.container_script({"command": ["bash"]}))

    def test_extracts_from_workload_kinds(self) -> None:
        for kind in ("Job", "CronJob", "Pod", "Deployment"):
            with self.subTest(kind=kind):
                scripts = cc.extract_scripts("c/t.yaml", job(["bash", "-c", "true"], kind=kind))
                self.assertEqual(scripts, [cc.Script("c/t.yaml", "kubectl", "bash", "true")])

    def test_own_templates_only(self) -> None:
        chart = cc.Chart(path=cc.REPO_ROOT, name="semaphore", library=False)
        self.assertTrue(cc.is_own_template(chart, "semaphore/templates/job.yaml"))
        self.assertFalse(
            cc.is_own_template(chart, "semaphore/charts/semaphoreui/templates/deployment.yaml")
        )

    def test_ignores_other_kinds(self) -> None:
        self.assertEqual(cc.extract_scripts("x", {"kind": "ConfigMap", "data": {}}), [])
        self.assertEqual(cc.extract_scripts("x", "not a mapping"), [])


class RenderedTests(unittest.TestCase):
    def test_split_rendered_keeps_source(self) -> None:
        text = (
            "---\n# Source: c/templates/a.yaml\nkind: Job\n"
            "---\n# Source: c/templates/b.yaml\nkind: Pod\n"
        )
        self.assertEqual(
            [source for source, _ in cc.split_rendered(text)],
            ["c/templates/a.yaml", "c/templates/b.yaml"],
        )


class ManifestTests(unittest.TestCase):
    def test_finds_manifest_heredocs(self) -> None:
        body = (
            "set -e\n"
            "cat > /tmp/a.yaml <<'EOF'\napiVersion: v1\nkind: ConfigMap\nEOF\n"
            "cat <<END\nnot a manifest\nEND\n"
            "kubectl apply -f - <<-\"EOF\"\n\tapiVersion: v1\n\tkind: Secret\n\tEOF\n"
        )
        self.assertEqual(
            cc.embedded_manifests(body),
            ["apiVersion: v1\nkind: ConfigMap", "\tapiVersion: v1\n\tkind: Secret"],
        )

    def test_flags_misindented_labels(self) -> None:
        docs = [
            {
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {"name": "x", "labels": None},
                "app.kubernetes.io/name": "x",
            }
        ]
        problems = cc.manifest_problems(docs)
        self.assertEqual(len(problems), 1)
        self.assertIn("app.kubernetes.io/name", problems[0])

    def test_accepts_valid_objects_and_empty_docs(self) -> None:
        docs = [None, {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {}, "data": {}}]
        self.assertEqual(cc.manifest_problems(docs), [])

    def test_requires_api_version_and_kind(self) -> None:
        self.assertEqual(len(cc.manifest_problems([{"metadata": {"name": "x"}}])), 1)
        self.assertEqual(len(cc.manifest_problems(["text"])), 1)


if __name__ == "__main__":
    unittest.main()
