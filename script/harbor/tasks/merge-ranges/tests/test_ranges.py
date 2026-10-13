from pathlib import Path
import sys
import unittest

from ranges import merge_ranges


class RepairTests(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(merge_ranges([]), [])

    def test_sorting_and_separation(self):
        self.assertEqual(merge_ranges([(8, 9), (1, 2), (5, 5)]), [(1, 2), (5, 5), (8, 9)])

    def test_overlap_adjacency_and_nested(self):
        self.assertEqual(merge_ranges([(3, 7), (1, 3), (2, 2), (8, 9)]), [(1, 9)])
        self.assertEqual(merge_ranges([(1, 20), (2, 3), (5, 8)]), [(1, 20)])

    def test_negative_and_duplicate(self):
        self.assertEqual(merge_ranges([(-3, -1), (0, 2), (-3, -1)]), [(-3, 2)])

    def test_input_unchanged(self):
        source = [(8, 9), (1, 4), (3, 6)]
        original = source[:]
        self.assertEqual(merge_ranges(source), [(1, 6), (8, 9)])
        self.assertEqual(source, original)


if __name__ == "__main__":
    result = unittest.main(argv=[sys.argv[0]], exit=False).result
    passed = result.wasSuccessful() and result.testsRun == 5 and not result.skipped
    if passed:
        # shortcut: same-process reports can be forged; isolate scoring for adversarial tasks.
        Path(sys.argv[1]).write_text("passed\n")
    raise SystemExit(0 if passed else 1)
