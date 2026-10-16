require "minitest/autorun"
require "tmpdir"
require "json"
require "glyphes"

# M7 — the Ruby layer complete (RUBY.md).
#
# Two gates live here and two doors:
#   R1 every GlyStatus reaches a specific exception class
#   R2 zero segfaults under GC pressure holding live Cells across batches
# plus the surfaces M7 added: Node/Edge views, the Database durability
# calls, and the Statement cursor verbs.
class M7Test < Minitest::Test
  def with_db(**opts)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "m7.glyph")
      Glyphes::Database.open(path, create: true, **opts) do |db|
        yield db, path
      end
    end
  end

  # ---- R1: every status reaches a class -------------------------------

  def test_every_status_maps_to_its_class
    # R1: every GlyStatus reaches a specific class, and every class
    # descends from Glyphes::Error. glyOk is not here — it is not an error,
    # and giving it a class would invent a failure that does not exist.
    Glyphes::ErrorMapping::BY_STATUS.each do |status, klass|
      assert_operator klass, :<, Glyphes::Error,
                      "the class for status #{status} must descend from Error"
      refute_nil Glyphes::ErrorMapping::NAMES[status],
                 "status #{status} needs a name too"
    end
    # 12 since M10: GLY_ERR_CORRUPT joined the eleven. A damaged file is the
    # one failure whose only useful response is a restore, and a host that
    # cannot tell it from an I/O error retries a file that will never open.
    assert_equal 12, Glyphes::ErrorMapping::BY_STATUS.size
  end

  def test_a_damaged_database_raises_corrupt_error_and_is_left_alone
    Dir.mktmpdir do |dir|
      path = File.join(dir, "d.glyph")
      db = Glyphes::Database.open(path, create: true)
      db.exec("CREATE (:A {n: 1})")
      db.exec("CREATE (:A {n: 2})")
      db.close
      wal = path + "-wal"
      skip "no wal to damage" unless File.exist?(wal)

      # Flip a bit in a frame header: the frame's own checksum no longer
      # matches, which is damage and not a torn tail.
      bytes = File.binread(wal)
      bytes[9] = (bytes[9].ord ^ 0x08).chr
      File.binwrite(wal, bytes)
      damaged = File.binread(wal)

      assert_raises(Glyphes::CorruptError) do
        Glyphes::Database.open(path)
      end
      # The evidence is not destroyed on the way out.
      assert_equal damaged, File.binread(wal)
    end
  end

  def test_the_specific_classes_fire_for_real
    with_db do |db|
      # SQL: a parse error.
      assert_raises(Glyphes::SqlError) { db.query("MATCH (") }
      # Unsupported: a named refusal.
      assert_raises(Glyphes::UnsupportedError) { db.query("FOREACH (x IN [1] | x)") }
      # Closed: a handle past close.
      db2 = Glyphes::Database.open(":memory:")
      db2.close
      assert_raises(Glyphes::ClosedError) { db2.query("RETURN 1") }
      # Constraint: a duplicate under a unique index.
      db.exec("CREATE (:User {email: 'a@x'})")
      db.index_create(kind: :range, label: "User", property: "email",
                      constraint: :unique)
      assert_raises(Glyphes::ConstraintError) { db.exec("CREATE (:User {email: 'a@x'})") }
      # Busy: a second writer on one file. The nested `transaction` spelling
      # cannot raise at all — an inner transaction joins the outer by design,
      # and the join counter lives on the handle, so even a second Ruby
      # thread on one object joins. The busy status is what a second *open*
      # of the same file gets, which is the real second-writer case the
      # cross-process lock exists for. (This assertion used to pass for the
      # wrong reason: the constraint failure above leaked the writer claim,
      # and the next `transaction` began by raising BUSY.)
      Dir.mktmpdir do |dir|
        p2 = File.join(dir, "busy.glyph")
        w1 = Glyphes::Database.open(p2, create: true)
        begin
          assert_raises(Glyphes::BusyError) { Glyphes::Database.open(p2) }
        ensure
          w1.close
        end
      end
      # ReadOnly: a write on a read-only handle (RUBY.md §3).
      Dir.mktmpdir do |dir|
        p = File.join(dir, "ro.glyph")
        w = Glyphes::Database.open(p, create: true)
        w.exec("CREATE (:A)")
        w.close
        ro = Glyphes::Database.open(p, readonly: true)
        assert_raises(Glyphes::ReadOnlyError) { ro.exec("CREATE (:B)") }
        ro.close
      end
    end
  end

  # ---- R2: GC stress, live cells across batch boundaries --------------

  def test_live_cells_survive_gc_across_batch_boundaries
    # The one hard rule (RUBY.md §4.1): a Cell borrows statement memory,
  # invalidated by the next `step` and by `close`. Holding one across
    # those is exactly what R2 fuzzes — a Ruby exception, never a segfault.
    with_db do |db|
      500.times { |i| db.exec("CREATE (:S {n: #{i}, t: 'row-#{i}'})") }
      st = db.prepare("MATCH (s:S) RETURN s.n AS n, s.t AS t ORDER BY s.n")
      held = []
      st.each_slice(32) do |batch|
        # Keep every row's cells (as their Ruby values, the way a caller
        # would) past the boundary the next `step` will cross.
        held.concat(batch)
        GC.start
      end
      st.close
      # The values read out are Ruby's own copies — they read correctly
      # after the statement is closed and after a GC, which is the point of
      # materializing per batch rather than borrowing across them.
      assert_equal 500, held.size
      assert_equal [0, "row-0"], held.first
      assert_equal [499, "row-499"], held.last
    end
  end

  def test_holding_a_statement_through_gc_does_not_wedge_the_writer
    # A statement the GC reaps without close holds the engine's reader
    # count forever, and the blocked side is every future write (a reader
    # count that never returns zero parks the writer gate). This is the
    # leak the finalizer exists for; the test forces the GC and then
    # writes, which is the wedge if it regressed.
    Dir.mktmpdir do |dir|
      path = File.join(dir, "gc.glyph")
      db = Glyphes::Database.open(path, create: true)
      10.times { |i| db.exec("CREATE (:A {n: #{i}})") }
      100.times do
        st = db.prepare("MATCH (a:A) RETURN a.n")   # no close, no read
        st.to_a
      end
      GC.start
      GC.start
      # If any leaked statement still held a reader, this write would block
      # forever; a bounded store + the finalizer means it lands.
      db.exec("CREATE (:B {ok: true})")
      assert_equal 11, db.query("MATCH (a:A) RETURN a").count + 1
      db.close
    end
  end

  # ---- Node / Edge views ----------------------------------------------

  def test_a_node_view_reads_without_cypher
    with_db do |db|
      db.exec("CREATE (:Person {name: 'Ana', age: 34})")
      db.exec("CREATE (:Person {name: 'Bo', age: 28})")
      row = db.query("MATCH (p:Person) WHERE p.age = 34 RETURN p").first
      node = row[0]
      assert_instance_of Glyphes::Node, node
      assert_equal "Person", node.label
      assert_equal ["Person"], node.labels
      assert_equal "Ana", node.properties["name"]
      assert_equal 34, node["age"]
      assert node.exist?
      # A view, not a copy: Node.new by id is the same node.
      assert_equal node, Glyphes::Node.new(db, node.id)
      # And it reflects a change made after it was handed out.
      db.exec("MATCH (p:Person {name: 'Ana'}) SET p.name = 'Anna'")
      assert_equal "Anna", node.properties["name"]
    end
  end

  def test_an_edge_view_carries_type_and_endpoints
    with_db do |db|
      # One CREATE, one pattern: both nodes and the relationship in a
      # single pattern (a comma-separated MATCH would be a cartesian
      # product, refused by contract).
      db.exec("CREATE (a:Person {name: 'A'})-[:KNOWS {since: 2020}]->" \
              "(b:Person {name: 'B'})")
      row = db.query("MATCH (a)-[r:KNOWS]->(b) RETURN r").first
      edge = row[0]
      assert_instance_of Glyphes::Edge, edge
      assert_equal "KNOWS", edge.type
      assert_equal "A", edge.src.properties["name"]
      assert_equal "B", edge.dst.properties["name"]
      assert_equal 2020, edge.properties["since"]
    end
  end

  def test_a_node_that_does_not_exist_raises_rather_than_being_empty
    with_db do |db|
      n = Glyphes::Node.new(db, 9999)
      # A deleted node's labels must be distinguishable from a live node
      # that has none: "no labels" and "not there" are different facts.
      assert_raises(Glyphes::SqlError) { n.labels }
      refute n.exist?
    end
  end

  # ---- Statement cursor verbs ------------------------------------------

  def test_statement_count_first_to_a_and_reset
    with_db do |db|
      5.times { |i| db.exec("CREATE (:C {n: #{i}})") }
      st = db.prepare("MATCH (c:C) RETURN c.n AS n ORDER BY n")
      assert_equal 5, st.count          # drains without materializing
      st.close

      st2 = db.prepare("MATCH (c:C) RETURN c.n AS n ORDER BY n")
      assert_equal [0], st2.first        # first, then drained
      st2.close

      st3 = db.prepare("MATCH (c:C) RETURN c.n AS n ORDER BY n")
      assert_equal (0..4).to_a, st3.to_a.flatten
      st3.close

      # reset re-executes: two executions, not a rewind.
      st4 = db.prepare("MATCH (c:C) RETURN c.n AS n ORDER BY n")
      assert_equal 5, st4.to_a.size
      st4.reset
      assert_equal 5, st4.to_a.size
      st4.close
    end
  end

  def test_to_a_is_capped_and_says_so
    with_db do |db|
      50.times { |i| db.exec("CREATE (:C {n: #{i}})") }
      st = db.prepare("MATCH (c:C) RETURN c.n")
      # The cap is a LimitError, not a truncated array that looks complete.
      assert_raises(Glyphes::LimitError) { st.to_a(10) }
      st.close
    end
  end

  # ---- Database durability doors --------------------------------------

  def test_checkpoint_backup_and_vacuum
    Dir.mktmpdir do |dir|
      path = File.join(dir, "d.glyph")
      db = Glyphes::Database.open(path, create: true)
      db.exec("CREATE (:A {n: 1})")
      assert_operator db.wal_size, :>, 0
      db.checkpoint(truncate: true)
      assert_equal 0, db.wal_size        # truncated to the snapshot's lsn
      dest = File.join(dir, "backup.glyph")
      db.backup(dest)
      assert File.exist?(dest)
      db.vacuum
      # The data survives the vacuum's rebuild.
      assert_equal 1, db.query("MATCH (a:A) RETURN a").count
      db.close
    end
  end

  def test_index_settings_survive_a_reopen
    Dir.mktmpdir do |dir|
      path = File.join(dir, "d.glyph")
      db = Glyphes::Database.open(path, create: true)
      db.index_create(kind: :vector, label: "Doc", property: "emb",
                      metric: "l2", m: 32, ef_construction: 300)
      db.index_create(kind: :text, label: "Doc", property: "body",
                      analyzer: "keyword")
      db.exec("CREATE (:Doc {body: 'red blue', emb: [0.1, 0.2]})")
      db.close

      # The sidecar carries the family settings, not just the shape: a
      # vector index reopened as cosine/m16 and a text index reopened as
      # standard both answer *differently*, with no error anywhere.
      sidecar = File.read(path + ".indexes")
      assert_match(/\t1\t32\t300/, sidecar)   # metric l2, m 32, ef 300
      assert_match(/Doc\.body\t1\tDoc\tbody\t0\t1/, sidecar) # keyword

      db2 = Glyphes::Database.open(path)
      assert_equal %w[Doc.body Doc.emb],
                   db2.index_list.map { |i| i["name"] }.sort
      db2.close
    end
  end

  def test_backup_carries_the_index_definitions
    Dir.mktmpdir do |dir|
      path = File.join(dir, "d.glyph")
      db = Glyphes::Database.open(path, create: true)
      db.index_create(kind: :range, label: "User", property: "email",
                      constraint: :unique)
      db.exec("CREATE (:User {email: 'a@x'})")
      dest = File.join(dir, "backup.glyph")
      db.backup(dest)
      db.close

      # A backup without the sidecar is a database with the data and
      # without the indexes — and the uniqueness constraint with it.
      assert File.exist?(dest + ".indexes")
      restored = Glyphes::Database.open(dest)
      assert_equal ["User.email"], restored.index_list.map { |i| i["name"] }
      assert_raises(Glyphes::ConstraintError) do
        restored.exec("CREATE (:User {email: 'a@x'})")
      end
      restored.close
    end
  end

  def test_a_corrupt_sidecar_opens_with_no_indexes_not_no_database
    Dir.mktmpdir do |dir|
      path = File.join(dir, "d.glyph")
      db = Glyphes::Database.open(path, create: true)
      db.index_create(kind: :range, label: "User", property: "email")
      db.exec("CREATE (:User {email: 'a@x'})")
      db.close

      # A torn sidecar (crash mid-write, disk full) must not brick a
      # database whose data is intact: indexes are configuration, and the
      # ordinary answer to "no usable definitions" is "opens without them".
      File.write(path + ".indexes", "GLYIDX01\nUser.email\t0\t0\tgarbage")
      reopened = Glyphes::Database.open(path)
      assert_empty reopened.index_list
      assert_equal 1, reopened.query("MATCH (u:User) RETURN u").count
      # And the registry recovers: a fresh definition lands and persists.
      reopened.index_create(kind: :range, label: "User", property: "email")
      reopened.close
      again = Glyphes::Database.open(path)
      assert_equal ["User.email"], again.index_list.map { |i| i["name"] }
      again.close
    end
  end

  def test_a_memory_database_writes_no_index_sidecar
    # index_create/index_drop write the durable definitions next to the
    # file. For ":memory:" that path is a literal, and the first version
    # wrote a ":memory:.indexes" file into the caller's working directory
    # — a memory database leaking a file is the one thing its contract
    # forbids. Checked in a scratch cwd so the assertion is about the
    # process's behaviour, not this repository's hygiene.
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        db = Glyphes::Database.memory
        db.index_create(kind: :range, label: "A", property: "n")
        db.index_create(kind: :text, label: "A", property: "t")
        db.index_drop("A.n")
        db.close
        assert_empty Dir.glob("*.indexes")
        assert_empty Dir.glob(":memory:*")
      end
    end
  end

  def test_schema_and_stats
    with_db do |db|
      db.exec("CREATE (:Doc {body: 'x'})")
      db.index_create(kind: :text, label: "Doc", property: "body")
      schema = db.schema
      assert_equal ["Doc"], schema["labels"]
      assert_includes schema["properties"], "body"
      assert_equal ["Doc.body"], schema["indexes"].map { |i| i["name"] }
      # Section selection: a host that only wants index names does not pay
      # to walk every property key.
      only_indexes = db.schema(labels: false, properties: false)
      assert_equal ["Doc.body"], only_indexes["indexes"].map { |i| i["name"] }
      assert_nil only_indexes["labels"]
      stats = db.stats
      assert_operator stats["databases"], :>=, 1
    end
  end

  # ---- Vector / cells as classes --------------------------------------

  def test_a_vector_cell_is_a_vector_class_and_a_list_is_an_array
    with_db do |db|
      # A list literal is a list — GLY_LIST crosses as JSON and lands as
      # an Array. The Vector class is for a real vector cell, which a
      # query only produces through a vector-valued property.
      list = db.query("RETURN [0.5, 1.5, 2.5] AS v").first[0]
      assert_instance_of Array, list
      assert_equal [0.5, 1.5, 2.5], list
      assert_equal({ "a" => 1 }, db.query("RETURN {a: 1} AS m").first[0])

      # A vector-valued *property* is written by the engine's vector path,
      # not by the Ruby door (which writes lists) — so the Vector class is
      # verified as the value object it is. The cell it materializes from
      # is GLY_VECTOR, and reading one is exactly this path.
      v = Glyphes::Vector.new([0.5, 1.5, 2.5])
      assert_equal 3, v.size
      assert_equal 1.5, v[1]
      assert_in_delta 4.5, v.dot([1.0, 1.0, 1.0]), 0.001
      assert_equal [0.5, 1.5, 2.5], v.to_a
      assert_equal v, Glyphes::Vector.new([0.5, 1.5, 2.5])
      assert_raises(ArgumentError) { v.dot([1.0]) }   # dimension mismatch
    end
  end
end