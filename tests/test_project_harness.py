"""The project contract must remain traversable and must not authorize execution."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('project_harness', ROOT / 'scripts/check_harness.py')
HARNESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HARNESS)


class ProjectHarnessTests(unittest.TestCase):
    def setUp(self):
        self.contract = json.loads((ROOT / 'docs/project/harness.json').read_text())

    def test_repository_contract_is_valid_and_connected(self):
        self.assertEqual([], HARNESS.validate(self.contract, ROOT))
        self.assertIn('docs/project/harness.md', (ROOT / 'AGENTS.md').read_text())

    def test_missing_product_domain_is_rejected(self):
        self.contract['subprojects'] = self.contract['subprojects'][1:]
        self.assertTrue(HARNESS.validate(self.contract, ROOT))

    def test_duplicate_id_is_rejected(self):
        self.contract['subprojects'].append(copy.deepcopy(self.contract['subprojects'][0]))
        self.assertTrue(HARNESS.validate(self.contract, ROOT))

    def test_missing_handoff_cannot_look_complete(self):
        self.contract['subprojects'][0]['nextAction'] = ''
        self.assertTrue(HARNESS.validate(self.contract, ROOT))

    def test_missing_or_external_source_is_rejected(self):
        for path in ['docs/not-present.md', '../outside.md', '/tmp/outside.md', 'https://example.com']:
            with self.subTest(path=path):
                contract = copy.deepcopy(self.contract)
                contract['subprojects'][0]['sources'] = [path]
                self.assertTrue(HARNESS.validate(contract, ROOT))

    def test_unknown_qa_mode_is_rejected(self):
        self.contract['subprojects'][0]['qa'][0]['mode'] = 'mock_counts_as_human'
        self.assertTrue(HARNESS.validate(self.contract, ROOT))

    def test_execution_permission_cannot_be_granted_by_contract(self):
        self.contract['executionAuthorizedByContract'] = True
        self.assertTrue(HARNESS.validate(self.contract, ROOT))

    def test_incomplete_case_is_rejected(self):
        del self.contract['subprojects'][0]['qa'][0]['evidence']
        self.assertTrue(HARNESS.validate(self.contract, ROOT))

    def test_verified_state_requires_a_completion_receipt(self):
        self.contract['subprojects'][0]['status'] = 'verified'
        self.assertTrue(HARNESS.validate(self.contract, ROOT))

    def test_non_string_status_and_mode_do_not_crash(self):
        self.contract['subprojects'][0]['status'] = []
        self.contract['subprojects'][0]['qa'][0]['mode'] = {}
        self.assertTrue(HARNESS.validate(self.contract, ROOT))

    def test_malformed_contract_returns_errors(self):
        for contract in [None, [], {}, {'schemaVersion': 1, 'subprojects': 'android'}]:
            with self.subTest(contract=contract):
                self.assertTrue(HARNESS.validate(contract, ROOT))


if __name__ == '__main__':
    unittest.main()
