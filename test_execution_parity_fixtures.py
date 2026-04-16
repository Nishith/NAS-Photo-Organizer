#!/usr/bin/env python3
"""Parity tests for checked-in execution fixtures."""

from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path


def _load_generator_module():
    repo_root = Path(__file__).resolve().parent
    module_path = repo_root / "tests" / "fixtures" / "parity" / "generate_execution_golden.py"
    spec = importlib.util.spec_from_file_location("generate_execution_golden", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


generator = _load_generator_module()


class ExecutionParityFixtureTests(unittest.TestCase):
    def test_checked_in_execution_golden_outputs_match_current_python_engine(self):
        for scenario_dir in generator.scenario_dirs():
            with self.subTest(scenario=scenario_dir.name):
                expected_path = scenario_dir / "expected.json"
                with expected_path.open("r", encoding="utf-8") as handle:
                    expected = json.load(handle)

                actual = generator.run_scenario(scenario_dir / "manifest.json")
                self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
