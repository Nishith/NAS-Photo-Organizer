#!/usr/bin/env python3
"""Tests for benchmark regression-budget tooling."""

import unittest

from benchmarks.run_benchmarks import compare_to_baseline
from benchmarks.run_benchmarks import extract_metrics
from benchmarks.run_benchmarks import write_summary


class BenchmarkComparisonTests(unittest.TestCase):
    def make_summary(self, *, hashing=100.0, classification=80.0, cold=60.0, fast=240.0, preview=50.0):
        return {
            "hashing": {"files_per_second": hashing},
            "classification": {"files_per_second": classification},
            "destination_indexing": {
                "cold_entries_per_second": cold,
                "fast_dest_entries_per_second": fast,
            },
            "preview": {"files_per_second": preview},
        }

    def test_extract_metrics_uses_stable_metric_names(self):
        metrics = extract_metrics(self.make_summary())

        self.assertEqual(metrics["hashing.files_per_second"]["value"], 100.0)
        self.assertEqual(metrics["hashing.files_per_second"]["unit"], "files/s")
        self.assertEqual(metrics["destination_indexing.fast_dest_entries_per_second"]["value"], 240.0)
        self.assertTrue(metrics["preview.files_per_second"]["higher_is_better"])

    def test_compare_to_baseline_passes_within_budget(self):
        baseline = self.make_summary()
        candidate = self.make_summary(
            hashing=96.0,
            classification=81.0,
            cold=58.0,
            fast=242.0,
            preview=49.0,
        )

        comparison = compare_to_baseline(candidate, baseline, max_regression=0.05)

        self.assertTrue(comparison["pass"])
        self.assertEqual(comparison["regressions"], [])
        self.assertTrue(any(item["metric"] == "classification.files_per_second" for item in comparison["improvements"]))

    def test_compare_to_baseline_fails_beyond_budget(self):
        baseline = self.make_summary()
        candidate = self.make_summary(preview=46.0)

        comparison = compare_to_baseline(candidate, baseline, max_regression=0.05)

        self.assertFalse(comparison["pass"])
        self.assertEqual(len(comparison["regressions"]), 1)
        self.assertEqual(comparison["regressions"][0]["metric"], "preview.files_per_second")

    def test_compare_to_baseline_marks_missing_metrics(self):
        baseline = self.make_summary()
        candidate = {"hashing": {"files_per_second": 100.0}}

        comparison = compare_to_baseline(candidate, baseline, max_regression=0.05)

        self.assertIn("classification.files_per_second", comparison["missing_metrics"])
        self.assertIn("preview.files_per_second", comparison["missing_metrics"])

    def test_write_summary_emits_json_file(self):
        summary = self.make_summary()

        with self.subTest("roundtrip"):
            import json
            import os
            import tempfile

            with tempfile.TemporaryDirectory() as tmp_dir:
                output_path = os.path.join(tmp_dir, "result.json")
                write_summary(summary, output_path)

                with open(output_path, "r", encoding="utf-8") as handle:
                    written = json.load(handle)

        self.assertEqual(written["hashing"]["files_per_second"], 100.0)


if __name__ == "__main__":
    unittest.main()
