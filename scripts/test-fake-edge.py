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
from unittest.mock import patch


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

    def test_a_pake_body_and_the_channel_go_to_the_yard_half(self):
        route = fake_edge.route
        pake = json.dumps({"pake": {"step": "start", "msg": "AA"}}).encode()
        self.assertEqual(route("/user/pair", pake), "helper")
        self.assertEqual(route("/user/e2e", b"\x00\x01"), "helper")
        self.assertEqual(route("/user/e2e", b""), "helper")

    def test_a_plain_pairing_and_everything_else_stays_here(self):
        route = fake_edge.route
        self.assertEqual(route("/user/pair", json.dumps({"code": "K7QM-2XPD"}).encode()), "local")
        self.assertEqual(route("/user/pair", json.dumps({"sealed": "AA"}).encode()), "local")
        self.assertEqual(route("/user/pair", b""), "local")
        self.assertEqual(route("/user/pair", b"not json"), "local")
        self.assertEqual(route("/user/pair", b"[1, 2]"), "local")
        self.assertEqual(route("/user/me", b""), "local")
        self.assertEqual(route("/user/call/Flows", b"{}"), "local")
        self.assertEqual(route("/user/events", b""), "local")

    def test_a_sealed_stream_is_relayed_before_the_next_chunk_arrives(self):
        class Answer:
            def __init__(self):
                self.reads = 0

            def read1(inner, size):
                self.assertEqual(size, 65536)
                inner.reads += 1
                if inner.reads == 1:
                    return b"first heartbeat\n"
                if inner.reads == 2:
                    self.assertEqual(output.parts, [b"first heartbeat\n"])
                    self.assertEqual(output.flushes, 1)
                    return b"second heartbeat\n"
                self.assertEqual(inner.reads, 3)
                return b""

            def read(inner, size):
                raise AssertionError("a whole read would wait for later stream chunks")

        class Output:
            def __init__(self):
                self.parts = []
                self.flushes = 0

            def write(self, chunk):
                self.parts.append(chunk)

            def flush(self):
                self.flushes += 1

        output = Output()
        fake_edge.relay_response(Answer(), output)
        self.assertEqual(output.parts, [b"first heartbeat\n", b"second heartbeat\n"])
        self.assertEqual(output.flushes, 2)

    def test_interrupting_helper_startup_stops_its_process_group(self):
        class Pipe:
            def readline(self):
                raise KeyboardInterrupt

        class Process:
            def __init__(self):
                self.pid = 123
                self.stdout = Pipe()

        process = Process()
        with patch.object(fake_edge.shutil, "which", return_value="/usr/bin/go"), \
             patch.object(fake_edge.subprocess, "Popen", return_value=process), \
             patch.object(fake_edge, "stop_yard") as stop:
            with self.assertRaises(KeyboardInterrupt):
                fake_edge.start_yard("http://127.0.0.1:12345")
        stop.assert_called_once_with(process)


if __name__ == "__main__":
    unittest.main()
