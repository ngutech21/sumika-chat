import unittest

from ranges import merge_ranges


class MergeRangesTests(unittest.TestCase):
    def test_adjacent_intervals(self):
        self.assertEqual(merge_ranges([(1, 2), (3, 5)]), [(1, 5)])

    def test_nested_intervals(self):
        self.assertEqual(merge_ranges([(1, 10), (2, 3)]), [(1, 10)])


if __name__ == "__main__":
    unittest.main()
