#!/usr/bin/env python3
import importlib.util
from importlib.machinery import SourceFileLoader
import json
import sys
import unittest
from pathlib import Path


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("fake-edge")
LOADER = SourceFileLoader("fake_edge", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
fake_edge = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(fake_edge)


class FakeEdgeResponseTests(unittest.TestCase):
    def test_json_keeps_dynamic_values_as_data(self):
        value = {"yard": 'north "<script>\n'}
        self.assertEqual(json.loads(fake_edge.json_body(value)), value)

    def test_bead_page_escapes_dynamic_text(self):
        page = fake_edge.bead_page('<script>alert("x")</script>', 'yard "north"')
        self.assertNotIn("<script>", page)
        self.assertIn("&lt;script&gt;", page)
        self.assertIn("&quot;", page)


if __name__ == "__main__":
    unittest.main()
