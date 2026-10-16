## glyphes — single test runner (TESTING.md §4).
##
## Every Nim-side gate runs from here. `-d:glyphesCheck` turns on the
## debug-build invariant assertions (STORAGE.md §8); the release build
## omits them and is what the benchmark suite measures.

import std/unittest

import unit/test_core
import unit/test_store
import unit/test_wal
import unit/test_txn
import unit/test_abi
import unit/test_follower_abi
import unit/test_cypher
import unit/test_exec
import unit/test_write
import unit/test_index
import unit/test_version
import unit/test_version_txn
import unit/test_vhist
import unit/test_s1_lock
import unit/test_s2_shm
import unit/test_follow

# Store (M1), durability (M2), transactions (M3) and the exported C
# surface are landed here; query (M4-M6) suites are added as their
# milestones land, per docs/TESTING.md §2.
