#!/usr/bin/env python3
import hashlib
import importlib.util
from importlib.machinery import SourceFileLoader
import json
import struct
import sys
import unittest
import zlib
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

    def test_the_gates_pictures_are_png_and_named_by_their_hash(self):
        self.assertEqual(len(fake_edge.BLOBS), 3)
        for name, data in fake_edge.MEDIA:
            self.assertEqual(fake_edge.BLOBS[hashlib.sha256(data).hexdigest()], data, name)
            self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"), name)
            # IHDR, then the one IDAT whose rows are a filter byte and
            # three bytes a pixel.
            width, height = struct.unpack(">II", data[16:24])
            length = struct.unpack(">I", data[33:37])[0]
            self.assertEqual(data[37:41], b"IDAT", name)
            rows = zlib.decompress(data[41:41 + length])
            self.assertEqual(len(rows), height * (1 + 3 * width), name)

    def test_the_gates_notes_carry_those_pictures_over_two_notes(self):
        result = json.loads(fake_edge.BEADS["yd-gate"])["result"]
        files = [[f["hash"] for f in note.get("files", [])] for note in result["notes"]]
        self.assertEqual([len(note) for note in files], [0, 1, 2])
        self.assertEqual({h for note in files for h in note}, set(fake_edge.BLOBS))


if __name__ == "__main__":
    unittest.main()
