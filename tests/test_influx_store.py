#!/usr/bin/env python3
"""Storage contract tests; HTTP is simulated, no production DB is touched."""
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'network_monitor'))
import influx_store as storage
import export_excel


CONFIG = {'INFLUX_URL': 'http://127.0.0.1:8086', 'INFLUX_ORG': 'test org',
          'INFLUX_BUCKET': 'test bucket', 'INFLUX_TOKEN': 'test-token', 'NM_HOST': 'test-node'}


class Response(io.StringIO):
    def read(self):
        return super().read().encode()


class StorageTests(unittest.TestCase):
    def test_all_collectors_preserve_units_protocol_and_identity(self):
        lines = []
        with patch.object(storage.InfluxStore, 'write_lines', side_effect=lambda x: lines.extend(x)):
            storage.write_sample(CONFIG, 'iperf', '2026-11-09T12:00:00+00:00',
                ['1.25', '0.2', '3', '1200', '64K', 'udp', 'role=client protocol=udp direction=reverse'])
            storage.write_sample(CONFIG, 'ping', '2026-11-09T12:00:00+00:00', ['2.5', '10.0.0.1', '10.0.0.2'])
            storage.write_sample(CONFIG, 'interruption', '2026-11-09T12:00:00+00:00', ['5.125', '10.0.0.1', '10.0.0.2'])
        self.assertIn('protocol=udp', lines[0])
        self.assertIn('direction=reverse', lines[0])
        self.assertIn('bitrate=1.25', lines[0])
        self.assertIn('jitter=0.2', lines[0])
        self.assertIn('packet_size=1200.0', lines[0])
        self.assertIn('latency=2.5', lines[1])
        self.assertIn('interruption_time=5.125', lines[2])
        self.assertTrue(all('host=test-node' in line for line in lines))

    def test_escaping_and_nonfinite_rejection(self):
        line = storage.line_protocol('a b', {'host': 'a,b=c'}, {'command': 'say "hello"\\path'}, 1)
        self.assertIn(r'a\ b,host=a\,b\=c', line)
        self.assertIn(r'command="say \"hello\"\\path"', line)
        with self.assertRaises(ValueError):
            storage.line_protocol('test', {}, {'bitrate': float('nan')}, 1)

    def test_timezone_and_inclusive_end(self):
        self.assertEqual(storage.timestamp_ns('2026-11-09T13:00:00+01:00'),
                         storage.timestamp_ns('2026-11-09T12:00:00Z'))
        store = storage.InfluxStore(CONFIG)
        with patch.object(store, 'query', return_value=[]) as query:
            store.records('iperf_results', '2026-11-09T12:00:00Z', '2026-11-09T12:00:00Z', 'test-node')
            self.assertIn(str(storage.timestamp_ns('2026-11-09T12:00:00Z') + 1), query.call_args.args[0])

    def test_query_csv_multiple_tables_and_quoted_fields(self):
        csv = (',result,table,_time,bitrate,executed_command\r\n'
               ',_result,0,2026-11-09T12:00:00Z,1.2,"hello, world"\r\n\r\n'
               ',result,table,_time,bitrate,executed_command\r\n'
               ',_result,1,2026-11-09T12:00:01Z,2.3,other\r\n')
        with patch.object(storage.InfluxStore, 'request', return_value=csv):
            rows = storage.InfluxStore(CONFIG).query('test')
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]['executed_command'], 'hello, world')

    def test_http_write_retries_same_point_and_hides_token(self):
        calls = []
        def open_request(request, **kwargs):
            calls.append(request)
            if len(calls) == 1:
                raise HTTPError(request.full_url, 503, 'unavailable', {}, None)
            return Response('')
        with patch.object(storage, 'urlopen', side_effect=open_request), patch.object(storage.time, 'sleep'):
            storage.InfluxStore(CONFIG).write_lines(['ping_results,host=test latency=1.0 123'])
        self.assertEqual(calls[0].data, calls[1].data)
        self.assertNotIn(CONFIG['INFLUX_TOKEN'], calls[0].full_url)
        self.assertIn('bucket=test+bucket', calls[0].full_url)

    def test_excel_empty_measurements_and_column_contract(self):
        row = {'_time': '2026-11-09T12:00:00Z', 'bitrate': '1.25', 'protocol': 'udp',
               'executed_command': 'protocol=udp direction=reverse'}
        def records(self, measurement, *args, **kwargs):
            return [row] if measurement == 'iperf_results' else []
        with tempfile.TemporaryDirectory() as folder, patch.object(storage.InfluxStore, 'records', records):
            path = Path(folder) / 'test.xlsx'
            export_excel.export_influx(CONFIG, path, None, None)
            from openpyxl import load_workbook
            wb = load_workbook(path)
            self.assertEqual(wb.sheetnames, ['iperf_results', 'ping_results', 'interruptions', 'commands'])
            self.assertEqual(wb['iperf_results'].cell(2, 3).value, '1.25')
            self.assertEqual(wb['iperf_results'].cell(2, 9).value, 'udp')
            self.assertEqual(wb['ping_results'].max_row, 1)

    def test_large_export_fails_before_materializing_history(self):
        store = storage.InfluxStore(CONFIG)
        with patch.object(store, 'query', return_value=[{'_value': '5271269'}]) as query:
            with self.assertRaisesRegex(ValueError, 'narrow --start/--end'):
                store.records('ping_results', host='test-node', max_rows=200000)
            self.assertEqual(query.call_count, 1)
            self.assertIn('legacy_row', query.call_args.args[0])


if __name__ == '__main__':
    unittest.main()
