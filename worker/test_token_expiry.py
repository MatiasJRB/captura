"""Go RFC3339 fractions must work on the supported Python 3.9 runtime."""
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import worker


class TokenExpiryTests(unittest.TestCase):
    def test_drive_token_reuses_trimmed_fraction_without_refreshing(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)/'rclone.conf'
            path.write_text('[fixture]\ntype = drive\ntoken = '+json.dumps(
                dict(access_token='fictional',expiry='2099-01-02T03:04:05.1234Z'))+'\n')
            config = dict(rclone_config=str(path),remote='fixture',rclone='must-not-run')
            with patch.object(worker.subprocess,'run',side_effect=AssertionError('unexpected refresh')):
                self.assertEqual('fictional',worker.drive_token(config))

    def test_trimmed_fraction_precision_keeps_the_same_instant(self):
        for fraction in ['1','12','123','1234','12345','123456','123456789']:
            expected = int(fraction[:6].ljust(6,'0'))
            value = worker.parse_token_expiry('2030-01-02T03:04:05.'+fraction+'Z')
            self.assertEqual(expected,value.microsecond)
            self.assertEqual(timezone.utc,value.tzinfo)

    def test_timezone_and_whole_seconds_are_preserved(self):
        self.assertEqual(datetime(2030,1,2,3,4,5,tzinfo=timezone.utc),
                         worker.parse_token_expiry('2030-01-02T03:04:05Z'))
        self.assertEqual(3*3600, worker.parse_token_expiry('2030-01-02T03:04:05+03:00').utcoffset().total_seconds())

    def test_invalid_or_naive_metadata_is_rejected_without_echo(self):
        for value in [None,{},'private-value','2030-01-02T03:04:05','2030-99-99T03:04:05Z']:
            with self.subTest(value=value), self.assertRaisesRegex(worker.SafeError,'^existing_drive_token_metadata_invalid$'):
                worker.parse_token_expiry(value)
