## glyphes — the M9 import/export benchmarks (RUBY.md §7, gate R8)
##
## R8 has two numbers:
##
##   * 10^6-row CSV import under 60 seconds.
##   * Parquet export within 0.1% of a Ruby reference.
##
## The first is a wall-clock budget. The second is not — it compares the
## *bytes* our Parquet writer produces against a plain-Ruby reference that
## encodes the same rows independently. Because the writer is PLAIN and
## uncompressed, that reference is exact arithmetic: the byte count of a
## PLAIN page is `num_values × width` (plus a 4-byte length per string), the
## definition levels are one byte per eight values, and the footer is
## fixed. A writer that encodes correctly *cannot* drift from that number,
## so a drift is a bug — which is the point of measuring against an
## independent count rather than against a golden file this code produced.
##
## Usage: ruby tests/bench/bench_import.rb [rows]

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "glyphes"
require "tmpdir"
require "fileutils"

ROWS = (ARGV[0] || 1_000_000).to_i

Dir.mktmpdir do |dir|
  csv = File.join(dir, "bench.csv")
  db_path = File.join(dir, "bench.glyph")

  # ---- generate ------------------------------------------------------
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  File.open(csv, "w") do |f|
    f.puts "name,city,age"
    ROWS.times { |i| f.puts "person#{i},city#{i % 1000},#{i}" }
  end
  gen = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  puts format("generated %<n>d rows in %<t>.1fs (%<s>d MiB)",
              n: ROWS, t: gen, s: File.size(csv) / 1_048_576)

  # ---- CSV import (the R8 wall-clock gate) ---------------------------
  db = Glyphes::Database.open(db_path, create: true)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  imported = db.import(csv, into: :P, types: { age: :integer })
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  rate = ROWS / elapsed
  puts format("CSV import  %<n>d rows in %<t>.1fs  (%<r>d rows/s)",
              n: imported, t: elapsed, r: rate)

  # The rows really landed — a fast import of nothing is not a fast import.
  counted = db.query("MATCH (p:P) RETURN count(p) AS c").to_a.flatten.first
  ok = counted == ROWS
  puts "  rows in the store: #{counted} #{ok ? '(matches)' : '(MISMATCH)'}"

  # ---- Parquet export vs a Ruby reference ----------------------------
  rows = ROWS < 50_000 ? ROWS : 50_000 # the reference count is O(n) in Ruby
  pq = File.join(dir, "bench.parquet")
  result = db.query("MATCH (p:P) RETURN p.name AS name, p.age AS age LIMIT #{rows}")
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  db.export(result, to: pq)
  export_el = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  size = File.size(pq)
  puts format("Parquet export %<n>d rows in %<t>.2fs  (%<s>d KiB)",
              n: rows, t: export_el, s: size / 1024)

  ref_data = result.to_a
  names = result.columns
  cols = names.each_with_index.map { |c, i| Glyphes::Parquet.infer_column(c, ref_data.map { |r| r[i] }) }
  reference = Glyphes::Parquet.reference_size(pq, cols,
                                              names.each_with_index.map { |_, i| ref_data.map { |r| r[i] } },
                                              rows)
  drift = (size - reference).abs / reference.to_f * 100.0
  puts format("  Ruby reference %<s>d bytes, drift %<d>.4f%%",
              s: reference, d: drift)

  db.close

  # ---- verdicts ------------------------------------------------------
  budget = 60.0
  csv_ok = elapsed < budget && ok
  pq_ok = drift <= 0.1

  puts
  if csv_ok
    puts format("R8 CSV: GREEN  (%.1fs < %.0fs budget)", elapsed, budget)
  else
    puts format("R8 CSV: RED    (%.1fs, budget %.0fs, rows %s)",
                elapsed, budget, counted == ROWS ? "ok" : "mismatch")
  end

  if pq_ok
    puts format("R8 Parquet: GREEN  (%.4f%% drift <= 0.1%%)", drift)
  else
    puts format("R8 Parquet: RED    (%.4f%% drift > 0.1%%)", drift)
  end

  exit(csv_ok && pq_ok ? 0 : 1)
end