import unittest

import pandas as pd

from uem_data_generator.line_protocol import frame_to_lines


class LineProtocolTest(unittest.TestCase):
    def test_template_has_no_timestamp(self):
        frame = pd.DataFrame([{"city": "New York", "value": 1.5}])
        line = frame_to_lines(
            frame,
            measurement="m",
            tags=["city"],
            fields=["value"],
            include_timestamp=False,
        )[0]
        self.assertEqual(line, r"m,city=New\ York value=1.5")

    def test_historical_timestamp_is_written_in_microseconds(self):
        frame = pd.DataFrame(
            [{"timestamp": "2026-06-12T16:00:00Z", "city": "New York", "value": 1.5}]
        )
        line = frame_to_lines(
            frame,
            measurement="m",
            tags=["city"],
            fields=["value"],
        )[0]

        timestamp = line.rsplit(" ", 1)[1]
        self.assertEqual(timestamp, "1781280000000000")
        self.assertEqual(len(timestamp), 16)


if __name__ == "__main__":
    unittest.main()
