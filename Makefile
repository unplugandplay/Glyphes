# glyphes — task runner.
#
# Every target is a thin wrapper: the work lives in `glyphes.nimble`, so a
# benchmark is reproducible from either entry point and the two cannot drift
# apart. `make bench` is the name the roadmap promises, and it runs the
# whole suite.
#
#   make bench          every benchmark (long: the suite builds 10^6-node
#                       fixtures and the SQLite comparison loads a graph
#                       statement by statement)
#   make bench-sqlite   only the M11 comparison against SQLite edge-tables
#   make test           the Nim and Ruby suites
#   make gate           the full gate: tests, TCK, and every pinned budget
#   make soak           the 20-node concurrency soak (SOAK_NODES=20 SOAK_DAYS=5)
#   make soak-smoke     the same harness, briefly, to prove it runs

NIM ?= nimble
RUBY ?= ruby

.PHONY: all bench bench-index bench-query bench-sqlite bench-vector \
        bench-import bench-sort \
        test test-nim test-ruby gate tck soak soak-smoke clean help

all: test

help:
	@echo "glyphes targets:"
	@echo "  make bench         - every benchmark"
	@echo "  make bench-sqlite  - M11 vs SQLite edge-tables (needs the sqlite3 gem)"
	@echo "  make test          - Nim + Ruby suites"
	@echo "  make gate          - full gate (tests, TCK, pinned budgets)"
	@echo "  make soak          - 20-node 5-day leak soak (SOAK_SECONDS, SOAK_NODES)"
	@echo "  make soak-smoke    - 100s soak, to prove the harness runs"

# ---------------------------------------------------------------- benchmarks

## The full suite. Order is cheapest-first so an early failure is cheap.
bench: bench-index bench-query bench-sort bench-vector bench-import bench-sqlite
	@echo "bench: done"

bench-index:
	$(NIM) benchIndex

bench-query:
	$(NIM) benchQuery

bench-sort:
	$(NIM) benchSort

bench-vector:
	$(NIM) benchVector

bench-import:
	$(NIM) benchImport

bench-sqlite:
	$(NIM) benchSqlite

# ------------------------------------------------------------------- tests

test: test-nim test-ruby

test-nim:
	$(NIM) test

test-ruby:
	$(RUBY) -Itests -Ilib tests/e2e/run.rb

## The gate every milestone has to pass: both suites, the TCK, and the
## pinned absolute budgets. Timing budgets are suspended automatically when
## the machine is loaded, and the ratio gates still run.
gate:
	$(NIM) gate

tck:
	$(NIM) tck

# -------------------------------------------------------------------- soak

## The 20-node, 5-day zero-leak soak (M11's gate). SOAK_SECONDS and
## SOAK_NODES override, so the same harness serves a smoke test and the real
## thing:
##   make soak                  -> 20 nodes, 5 days (432000 s)
##   make soak-smoke            -> the same, briefly
##   make soak SOAK_SECONDS=600
soak:
	$(NIM) soakLeak $(SOAK_SECONDS) $(SOAK_NODES)

soak-smoke:
	$(MAKE) soak SOAK_SECONDS=100 SOAK_NODES=20

# -------------------------------------------------------------------- misc

clean:
	rm -rf tmp
