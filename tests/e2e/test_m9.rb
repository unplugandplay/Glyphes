require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "glyphes"

# M9 — import and export (RUBY.md §6). Gate R11: an unknown column raises;
# no silent data drop. Gate R8: the CSV import rate, measured in
# bench_import.rb rather than asserted here.
#
# The engine never sees a file format (PRD.md P9): everything below is Ruby
# parsing bytes and handing the engine Cypher and parameters.
class M9Test < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @db = Glyphes::Database.open(File.join(@dir, "m9.glyph"), create: true)
  end

  def teardown
    @db.close unless @db.closed?
    FileUtils.remove_entry(@dir)
  end

  def path(name) = File.join(@dir, name)

  def write(name, content)
    p = path(name)
    File.write(p, content)
    p
  end

  # ---- import: CSV ----------------------------------------------------

  def test_csv_import_creates_nodes_with_coerced_types
    csv = write("p.csv", "name,city,age\nana,Lyon,34\nbo,Nice,28\n")
    assert_equal 2, @db.import(csv, into: :Person, types: { age: :integer })
    rows = @db.query("MATCH (p:Person) RETURN p.name AS n, p.age AS a ORDER BY p.name").to_a
    assert_equal [["ana", 34], ["bo", 28]], rows
  end

  def test_skip_drops_leading_rows_before_the_header
    csv = write("junk.csv", "not,a,header\nname,age\nana,34\n")
    # skip: counts rows to drop *before* the header is read.
    assert_equal 1, @db.import(csv, into: :Person, skip: 1, types: { age: :integer })
    assert_equal [["ana", 34]],
                 @db.query("MATCH (p:Person) RETURN p.name AS n, p.age AS a").to_a
  end

  def test_an_unknown_column_raises_r11
    csv = write("typo.csv", "name,nmae\nana,x\n")
    # The file has a column `keys:` does not name. Importing it anyway drops
    # the column silently — the header typo nobody notices until the data
    # is gone. R11: raise.
    err = assert_raises(ArgumentError) { @db.import(csv, into: :Person, keys: %i[name]) }
    assert_match(/nmae/, err.message)
    assert_equal 0, @db.query("MATCH (p:Person) RETURN p").count
  end

  def test_a_failed_import_writes_nothing_at_all
    csv = write("bad.csv", "name,age\nana,34\nbo,not-a-number\n")
    assert_raises(ArgumentError) { @db.import(csv, into: :Person, types: { age: :integer }) }
    # One transaction around the whole file (Y12): a half-import is worse
    # than none, because it looks finished.
    assert_equal 0, @db.query("MATCH (p:Person) RETURN p").count
  end

  def test_a_coercion_failure_names_the_row_and_the_column
    csv = write("bad2.csv", "name,age\nana,34\nbo,not-a-number\n")
    err = assert_raises(ArgumentError) { @db.import(csv, into: :Person, types: { age: :integer }) }
    assert_match(/row 2/, err.message)
    assert_match(/age/, err.message)
  end

  def test_batch_size_does_not_change_the_result
    csv = write("many.csv", (1..50).map { |i| "#{i}" }.join("\n").prepend("n\n"))
    @db.import(csv, into: :Num, batch: 1)
    @db.import(csv, into: :Num2, batch: 7)
    assert_equal @db.query("MATCH (n:Num) RETURN count(n) AS c").to_a.first,
                 @db.query("MATCH (n:Num2) RETURN count(n) AS c").to_a.first
  end

  # ---- import: JSONL --------------------------------------------------

  def test_jsonl_import
    jl = write("d.jsonl", %({"name":"doc1","year":2020}\n{"name":"doc2","year":2021}\n))
    assert_equal 2, @db.import(jl, into: :Doc, types: { year: :integer })
    assert_equal [[2020], [2021]],
                 @db.query("MATCH (d:Doc) RETURN d.year AS y ORDER BY y").to_a
  end

  def test_jsonl_unknown_column_raises
    jl = write("d.jsonl", %({"name":"doc1","nmae":"x"}\n))
    err = assert_raises(ArgumentError) { @db.import(jl, into: :Doc, keys: %i[name year]) }
    assert_match(/nmae/, err.message)
  end

  # ---- import: vector --------------------------------------------------

  def test_a_vector_import_builds_the_index_after_the_load
    jl = write("v.jsonl", (1..20).map { |i| %({"name":"d#{i}","emb":[#{i}.0,2.0,3.0]}) }.join("\n"))
    assert_equal 20, @db.import(jl, into: :V, vector: :emb, dim: 3, types: { emb: :vector })
    assert_includes @db.index_list.map { |i| i["name"] }, "V.emb"
    # The index is built (not merely created), so it answers a search.
    res = @db.query("CALL db.idx.vector('V.emb') AGAINST [1.0,2.0,3.0] YIELD node, score RETURN count(node) AS c").to_a
    assert_operator res.first.first.to_i, :>=, 1
  end

  def test_a_vector_of_the_wrong_width_is_refused
    jl = write("bad.jsonl", %({"name":"d","emb":[1.0,2.0]}\n))
    err = assert_raises(ArgumentError) do
      @db.import(jl, into: :V, vector: :emb, dim: 3, types: { emb: :vector })
    end
    assert_match(/dim 3/, err.message)
  end

  # ---- export ---------------------------------------------------------

  def test_csv_export_infers_the_format_from_the_extension
    @db.exec("CREATE (:Person {name: 'ana', age: 34})")
    @db.exec("CREATE (:Person {name: 'bo', age: 28})")
    out = path("out.csv")
    @db.export(@db.query("MATCH (p:Person) RETURN p.name AS name, p.age AS age ORDER BY p.name"), to: out)
    assert_equal "name,age\nana,34\nbo,28\n", File.read(out)
  end

  def test_jsonl_export
    @db.exec("CREATE (:Doc {name: 'doc1', year: 2020})")
    out = path("out.jsonl")
    @db.export(@db.query("MATCH (d:Doc) RETURN d.name AS name, d.year AS year"), to: out)
    assert_equal({ "name" => "doc1", "year" => 2020 }, JSON.parse(File.read(out).strip))
  end

  def test_parquet_export_refuses_a_nested_value
    @db.exec("CREATE (:Doc {name: 'x', tags: ['a', 'b']})")
    out = path("out.parquet")
    # Parquet has no nested type here; a list column is refused, not
    # stringified into something readable and wrong (RUBY.md §6.2).
    err = assert_raises(ArgumentError) do
      @db.export(@db.query("MATCH (d:Doc) RETURN d.name AS name, d.tags AS tags"), to: out)
    end
    assert_match(/nested|list/i, err.message)
  end

  def test_an_unknown_extension_is_refused
    out = path("out.xlsx")
    assert_raises(ArgumentError) { @db.export(@db.query("MATCH (p:Person) RETURN p"), to: out) }
  end

  # ---- parquet round trip --------------------------------------------

  def test_parquet_round_trips_through_the_dsl
    @db.exec("CREATE (:Person {name: 'ana', age: 34})")
    @db.exec("CREATE (:Person {name: 'bo', age: 28})")
    out = path("people.parquet")
    @db.export(@db.query("MATCH (p:Person) RETURN p.name AS name, p.age AS age ORDER BY p.name"), to: out)

    other = Glyphes::Database.memory
    assert_equal 2, other.import(out, into: :Imported)
    assert_equal [["ana", 34], ["bo", 28]],
                 other.query("MATCH (i:Imported) RETURN i.name AS n, i.age AS a ORDER BY n").to_a
  end

  def test_parquet_preserves_nulls_through_a_round_trip
    @db.exec("CREATE (:P {name: 'ana', age: 34})")
    @db.exec("CREATE (:P {name: 'bo'})")
    out = path("nulls.parquet")
    @db.export(@db.query("MATCH (p:P) RETURN p.name AS name, p.age AS age ORDER BY p.name"), to: out)
    other = Glyphes::Database.memory
    other.import(out, into: :Q)
    assert_equal [["ana", 34], ["bo", nil]],
                 other.query("MATCH (q:Q) RETURN q.name AS n, q.age AS a ORDER BY n").to_a
  end

  def test_parquet_file_is_a_real_parquet_file
    @db.exec("CREATE (:P {name: 'x'})")
    out = path("f.parquet")
    @db.export(@db.query("MATCH (p:P) RETURN p.name AS name"), to: out)
    bytes = File.binread(out)
    assert_equal "PAR1", bytes[0, 4]
    assert_equal "PAR1", bytes[-4, 4]
  end

  # ---- the format layer itself ----------------------------------------

  def test_parquet_reader_refuses_a_file_that_is_not_parquet
    junk = write("junk.parquet", "this is not a parquet file")
    assert_raises(ArgumentError) { Glyphes::Parquet.read(junk) }
  end

  def test_import_refuses_a_format_it_does_not_read
    xlsx = write("x.xlsx", "nope")
    assert_raises(ArgumentError) { @db.import(xlsx, into: :X) }
  end
end