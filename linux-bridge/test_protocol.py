#!/usr/bin/env python3
import struct
import unittest

from m5wispr_bridge import parse_config, parse_packet


class ProtocolTest(unittest.TestCase):
    def test_config_and_packets(self):
        config = parse_config(struct.pack("<4sIBBHI", b"M5W1", 16_000, 16, 1, 160, 8))
        self.assertEqual((config.rate, config.channels), (16_000, 1))

        start = parse_packet(struct.pack("<IBBHhh", 41, 1, 1, 2, -123, 456))
        self.assertTrue(start.is_start)
        self.assertEqual((start.sequence, start.sample_count), (41, 2))
        self.assertEqual(start.pcm, struct.pack("<hh", -123, 456))

        stop = parse_packet(struct.pack("<IBBH", 42, 2, 1, 0))
        self.assertTrue(stop.is_stop)
        self.assertEqual(stop.pcm, b"")

        with self.assertRaisesRegex(ValueError, "length mismatch"):
            parse_packet(struct.pack("<IBBHh", 43, 0, 1, 2, 1))


if __name__ == "__main__":
    unittest.main()
