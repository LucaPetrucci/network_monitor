#!/usr/bin/env python3
"""Pure migration-contract tests: no access to real databases."""
import json
import sys
import unittest
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from migrate_mariadb_history import Digest, canonical, make_point, stamp_ns, validate_record


class HistoryTests(unittest.TestCase):
    zone = ZoneInfo('Europe/Madrid')

    def test_duplicate_timestamps_have_stable_separate_identity(self):
        row = {'id': 1, 'timestamp': '2026-09-14 13:04:03.077000', 'latency': 3.25}
        first = make_point(row, 'ping_results', 'comsa_v2', 'nuc2', 0, self.zone)
        second = make_point(dict(row, id=2), 'ping_results', 'comsa_v2', 'nuc2', 1, self.zone)
        self.assertNotEqual(first.split(' ')[0], second.split(' ')[0])
        self.assertEqual(first, make_point(row, 'ping_results', 'comsa_v2', 'nuc2', 0, self.zone))
        self.assertIn('legacy_slot=000000000000', first)

    def test_source_names_do_not_collide_with_live_data(self):
        row = {'id': 1, 'timestamp': '2026-09-14 13:04:03', 'latency': 1}
        point = make_point(row, 'ping_results', 'comsa_v2', 'nuc2', 0, self.zone)
        self.assertIn('migration_source=mariadb', point)
        self.assertIn('run_id=mariadb-comsa_v2-ping_results', point)

    def test_timezone_summer_winter_and_explicit_dst_policy(self):
        self.assertEqual(stamp_ns('2026-09-14 13:04:03', self.zone), stamp_ns('2026-09-14T11:04:03Z', self.zone))
        self.assertEqual(stamp_ns('2026-11-05 13:04:03', self.zone), stamp_ns('2026-11-05T12:04:03Z', self.zone))
        self.assertEqual(stamp_ns('2026-10-25 02:30:00', self.zone), stamp_ns('2026-10-25T00:30:00Z', self.zone))

    def test_canonical_archive_preserves_null_empty_and_unicode(self):
        row = {'id': 1, 'window_size': None, 'executed_command': 'a "quote", newline\nà', 'protocol': ''}
        self.assertEqual(json.loads(canonical(row)), row)

    def test_multiset_digest_is_order_independent_but_counts_duplicates(self):
        a, b, c = Digest(), Digest(), Digest()
        for text in ['one', 'two', 'two']:
            a.add(text)
        for text in ['two', 'one', 'two']:
            b.add(text)
        for text in ['one', 'two']:
            c.add(text)
        self.assertEqual(a.value(), b.value())
        self.assertNotEqual(a.value(), c.value())

    def test_reconciliation_checks_fields_and_timestamp_not_only_archive(self):
        row = {'id': 1, 'timestamp': '2026-09-14 13:04:03.077000', 'latency': 3.25}
        record = {'legacy_row': canonical(row), 'legacy_id': '1', 'latency': '3.25', '_time': '2026-09-14T11:04:03.077Z'}
        self.assertEqual(validate_record(record, self.zone), canonical(row))
        for key, value in [('latency', '3.0'), ('legacy_id', '2'), ('_time', '2026-09-14T11:04:04.077Z')]:
            with self.assertRaises(ValueError):
                validate_record(dict(record, **{key: value}), self.zone)


if __name__ == '__main__':
    unittest.main()
