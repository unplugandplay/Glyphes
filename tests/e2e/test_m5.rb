# M5.1 gate: the write door, through FFI (ROADMAP.md Phase B, ABI.md
# "mutation without a transaction").
#
# This is the milestone's unlock: the first Ruby call that changes the
# graph. Everything here crosses the C boundary twice — one call to write,
# one to read back — because a write test that never reads is a test of a
# return value, not of a database.
#
# The interesting cases are the ones where the transaction, not the query,
# is the subject: joining an open transaction, rolling one back, and what a
# read-only database says when you try.

require "minitest/autorun"
require "tmpdir"
require_relative "../../lib/glyphes"

class M5Test < Minitest::Test
  def with_db(**opts)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "m5.glyph")
      Glyphes::Database.open(path, create: true, **opts) do |db|
        yield db, path
      end
    end
  end

  def labels_of(db)
    db.query("MATCH (n) RETURN labels(n)[0] AS l ORDER BY l").to_a.map(&:first)
  end

  # ---- what lands ---------------------------------------------------

  def test_create_makes_a_readable_node
    with_db do |db|
      assert_equal 1, db.exec("CREATE (:Person {name: 'Ana', age: 34})")
      rows = db.query("MATCH (n:Person) RETURN n.name AS name, n.age AS age").to_a
      assert_equal [["Ana", 34]], rows
    end
  end

  def test_create_with_a_relationship_reports_three_entities
    with_db do |db|
      n = db.exec("CREATE (a:Person {name: 'Bo'})-[:KNOWS {since: 2024}]->(b:Person {name: 'Cy'})")
      assert_equal 3, n          # two nodes, one relationship
      rows = db.query("MATCH (a:Person)-[r:KNOWS]->(b:Person) RETURN a.name, b.name, r.since").to_a
      assert_equal [["Bo", "Cy", 2024]], rows
    end
  end

  def test_several_patterns_in_one_clause
    with_db do |db|
      assert_equal 3, db.exec("CREATE (:A), (:B), (:C)")
      assert_equal %w[A B C], labels_of(db)
    end
  end

  def test_parameters_bind_in_a_write
    with_db do |db|
      assert_equal 1, db.exec("CREATE (:Doc {title: $t, rev: $r})", { "t" => "Spec", "r" => 3 })
      assert_equal [["Spec", 3]],
                   db.query("MATCH (d:Doc) RETURN d.title, d.rev").to_a
    end
  end

  def test_a_write_can_filter_through_a_read_phase
    with_db do |db|
      db.exec("CREATE (:P {keep: true}), (:P {keep: false}), (:P {keep: true})")
      assert_equal 2, db.exec("MATCH (n:P) WHERE n.keep = true CREATE (:Copy {src: id(n)})")
      assert_equal ["Copy", "Copy"], labels_of(db).select { |l| l == "Copy" }
    end
  end

  # ---- the transaction is the subject -------------------------------

  def test_exec_inside_a_transaction_rolls_back_with_it
    with_db do |db|
      db.exec("CREATE (:Keep)")
      assert_raises(RuntimeError) do
        db.transaction do
          db.exec("CREATE (:Doomed)")
          raise "abort"
        end
      end
      assert_equal ["Keep"], labels_of(db)
    end
  end

  def test_exec_inside_a_transaction_commits_with_it
    with_db do |db|
      db.transaction do
        db.exec("CREATE (:One)")
        db.exec("CREATE (:Two)")
      end
      assert_equal %w[One Two], labels_of(db)
    end
  end

  def test_several_writes_in_one_transaction_are_one_transaction
    with_db do |db|
      generation = db.stat[:generation]
      db.transaction do
        db.exec("CREATE (:A)")
        db.exec("CREATE (:B)")
      end
      # One commit, one generation step: if each exec committed on its own,
      # the generation would have moved twice.
      assert_equal generation + 1, db.stat[:generation]
    end
  end

  # ---- durability ----------------------------------------------------

  def test_committed_writes_survive_a_reopen
    path = nil
    Dir.mktmpdir do |dir|
      path = File.join(dir, "m5.glyph")
      Glyphes::Database.open(path, create: true) do |db|
        db.exec("CREATE (:Persisted {v: 1})")
        db.exec("CREATE (a:X)-[:R]->(b:X)")
      end
      Glyphes::Database.open(path) do |db|
        assert_equal [["Persisted", 1]],
                     db.query("MATCH (n:Persisted) RETURN labels(n)[0], n.v").to_a
        assert_equal 1, db.stat[:edges]
      end
    end
  end

  # ---- refusals ------------------------------------------------------

  def test_a_readonly_database_refuses_a_write
    Dir.mktmpdir do |dir|
      path = File.join(dir, "m5.glyph")
      Glyphes::Database.open(path, create: true) { |db| db.exec("CREATE (:X)") }
      Glyphes::Database.open(path, readonly: true) do |db|
        e = assert_raises(Glyphes::ReadOnlyError) { db.exec("CREATE (:Y)") }
        assert_equal Glyphes::FFI::GLY_ERR_READONLY, e.status
      end
    end
  end

  def test_the_read_door_still_refuses_a_write_by_name
    with_db do |db|
      e = assert_raises(Glyphes::UnsupportedError) { db.prepare("CREATE (:Nope)") }
      assert_equal Glyphes::FFI::GLY_ERR_UNSUPPORTED, e.status
      assert_includes e.message, "CREATE"
    end
  end

  def test_exec_on_a_closed_database_raises
    with_db do |db|
      db.close
      assert_raises(Glyphes::ClosedError) { db.exec("CREATE (:X)") }
    end
  end

  def test_a_syntax_error_in_a_write_is_a_sql_error
    with_db do |db|
      e = assert_raises(Glyphes::SqlError) { db.exec("CREATE (:X") }
      assert_equal Glyphes::FFI::GLY_ERR_SQL, e.status
      # And nothing was written by the failed statement.
      assert_equal [], labels_of(db)
    end
  end

  def test_the_clauses_that_have_not_landed_yet_are_still_refused
    with_db do |db|
      db.exec("CREATE (:X)")
      # FOREACH left this list at M5.7; LOAD CSV is the remaining named
      # refusal, and a refusal by name is a contract rather than a gap.
      { "LOAD CSV FROM 'x' AS line RETURN line" => "LOAD" }.each do |q, word|
        e = assert_raises(Glyphes::UnsupportedError) { db.exec(q) }
        assert_includes e.message, word
      end
    end
  end

  def test_foreach_writes_once_per_element
    with_db do |db|
      db.exec("CREATE (:P {seen: 0})")
      # One row (the one P), two elements: two writes, and the row does
      # not multiply. That is what makes a FOREACH not a rewritten UNWIND.
      assert_equal 2, db.exec("MATCH (n:P) FOREACH (x IN [n, n] | SET x.seen = 1)")
      assert_equal [[1]], db.query("MATCH (n:P) RETURN n.seen").to_a
    end
  end

  def test_foreach_refuses_what_it_does_not_do
    with_db do |db|
      db.exec("CREATE (:P)")
      # The element has to be writable.
      e = assert_raises(Glyphes::SqlError) do
        db.exec("MATCH (n:P) FOREACH (x IN [1] | SET x.seen = 1)")
      end
      assert_includes e.message, "FOREACH's element"
      # And CREATE/DELETE inside are refused by name, as openCypher does.
      e = assert_raises(Glyphes::SqlError) do
        db.exec("MATCH (n:P) FOREACH (x IN [n] | CREATE (:Q))")
      end
      assert_includes e.message, "SET or REMOVE"
    end
  end

  # ---- M5.2: SET, REMOVE, DELETE ----------------------------------------

  def test_set_and_remove_change_properties
    with_db do |db|
      db.exec("CREATE (:P {name: 'Ana', age: 34, city: 'Lyon'})")
      assert_equal 1, db.exec("MATCH (n:P) SET n.age = n.age + 1")
      assert_equal 1, db.exec("MATCH (n:P) REMOVE n.city")
      rows = db.query("MATCH (n:P) RETURN n.name, n.age, n.city").to_a
      assert_equal [["Ana", 35, nil]], rows
    end
  end

  def test_set_merge_and_replace_are_different_operations
    with_db do |db|
      db.exec("CREATE (:P {keep: 1, drop: 2})")
      db.exec("MATCH (n:P) SET n += {added: 3}")
      assert_equal 3, db.query("MATCH (n:P) RETURN keys(n) AS k").first.first.size
      db.exec("MATCH (n:P) SET n = {only: 9}")
      assert_equal [["only", 9]], db.query("MATCH (n:P) RETURN keys(n)[0], n.only").to_a
    end
  end

  def test_a_set_of_null_removes_the_property
    with_db do |db|
      db.exec("CREATE (:P {x: 1, y: 2})")
      db.exec("MATCH (n:P) SET n.y = null")
      assert_equal [[["x"]]], db.query("MATCH (n:P) RETURN keys(n) AS k").to_a
    end
  end

  def test_delete_refuses_a_connected_node_and_detach_takes_it
    with_db do |db|
      db.exec("CREATE (a:X)-[:R]->(b:X)")
      e = assert_raises(Glyphes::ConstraintError) { db.exec("MATCH (a:X) DELETE a") }
      assert_includes e.message, "DETACH"
      # The refusal changed nothing.
      assert_equal 2, db.stat[:nodes]
      ## Two nodes and the edge between them: the count is entities, and
      ## DETACH's cascade is part of what it removed.
      assert_equal 3, db.exec("MATCH (n:X) DETACH DELETE n")
      assert_equal 0, db.stat[:nodes]
      assert_equal 0, db.stat[:edges]
    end
  end

  def test_a_transaction_sees_its_own_writes
    with_db do |db|
      ## The shape every write workflow needs: create, then find it again in
      ## the same transaction and change it. It worked from M5.1 for `CREATE`
      ## but not for anything that *matched* — reads consulted only the
      ## published snapshot, so the second statement found nothing.
      db.transaction do
        db.exec("CREATE (:P {v: 1})")
        assert_equal 1, db.exec("MATCH (n:P) SET n.v = 42")
        assert_equal 1, db.exec("MATCH (n:P) REMOVE n.v")
      end
      ## The node is still there — a REMOVE takes the property, not the node —
      ## and its `v` reads null.
      assert_equal [[nil]], db.query("MATCH (n:P) RETURN n.v AS v").to_a
    end
  end

  def test_a_relationship_written_and_read_in_one_transaction
    with_db do |db|
      db.transaction do
        db.exec("CREATE (a:X)-[:R {w: 1}]->(b:X)")
        assert_equal 1, db.exec("MATCH (a:X)-[r:R]->(b:X) SET r.w = 2")
      end
      assert_equal [[2]], db.query("MATCH ()-[r:R]->() RETURN r.w AS w").to_a
    end
  end

  def test_a_node_cannot_be_stored_as_a_property
    with_db do |db|
      db.exec("CREATE (a:X)-[:R]->(b:X)")
      ## A type error in the caller's query, so it gets a named status rather
      ## than GLY_ERR — which Ruby maps to InternalError, i.e. "our bug".
      e = assert_raises(Glyphes::SqlError) { db.exec("MATCH (a:X)-[:R]->(b) SET a.copy = b") }
      assert_includes e.message, "vkNode"
    end
  end

  def test_an_anonymous_pattern_traverses
    with_db do |db|
      db.exec("CREATE (a:X {k: 1})-[:R {w: 5}]->(b:X)")
      db.exec("CREATE (c:X {k: 2})-[:R {w: 7}]->(d:X)")
      ## `MATCH ()-[:R]->()` bound nothing at M4 and silently answered one
      ## empty row. The SET below is what found it.
      assert_equal [[5], [7]], db.query("MATCH ()-[r:R]->() RETURN r.w AS w ORDER BY w").to_a
      assert_equal 2, db.exec("MATCH ()-[r:R]->() SET r.w = 6")
    end
  end

  # ---- M5.3: MERGE ------------------------------------------------------

  def test_merge_creates_once_and_then_matches
    with_db do |db|
      assert_equal 1, db.exec("MERGE (n:Person {name: 'Ana'})")
      assert_equal 0, db.exec("MERGE (n:Person {name: 'Ana'})")
      assert_equal 1, db.query("MATCH (n:Person) RETURN n.name").to_a.size
    end
  end

  def test_merge_of_a_relationship_is_all_or_nothing
    with_db do |db|
      assert_equal 3, db.exec("MERGE (a:P {n: 'a'})-[:R]->(b:P {n: 'b'})")
      assert_equal 0, db.exec("MERGE (a:P {n: 'a'})-[:R]->(b:P {n: 'b'})")
      assert_equal 1, db.stat[:edges]
      assert_equal 2, db.stat[:nodes]
    end
  end

  def test_merge_sees_what_this_transaction_created
    with_db do |db|
      ## The reason M5.2's transactional visibility was a prerequisite: a
      ## MERGE whose match half cannot see the transaction's own writes
      ## creates a duplicate per row, which is the opposite of MERGE.
      db.transaction do
        db.exec("MERGE (n:Seq {i: 1})")
        db.exec("MERGE (n:Seq {i: 1})")
        db.exec("MERGE (n:Seq {i: 2})")
      end
      assert_equal 2, db.query("MATCH (n:Seq) RETURN n").to_a.size
    end
  end

  def test_on_create_and_on_match_run_on_their_own_branches
    with_db do |db|
      db.exec("MERGE (n:T {k: 1}) ON CREATE SET n.made = 1 ON MATCH SET n.seen = 1")
      db.exec("MERGE (n:T {k: 1}) ON CREATE SET n.made = 2 ON MATCH SET n.seen = 2")
      assert_equal [[1, 2]], db.query("MATCH (n:T) RETURN n.made, n.seen").to_a
    end
  end

  def test_merge_under_a_match_is_constrained_to_the_matched_node
    with_db do |db|
      db.exec("CREATE (a1:P {n: 'a1'})-[:R]->(b1:P {n: 'b1'})")
      db.exec("CREATE (a2:P {n: 'a2'})-[:R]->(b2:P {n: 'b2'})")
      ## If the match half ignored the bound variable, this would match a2's
      ## relationship and bind the wrong node.
      db.exec("MATCH (a:P {n: 'a1'}) MERGE (a)-[:R]->(fresh:P {n: 'fresh'})")
      assert_equal [["fresh"]], db.query("MATCH (n:P {n: 'fresh'}) RETURN n.n").to_a
      assert_equal 3, db.query("MATCH (a:P)-[r:R]->(b:P) RETURN b.n").to_a.size
    end
  end

  def test_label_and_nested_writes_are_refused_with_a_reason
    with_db do |db|
      db.exec("CREATE (:P)")
      # One label per node (pin C13) — the parse says so rather than
      # accepting and doing nothing.
      e = assert_raises(Glyphes::SqlError) { db.exec("MATCH (n:P) SET n:Admin") }
      assert_includes e.message, "one label"
      e = assert_raises(Glyphes::SqlError) { db.exec("MATCH (n:P) SET n.m.k = 1") }
      assert_includes e.message, "nested"
      e = assert_raises(Glyphes::SqlError) { db.exec("MATCH (n:P) SET n = 3") }
      assert_includes e.message, "map"
    end
  end
  # ---------------------------------------------------------------- M5.4
  #
  # Aggregates through the Ruby seam: the value crosses as a JSON cell, so
  # what these pin is that an integer aggregate arrives as an integer and a
  # collect arrives as a *list* rather than as a stringified stand-in.

  def test_count_arrives_as_a_number_and_count_of_a_property_skips_nulls
    with_db do |db|
      db.exec("CREATE (:P {v: 1}), (:P {v: 2}), (:P)")
      assert_equal 3, db.query("MATCH (n:P) RETURN count(*) AS c").to_a.first[0]
      assert_equal 2, db.query("MATCH (n:P) RETURN count(n.v) AS c").to_a.first[0]
      ## No MATCH at all: a global aggregation over an empty input is still
      ## one row, and it is zero.
      assert_equal 0, db.query("RETURN count(*) AS c").to_a.first[0]
    end
  end

  def test_group_by_comes_back_as_one_row_per_key
    with_db do |db|
      db.exec("CREATE (:P {k: 'a', v: 1}), (:P {k: 'a', v: 3}), (:P {k: 'b', v: 5})")
      rows = db.query("MATCH (n:P) RETURN n.k AS k, count(*) AS c ORDER BY k").to_a
      assert_equal [["a", 2], ["b", 1]], rows
    end
  end

  def test_sum_keeps_its_type_and_collect_returns_a_list
    with_db do |db|
      db.exec("CREATE (:P {v: 1}), (:P {v: 2})")
      assert_equal 3, db.query("MATCH (n:P) RETURN sum(n.v) AS s").to_a.first[0]
      ## An integer sum that arrived as 3.0 would be a type bug the caller
      ## cannot see through a JSON cell.
      assert_equal 1.5, db.query("MATCH (n:P) RETURN avg(n.v) AS a").to_a.first[0]
      homes = db.query("MATCH (n:P) RETURN collect(n.v) AS vs").to_a.first[0]
      assert_equal [1, 2], homes
      assert_instance_of Array, homes
    end
  end

  def test_an_aggregate_in_where_is_refused_rather_than_silently_false
    with_db do |db|
      db.exec("CREATE (:P), (:P)")
      ## UnsupportedError, not SqlError: the query is well-formed and the
      ## clause is not in the 0.1 contract — the same class as the other
      ## planned-away constructs, which is what makes it distinguishable from
      ## a query that is merely wrong.
      e = assert_raises(Glyphes::UnsupportedError) do
        db.query("MATCH (n:P) WHERE count(n) > 1 RETURN n")
      end
      assert_equal Glyphes::FFI::GLY_ERR_UNSUPPORTED, e.status
      assert_includes e.message, "aggregate"
      ## …and sum of strings, which is a different refusal for a different
      ## reason: the values exist, they just cannot be folded.
      db.exec("CREATE (:Q {s: 'x'})")
      e = assert_raises(Glyphes::SqlError) { db.query("MATCH (n:Q) RETURN sum(n.s) AS s") }
      assert_includes e.message, "numbers"
    end
  end

  def test_with_is_a_grouping_boundary_the_next_clause_can_filter_on
    with_db do |db|
      db.exec("CREATE (:P {k: 'a'}), (:P {k: 'a'}), (:P {k: 'b'})")
      rows = db.query("MATCH (n:P) WITH n.k AS k, count(*) AS c WHERE c > 1 RETURN k").to_a
      assert_equal [["a"]], rows
    end
  end
  # ---------------------------------------------------------------- M5.5
  #
  # The two joins that answer for what is *missing*: a walk that may not
  # exist, and a left side that survives not finding one. Both arrive
  # through the seam, so what is pinned here is the shape of the value — a
  # path binding is a list, a null side is a real null and not an absent
  # cell.

  def test_a_variable_length_binds_the_whole_walk_as_a_list
    with_db do |db|
      db.exec("CREATE (a:P {n: 'a'})-[:R]->(b:P {n: 'b'})-[:R]->(c:P {n: 'c'})")
      rows = db.query("MATCH (x:P {n: 'a'})-[r*2..2]->(y) RETURN y.n AS y, size(r) AS len").to_a
      assert_equal [["c", 2]], rows
      ## Every walk is a row, not every endpoint: a two-hop walk and a one-hop
      ## walk to the same node are two paths and two rows.
      assert_equal 2, db.query("MATCH (x:P {n: 'a'})-[*1..2]->(y:P) RETURN y.n AS y").to_a.size
    end
  end

  def test_a_walk_never_uses_the_same_relationship_twice
    with_db do |db|
      ## A cycle, which is the case where the rule matters: without it the
      ## walk never ends.
      db.exec("CREATE (a:C {n: 'a'}), (b:C {n: 'b'}), (c:C {n: 'c'})")
      db.exec("MATCH (x:C {n: 'a'}) CREATE (x)-[:R]->(:C {n: 'b'})")
      db.exec("MATCH (x:C {n: 'b'}) CREATE (x)-[:R]->(:C {n: 'c'})")
      ## And back to a, which is what makes the walk able to return to where
      ## it started — a node may repeat, the edge may not.
      db.exec("MATCH (x:C {n: 'c'}) CREATE (x)-[:R]->(:C {n: 'a'})")
      assert_equal 3, db.query("MATCH (x:C {n: 'a'})-[*]->(y) RETURN count(*) AS c").to_a.first[0]
    end
  end

  def test_optional_match_keeps_the_left_row_and_nulls_the_right
    with_db do |db|
      db.exec("CREATE (a:P {n: 'a'})-[:R]->(b:P {n: 'b'})")
      db.exec("CREATE (c:P {n: 'c'})")
      ## b has an :R edge *into* it and none out of it, which is a different
      ## thing: the pattern is (p)-[:R]->(q), so b is on the null side too.
      rows = db.query("MATCH (p:P) OPTIONAL MATCH (p)-[:R]->(q) RETURN p.n AS p, q.n AS q ORDER BY p").to_a
      assert_equal [["a", "b"], ["b", nil], ["c", nil]], rows
    end
  end

  def test_the_null_side_survives_a_with_where_and_finds_the_orphans
    with_db do |db|
      db.exec("CREATE (a:P {n: 'a'})-[:R]->(b:P {n: 'b'})")
      db.exec("CREATE (c:P {n: 'c'})")
      rows = db.query("MATCH (p:P) OPTIONAL MATCH (p)-[:R]->(q) " \
                      "WITH p, q WHERE q IS NULL RETURN p.n AS p ORDER BY p").to_a
      assert_equal [["b"], ["c"]], rows
    end
  end

  def test_its_unsupported_shapes_are_refused_by_name
    with_db do |db|
      db.exec("CREATE (:P)")
      e = assert_raises(Glyphes::UnsupportedError) { db.query("OPTIONAL MATCH (a) RETURN a.n") }
      assert_includes e.message, "left"
      e = assert_raises(Glyphes::UnsupportedError) do
        db.query("MATCH (a:P) OPTIONAL MATCH (a)-->(b) OPTIONAL MATCH (b)-->(c) RETURN a.n")
      end
      assert_includes e.message, "second"
    end
  end
  # ---------------------------------------------------------------- M6.1
  #
  # The index through the seam: create it, watch a query's answer not
  # change, and check the registry says what it should. What is *not* here
  # is a timing claim — a fast query and an unused index look the same from
  # Ruby, so the gate lives in the Nim benchmark.

  def test_an_index_changes_no_answer
    with_db do |db|
      100.times { |i| db.exec("CREATE (:Person {age: #{i % 10}, name: 'p#{i}'})") }
      before = db.query("MATCH (n:Person) WHERE n.age > 6 RETURN n.name AS name ORDER BY name").to_a
      db.index_create(kind: :range, label: "Person", property: "age")
      after = db.query("MATCH (n:Person) WHERE n.age > 6 RETURN n.name AS name ORDER BY name").to_a
      assert_equal before, after
      assert_equal 30, after.size
      ## A point lookup, the case the index is for.
      assert_equal 10, db.query("MATCH (n:Person) WHERE n.age = 3 RETURN n.name AS name").to_a.size
      ## …and one that matches nothing, which must be nothing and not
      ## "everything, because the index was empty".
      assert_equal [], db.query("MATCH (n:Person) WHERE n.age = 99 RETURN n.name AS name").to_a
    end
  end

  def test_a_write_reaches_the_index
    with_db do |db|
      db.exec("CREATE (:Person {age: 30})")
      db.index_create(kind: :range, label: "Person", property: "age")
      assert_equal 1, db.query("MATCH (n:Person) WHERE n.age = 30 RETURN n").to_a.size
      db.exec("MATCH (n:Person) SET n.age = 31")
      assert_equal 0, db.query("MATCH (n:Person) WHERE n.age = 30 RETURN n").to_a.size
      assert_equal 1, db.query("MATCH (n:Person) WHERE n.age = 31 RETURN n").to_a.size
      db.exec("MATCH (n:Person) DELETE n")
      ## Pin I11: a deleted node is never returned by an index, and the
      ## delete is visible to the very next statement.
      assert_equal 0, db.query("MATCH (n:Person) WHERE n.age = 31 RETURN n").to_a.size
    end
  end

  def test_the_registry_is_visible_and_a_rebuild_refills
    with_db do |db|
      10.times { |i| db.exec("CREATE (:Doc {n: #{i}})") }
      db.index_create(kind: :range, label: "Doc", property: "n")
      listed = db.index_list
      assert_equal 1, listed.size
      assert_equal "Doc.n", listed[0]["name"]
      assert_equal 10, listed[0]["entries"]
      db.index_rebuild("Doc.n")
      assert_equal 10, db.index_list[0]["entries"]
      db.index_drop("Doc.n")
      assert_equal [], db.index_list
    end
  end

  def test_an_index_kind_that_is_not_built_says_so
    with_db do |db|
      db.exec("CREATE (:Doc {n: 1})")
      # All three families exist now (M6.1 range, M6.2 text, M6.3 vector);
      # what is refused is a kind the engine has never heard of. The Ruby
      # surface validates symbols client-side, so this goes through the
      # FFI with a raw kind to prove the engine refuses it too.
      e = assert_raises(Glyphes::Error) do
        Glyphes::Guard.check!(
          Glyphes::FFI::glyphes_index_create(db.handle, 9,
                                             JSON.generate({"property" => "x"})),
          "index_create")
      end
      assert_includes e.message, "unknown index kind"
    end
  end

  def test_a_text_index_round_trips_through_the_ffi
    with_db do |db|
      db.exec("CREATE (:Doc {body: 'the quick brown fox'})")
      db.exec("CREATE (:Doc {body: 'the lazy dog sleeps'})")
      name = db.index_create(kind: :text, label: "Doc", property: "body",
                             analyzer: "standard")
      assert_equal "Doc.body", name
      names = db.index_list.map { |d| d["name"] }
      assert_includes names, "Doc.body"
      # Rebuilding a text index through the ABI refills it from the store.
      db.index_rebuild("Doc.body")
      entry = db.index_list.find { |d| d["name"] == "Doc.body" }
      assert_equal 2, entry["entries"]
    end
  end

  def test_an_unknown_analyzer_is_refused_through_the_ffi
    with_db do |db|
      e = assert_raises(Glyphes::Error) do
        db.index_create(kind: :text, label: "Doc", property: "body",
                        analyzer: "klingon")
      end
      assert_includes e.message, "unknown analyzer"
    end
  end

  # A bare `CALL ... YIELD` is a complete statement, and its answer is the
  # columns it yields. The planner filled `columns` only from a projection,
  # so the bare form planned a correct operator and then described the
  # answer as zero columns — rows came back empty through Ruby, for text and
  # for vector alike. Every retrieval test before this one ended in RETURN,
  # which is why it survived: the RETURN supplied the names.
  def test_a_bare_retrieval_reports_the_columns_it_yields
    with_db do |db|
      db.exec("CREATE (:Doc {body: 'the quick brown fox', t: [0.1, 0.2, 0.3]})")
      db.exec("CREATE (:Doc {body: 'quick brown', t: [0.9, 0.1, 0.1]})")
      db.index_create(kind: :text, label: "Doc", property: "body")
      db.index_create(kind: :vector, label: "Doc", property: "t", dim: 3, metric: :cosine)

      res = db.query("CALL db.idx.text('Doc.body') AGAINST $q YIELD doc, score",
                     q: "quick")
      assert_equal %w[doc score], res.columns
      assert_equal 2, res.count
      assert res.to_a.all? { |r| r[1].is_a?(Float) }

      res2 = db.query("CALL db.idx.vector('Doc.t') AGAINST $q YIELD doc, score",
                      q: [0.1, 0.2, 0.3])
      assert_equal %w[doc score], res2.columns
      assert_equal 2, res2.count
      ## The identical vector scores ~1.0 against itself on cosine. Not
      ## exactly 1.0: vectors are stored float32, so the dot product of a
      ## vector with itself rounds. A 1e-9 tolerance here would be testing
      ## float64 against a float32 store.
      assert_in_delta 1.0, res2.to_a.first.last, 1e-5

      ## A projection still names the answer; the two must not double up.
      res3 = db.query("CALL db.idx.text('Doc.body') AGAINST $q YIELD doc, score " \
                      "RETURN doc", q: "quick")
      assert_equal %w[doc], res3.columns
      assert_equal 2, res3.count
    end
  end

  def test_a_retrievals_yielded_names_are_in_scope_for_what_follows
    with_db do |db|
      3.times do |i|
        db.exec("CREATE (:Doc {body: 'shared word', t: $t})",
                "t" => [i * 0.3, 0.1, 0.1])
      end
      db.index_create(kind: :text, label: "Doc", property: "body")
      db.index_create(kind: :vector, label: "Doc", property: "t", dim: 3, metric: :cosine)

      ## WITH resolves the yielded name — it used to be refused as undefined.
      res = db.query("CALL db.idx.text('Doc.body') AGAINST $q YIELD doc, score " \
                     "WITH score RETURN score", q: "shared")
      assert_equal %w[score], res.columns
      assert_equal 3, res.count

      ## So does WHERE on the pushed-down filter.
      res2 = db.query("CALL db.idx.text('Doc.body') AGAINST $q YIELD doc, score " \
                      "WHERE score > 0 RETURN score", q: "shared")
      assert_equal 3, res2.count

      ## And ORDER BY, which resolves a bare name against the answer's shape.
      res3 = db.query("CALL db.idx.vector('Doc.t') AGAINST $q YIELD doc, score " \
                      "WITH score ORDER BY score RETURN score", q: [0.1, 0.1, 0.1])
      scores = res3.to_a.map(&:last)
      assert_equal 3, scores.length
      assert_equal scores.sort, scores, "ORDER BY did not order"
    end
  end

  def test_a_text_search_scores_through_the_query_door
    with_db do |db|
      db.exec("CREATE (:Doc {body: 'the quick brown fox jumps'})")
      db.exec("CREATE (:Doc {body: 'the quick brown fox is quick and brown'})")
      db.index_create(kind: :text, label: "Doc", property: "body")
      rows = db.query(
        "CALL db.idx.text('Doc.body') AGAINST $q YIELD doc, score " \
        "RETURN doc, score", q: "quick")
      assert_equal 2, rows.count
      # Twice in a document scores higher, and the order is the answer.
      scores = rows.to_a.map { |r| r[1] }
      assert scores[0] > scores[1]
      assert_instance_of Float, scores[0]
    end
  end

  def test_a_unique_constraint_fails_the_write_and_names_the_value
    with_db do |db|
      db.exec("CREATE (:User {email: 'a@x'})")
      db.index_create(kind: :range, label: "User", property: "email",
                      constraint: :unique)
      e = assert_raises(Glyphes::ConstraintError) do
        db.exec("CREATE (:User {email: 'a@x'})")
      end
      assert_includes e.message, "unique"
      assert_includes e.message, "a@x"
      # The refused write committed nothing.
      assert_equal 1, db.query("MATCH (n:User) RETURN n").count
    end
  end

  def test_an_exists_constraint_refuses_a_missing_property
    with_db do |db|
      db.index_create(kind: :range, label: "User", property: "email",
                      constraint: :exists)
      e = assert_raises(Glyphes::ConstraintError) do
        db.exec("CREATE (:User {name: 'a'})")
      end
      assert_includes e.message, "has no email"
    end
  end

  def test_a_vector_search_scores_through_the_query_door
    with_db do |db|
      # A JSON array parameter is a list of numbers; the vector index
      # accepts it as the query vector, which is what makes the Ruby
      # surface able to pass embeddings without a second type.
      db.exec("CREATE (:Doc {embedding: $v})",
              v: [1.0, 0.0, 0.0])
      db.exec("CREATE (:Doc {embedding: $v})",
              v: [0.0, 1.0, 0.0])
      db.exec("CREATE (:Doc {embedding: $v})",
              v: [0.92, 0.1, 0.0])
      db.index_create(kind: :vector, label: "Doc", property: "embedding")
      rows = db.query(
        "CALL db.idx.vector('Doc.embedding') AGAINST $q YIELD doc, score " \
        "RETURN doc, score", q: [0.95, 0.05, 0.0])
      assert_equal 3, rows.count
      scores = rows.to_a.map { |r| r[1] }
      # Best first, and the near-duplicate of the query tops it.
      assert scores[0] > scores[1]
      assert scores[1] > scores[2]
      assert_instance_of Float, scores[0]
    end
  end

  def test_a_vector_search_with_a_pushed_filter_answers_only_live_rows
    with_db do |db|
      db.exec("CREATE (:Doc {embedding: $v, year: 2020})",
              v: [1.0, 0.0, 0.0])
      db.exec("CREATE (:Doc {embedding: $v, year: 2024})",
              v: [0.9, 0.1, 0.0])
      db.index_create(kind: :vector, label: "Doc", property: "embedding")
      rows = db.query(
        "CALL db.idx.vector('Doc.embedding') AGAINST $q YIELD doc, score " \
        "WHERE doc.year = 2024 RETURN doc, score", q: [0.95, 0.05, 0.0])
      assert_equal 1, rows.count
    end
  end

  def test_an_unknown_metric_is_refused_through_the_ffi
    with_db do |db|
      e = assert_raises(Glyphes::Error) do
        db.index_create(kind: :vector, label: "Doc", property: "embedding",
                        metric: "manhattan")
      end
      assert_includes e.message, "unknown metric"
    end
  end

  def test_ef_construction_below_200_is_refused_through_the_ffi
    with_db do |db|
      e = assert_raises(Glyphes::Error) do
        db.index_create(kind: :vector, label: "Doc", property: "embedding",
                        ef_construction: 50)
      end
      assert_includes e.message, "ef_construction"
    end
  end

  def test_two_indexes_cannot_share_a_name
    with_db do |db|
      db.index_create(kind: :range, label: "Doc", property: "body")
      # One name, one index (INDEX.md §1). A second family over the same
      # name used to make a shadow definition that `index_list` reported
      # twice and `index_drop` removed at random.
      e = assert_raises(Glyphes::SqlError) do
        db.index_create(kind: :text, label: "Doc", property: "body")
      end
      assert_includes e.message, "one name, one index"
    end
  end

  def test_an_index_and_its_constraint_survive_a_reopen
    # Its own tmpdir: this test closes and reopens handles by path, which
    # the block form of `with_db` (which owns the handle) is not for.
    Dir.mktmpdir do |dir|
      path = File.join(dir, "reopen.glyph")
      db = Glyphes::Database.open(path, create: true)
      db.exec("CREATE (:User {email: 'a@x'})")
      db.index_create(kind: :range, label: "User", property: "email",
                      constraint: :unique)
      db.close

      db2 = Glyphes::Database.open(path)
      assert_equal ["User.email"], db2.index_list.map { |d| d["name"] }
      # The constraint is enforced again: it is part of the definition,
      # rebuilt against the index the reopen rebuilt from live records.
      assert_raises(Glyphes::ConstraintError) do
        db2.exec("CREATE (:User {email: 'a@x'})")
      end
      # And the rebuilt index answers — it is not a name with no content.
      assert_equal 1, db2.query("MATCH (u:User) WHERE u.email = 'a@x' RETURN u").count
      db2.index_drop("User.email")
      db2.close

      db3 = Glyphes::Database.open(path)
      assert_empty db3.index_list
      db3.close
    end
  end

  # A read inside `db.transaction` sees what that transaction wrote. This is
  # the Ruby half of pin C4: the engine always had it (the delta seek index
  # exists to serve exactly this), but `query` and `prepare` passed `nil` for
  # the writer while `exec` joined, so a read in the middle of a transaction
  # answered from a snapshot that predated every write in it. Every read
  # returned nothing, not just reads after a DELETE — which is how this was
  # originally misdiagnosed as a DETACH DELETE defect.
  def test_a_read_inside_a_transaction_sees_its_own_writes
    db = Glyphes::Database.memory
    db.transaction do
      db.exec("CREATE (:N {n: 'a'})")
      db.exec("CREATE (:N {n: 'b'})")
      db.exec("CREATE (:N {n: 'c'})")
      # Both edges leave `a`, so deleting `b` must take `a->b` and leave
      # `a->c` — the case where a cascade that over-reaches is visible.
      %w[b c].each do |dst|
        db.exec("MATCH (x:N {n: 'a'}) MERGE (y:N {n: $t}) CREATE (x)-[:R]->(y)",
                { "t" => dst })
      end

      assert_equal %w[a b c],
                   db.query("MATCH (x:N) RETURN x.n AS n ORDER BY n").flat_map { |r| r }
      assert_equal %w[b c],
                   db.query("MATCH (:N {n: 'a'})-[r:R]->(y:N) RETURN y.n AS n ORDER BY n")
                       .flat_map { |r| r }

      db.exec("MATCH (b:N {n: 'b'}) DETACH DELETE b")

      # The deleted node is gone and the edge that went with it, and the
      # survivor is still there — all inside the same transaction.
      assert_equal %w[a c],
                   db.query("MATCH (x:N) RETURN x.n AS n ORDER BY n").flat_map { |r| r }
      assert_equal %w[c],
                   db.query("MATCH (:N {n: 'a'})-[r:R]->(y:N) RETURN y.n AS n")
                       .flat_map { |r| r }
      assert_empty db.query("MATCH (x:N {n: 'b'}) RETURN x")
    end
    # Committed, and the same answers.
    assert_equal %w[a c],
                 db.query("MATCH (x:N) RETURN x.n AS n ORDER BY n").flat_map { |r| r }
    db.close
  end

  def test_a_read_outside_a_transaction_still_does_not_take_the_writer_lock
    db = Glyphes::Database.memory
    db.exec("CREATE (:N {n: 'x'})")
    # A read with no open transaction must not *begin* one. If it did, a
    # query would take the writer lock and two readers would collide.
    threads = 4.times.map do
      Thread.new { 20.times { db.query("MATCH (n:N) RETURN n.n AS v").to_a } }
    end
    threads.each(&:join)
    db.close
  end

  def test_a_model_read_inside_a_transaction_sees_its_own_writes
    db = Glyphes::Database.memory
    klass = Class.new(Glyph::Base) do
      def self.name = "Thing"
    end
    klass.store = db
    db.transaction do
      klass.create!(n: 1)
      klass.create!(n: 2)
      ## `where` goes through `db.query`, which is the path that used to be
      ## blind. The model layer is where a user would notice first.
      assert_equal 2, klass.where({}).to_a.size
    end
    db.close
  end
end
