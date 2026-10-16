"""Check native JSON boundaries without changing their wire representation."""

import ast
import copy
import json
import sys
import unittest
from pathlib import Path

from pydantic import ValidationError
from script.harbor.models import CheckpointResponse, CompletenessReport, NativeResult


class NativeModelTests(unittest.TestCase):
    def test_native_fields_round_trip_without_adding_absent_optional_fields(self):
        payload = {
            "modelID": "fixture",
            "outcome": "completed",
            "turnID": "turn",
            "finishTaskStatus": "done",
            "maxToolLoopIterations": 25,
            "contextTokenLimit": 8192,
            "futureMetadata": {"value": 1},
        }
        result = NativeResult.model_validate_json(json.dumps(payload))
        self.assertEqual(result.model_dump(exclude_unset=True), payload)
        minimal = {"modelID": "fixture", "outcome": "failed", "errorMessage": "Could not load model"}
        self.assertEqual(NativeResult.model_validate(minimal).model_dump(exclude_unset=True), minimal)

    def test_native_fields_reject_invalid_types_and_unknown_outcomes(self):
        for key, value in (
            ("outcome", "success"),
            ("modelID", ""),
            ("turnID", ""),
            ("finishTaskStatus", "success"),
            ("maxToolLoopIterations", True),
            ("maxToolLoopIterations", -1),
            ("contextTokenLimit", "8192"),
            ("contextTokenLimit", 0),
        ):
            with self.subTest(key=key, value=value), self.assertRaises(ValidationError):
                NativeResult.model_validate({"modelID": "fixture", "outcome": "completed", key: value})

    def test_checkpoint_envelope_requires_result_and_rejects_extra_keys(self):
        payload = {"checkpointID": "first", "result": {"modelID": "fixture", "outcome": "completed"}}
        self.assertEqual(CheckpointResponse.model_validate(payload).model_dump(exclude_unset=True), payload)
        for update in ({"checkpointID": 1}, {"checkpointID": ""}, {"result": None}, {"unexpected": True}):
            with self.subTest(update=update), self.assertRaises(ValidationError):
                CheckpointResponse.model_validate({**payload, **update})

    def test_completeness_report_does_not_coerce_flags_counts_or_issue_strings(self):
        payload = {
            "schema_version": 1,
            "complete": True,
            "issues": [],
            "files": {"agent/result.json": {"bytes": 50, "sha256": "digest"}},
            "steps": [{"name": "second", "attempted": False, "reason": "Previous failure"}],
        }
        self.assertEqual(CompletenessReport.model_validate(payload).model_dump(exclude_unset=True), payload)
        for update in (
            {"schema_version": True},
            {"schema_version": 2},
            {"complete": "true"},
            {"complete": 1},
            {"issues": [1]},
            {"trace_requests": True},
            {"trace_clipped_rows": -1},
            {"files": []},
        ):
            with self.subTest(update=update), self.assertRaises(ValidationError):
                CompletenessReport.model_validate({**copy.deepcopy(payload), **update})

    def test_container_worker_uses_only_standard_library_and_python37_syntax(self):
        worker = Path(__file__).with_name("worker.py")
        tree = ast.parse(worker.read_text(), feature_version=(3, 7))
        imports = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imports.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                self.assertEqual(node.level, 0)
                imports.add(node.module.split(".")[0])
        self.assertLessEqual(imports, sys.stdlib_module_names)


if __name__ == "__main__":
    unittest.main()
