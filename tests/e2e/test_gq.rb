# The GLYPH QUERY doors, through FFI (PRD-GLYPH-QUERY.md, ABI.md §2).
#
# The Nim suite (tests/unit/test_gq.nim) drives the doors from inside the
# engine; this file drives them the way a host does — compile, prepare,
# step, close — and it is the only place the *Ruby* side of the doors is
# proved at all. A door that works in Nim and not in Ruby is a door that
# only half exists.
#
# The fixture is the same one the M4 suite uses: written by the real Nim
# write path, so what the guest sees is what the engine wrote.

require "minitest/autorun"
require "tmpdir"
require_relative "../../lib/glyphes"

class GqTest < Minitest::Test
  FIXTURE = File.expand_path("../fixtures/social.glyph", __dir__)

  def setup
    unless File.exist?(FIXTURE) || File.exist?(FIXTURE + "-wal")
      skip "no fixture — run `nimble fixture` (or `nimble gemtest`)"
    end
    @db = Glyphes::Database.open(FIXTURE, readonly: true)
  end

  def teardown
    @db.close unless @db.closed?
  end

  def test_compile_returns_the_cypher_and_the_parameters
    cypher, params = @db.gq_compile("find Person where age > 30")
    assert_equal "MATCH (n:Person) WHERE n.age > 30 RETURN id(n) AS id", cypher
    assert_equal "{}", params
  end

  def test_compile_puts_a_literal_in_a_parameter
    cypher, params = @db.gq_compile('add person {name "Ada"}')
    assert_equal "CREATE (n:person {name: $p1}) RETURN id(n) AS id", cypher
    assert_equal '{"p1":"Ada"}', params
  end

  def test_a_value_never_reaches_the_query_text
    cypher, = @db.gq_compile('add Person {name "Ada\\"; DROP"}')
    refute_includes cypher, "DROP"
  end

  def test_a_prepared_gq_statement_returns_the_rows
    st = @db.gq("find Person")
    ids = st.to_a.map { |row| row.first.to_i }
    refute_empty ids
    st.close
  end

  def test_the_link_door_writes_one_edge
    ## The one write GLYPH QUERY cannot express: two *existing* nodes.
    ## It needs a writable database of its own, so it makes one.
    Dir.mktmpdir do |dir|
      path = File.join(dir, "link.glyph")
      db = Glyphes::Database.open(path, create: true)
      begin
        db.exec("CREATE (a:Person) RETURN id(a) AS id")
        db.exec("CREATE (b:Person) RETURN id(b) AS id")
        ids = db.query("MATCH (n:Person) RETURN id(n) AS id").to_a.map { |r| r.first.to_i }
        assert_equal 2, ids.size
        edge = db.link(ids[0], "KNOWS", ids[1])
        assert_operator edge, :>, 0
        # The edge is there: the follow finds the far end.
        followed = db.query("MATCH (a:Person)-[:KNOWS]->(b) RETURN id(b) AS id").to_a
        assert_equal [ids[1]], followed.map { |r| r.first.to_i }
      ensure
        db.close
      end
    end
  end

  def test_the_link_door_refuses_a_missing_node_by_name
    Dir.mktmpdir do |dir|
      path = File.join(dir, "missing.glyph")
      db = Glyphes::Database.open(path, create: true)
      begin
        db.exec("CREATE (a:Person) RETURN id(a) AS id")
        id = db.query("MATCH (n:Person) RETURN id(n) AS id").to_a.first.first.to_i
        error = assert_raises(Glyphes::Error) { db.link(id, "KNOWS", 999_999) }
        assert_match(/999999/, error.message)
      ensure
        db.close
      end
    end
  end

  def test_the_doors_refuse_what_is_not_a_query
    error = assert_raises(Glyphes::Error) { @db.gq("labels") }
    assert_match(/schema/, error.message)
    error = assert_raises(Glyphes::Error) { @db.gq("link $a KNOWS $b") }
    assert_match(/glyphes_link/, error.message)
  end
end
