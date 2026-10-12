Fix `merge_ranges` in `/app/ranges.py`.

Each input tuple is an inclusive integer interval `(start, end)`, with `start <= end`.
Return a sorted list of tuples that merges overlapping or adjacent intervals.
Handle empty input, negative endpoints, duplicate intervals, and intervals nested
inside other intervals. Do not mutate the input. Keep the public function signature.

Run the existing tests and add useful cases if needed. All task files and commands
belong to the task workspace `/app`.
