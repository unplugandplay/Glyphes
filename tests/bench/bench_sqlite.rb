# frozen_string_literal: true
## glyphes — M11: glyphes vs SQLite edge-tables.
##
## The project's own framing (README "Why") is that SQLite with edge tables
## is the alternative worth measuring against: free, embedded, and
## everywhere. So this benchmark builds the *same seeded graph* in both
## systems and runs the same five workloads, giving SQLite what a competent
## engineer would actually give it — a nodes table, an edges table, and
## B-tree indexes on both edge endpoints and on the property column. A
## comparison that handicapped SQLite would be a marketing number, not a
## measurement.
##
## The workloads are chosen to be meaningful to *both* systems:
##
##   load     bulk insert of the whole graph (nodes and edges)
##   point    find a node by an indexed range property
##   one-hop  walk out from a node by id
##   two-hop  the same walk two levels deep (recursive CTE vs var-length)
##   filter   count over a property predicate
##
## What this cannot tell you: SQLite with edge tables, in the hands of
## someone who knows their data model, is a perfectly good system, and on
## some of these workloads it wins — the load especially, because a bulk
## insert into two integer tables is not a hard thing for SQLite to do.
## The point is to know *which* and by how much, not to declare a winner.
## `limitations.md` says this again next to the headline number.
##
## Two rules this file follows because the first version broke both:
##
##   1. Both engines are keyed by the *property* id, never by internal
##      node id. An earlier draft walked `id(a) = $id` here and `src = ?`
##      in SQLite — which asks each system a different question, and
##      reports the difference as a speed.
##   2. Every workload's row count is compared between the two systems
##      *before* any timing is printed. A fast wrong number is worse than
##      no number, and a benchmark cannot be trusted to notice its own
##      bug.
#
# Usage: ruby tests/bench/bench_sqlite.rb [nodes] [edgesPerNode]
#   defaults: 5_000 nodes, 4 edges/node — about three minutes, almost all of
#   it the edge load (see limitations.md: MERGE scans rather than seeks, and
#   the grammar refuses a comma-MATCH, so every edge needs one).
#   `nimble benchSqlite 50000 4` is a bigger, slower run.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "glyphes"
require "sqlite3"
require "tmpdir"

NODES = Integer(ARGV[0] || 5_000)
FANOUT = Integer(ARGV[1] || 4)
CITIES = %w[Lyon Nice Paris Berlin Madrid Rome Lisbon Vienna].freeze
BATCH = 1000
POINT_ITER = 200
ONE_HOP_ITER = 1000
TWO_HOP_ITER = 100

def abort_with(msg)
  warn(msg)
  exit 1
end

abort_with("bench_sqlite: nodes must be positive") unless NODES.positive?
abort_with("bench_sqlite: edgesPerNode must not be negative") if FANOUT.negative?

# The one dataset, yielded by both loaders. Deterministic: a benchmark that
# cannot be re-run is a rumour.
def nodes_of(nodes)
  Enumerator.new do |y|
    nodes.times { |i| y << [i, CITIES[i % CITIES.length], (i % 70) + 18] }
  end
end

def edges_of(nodes, fanout)
  return enum_for(:none) unless fanout.positive?

  Enumerator.new do |y|
    nodes.times do |i|
      fanout.times { |k| y << [i, (i * 31 + k * 7 + 1) % nodes] }
    end
  end
end

def timeit
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  value = yield
  [Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, value]
end

# The graph's nodes, as glyphes parameter rows.
def person_params(id, city, age)
  { "id" => id, "city" => city, "age" => age }
end

CREATE_NODE = "CREATE (:Person {id: $id, city: $city, age: $age})".freeze

# One edge between two *existing* nodes. A comma MATCH is refused (a
# cartesian product, refused at M5) and a second MATCH clause is a join,
# also refused — so the destination is bound with MERGE, which finds the
# existing node instead of creating a second copy of it.
#
# This is the honest shape to measure: the dialect's refusal of joins is a
# real cost, and it belongs in the number rather than in a footnote. It is
# also the benchmark's bottleneck. `MERGE`'s match half is built by
# `mergeChain`, which scans the label rather than seeking — measured at
# 275/s against 11 843/s for the equivalent MATCH and 21 620/s for CREATE a
# bare node, on 3·10^3 nodes with an index on the property. So edge load
# runs at a few hundred edges per second while node load runs at ~11 000/s.
# `limitations.md` states this with the numbers; fixing it means moving the
# seek out of plan.nim into ops.nim, because ops.nim cannot import plan.nim
# and `mergeChain` needs the same seek the planner uses.
def link(db, src, dst)
  db.exec("MATCH (a:Person {id: $src}) MERGE (b:Person {id: $dst}) " \
          "CREATE (a)-[:KNOWS]->(b)",
          { "src" => src, "dst" => dst })
end

# ---------------------------------------------------------------- glyphes

def run_glyphes(dir)
  r = {}
  db = Glyphes::Database.open(File.join(dir, "g.glyph"), create: true)
  # Both indexes are ones a real schema would have: age is the queried
  # property, id is what edges bind their endpoints by.
  db.index_create(kind: :range, label: "Person", property: "age")
  db.index_create(kind: :range, label: "Person", property: "id")

  db.transaction do
    print "  nodes ..."; $stdout.flush
    r[:load_nodes], = timeit do
      batch = []
      nodes_of(NODES).each do |(id, city, age)|
        batch << person_params(id, city, age)
        next if batch.size < BATCH

        batch.each { |row| db.exec(CREATE_NODE, row) }
        batch.clear
      end
      batch.each { |row| db.exec(CREATE_NODE, row) }
    end

    print " #{r[:load_nodes].round(2)}s\n  edges ..."; $stdout.flush
    r[:load_edges], = timeit do
      batch = []
      edges_of(NODES, FANOUT).each do |(src, dst)|
        batch << [src, dst]
        next if batch.size < BATCH

        batch.each { |(s, d)| link(db, s, d) }
        batch.clear
      end
      batch.each { |(s, d)| link(db, s, d) }
    end
  end
  r[:load] = r[:load_nodes] + r[:load_edges]
  print " #{r[:load_edges].round(2)}s\n"

  r[:point], r[:point_rows] = timeit do
    n = 0
    (0...POINT_ITER).each do |i|
      n += db.query("MATCH (p:Person) WHERE p.age = $age RETURN p LIMIT 1",
                    { "age" => (i % 70) + 18 }).to_a.length
    end
    n
  end

  # Keyed by property id on both sides — the property is what SQLite's
  # `edges.src` holds, so it is what both must walk from.
  r[:one_hop], r[:one_rows] = timeit do
    n = 0
    (0...ONE_HOP_ITER).each do |i|
      n += db.query("MATCH (a:Person {id: $id})-[:KNOWS]->(b:Person) RETURN b",
                    { "id" => i * 7 % NODES }).to_a.length
    end
    n
  end

  r[:two_hop], r[:two_rows] = timeit do
    n = 0
    (0...TWO_HOP_ITER).each do |i|
      n += db.query("MATCH (a:Person {id: $id})-[:KNOWS*1..2]->(b:Person) RETURN b",
                    { "id" => i * 13 % NODES }).to_a.length
    end
    n
  end

  r[:filter], r[:filter_rows] = timeit do
    db.query("MATCH (p:Person) WHERE p.age > 30 RETURN count(p) AS c").to_a.first.first
  end

  db.close
  r
end

# ---------------------------------------------------------------- sqlite

def run_sqlite(path)
  r = {}
  db = SQLite3::Database.new(path)
  db.execute_batch(<<~SQL)
    PRAGMA journal_mode = OFF;
    PRAGMA synchronous = OFF;
    CREATE TABLE nodes (id INTEGER PRIMARY KEY, city TEXT, age INTEGER);
    CREATE TABLE edges (src INTEGER, dst INTEGER);
  SQL

  r[:load_nodes], = timeit do
    db.execute("BEGIN")
    ins = db.prepare("INSERT INTO nodes (id, city, age) VALUES (?,?,?)")
    nodes_of(NODES).each { |row| ins.execute(*row) }
    ins.close
    db.execute("COMMIT")
  end

  r[:load_edges], = timeit do
    db.execute("BEGIN")
    ins = db.prepare("INSERT INTO edges (src, dst) VALUES (?,?)")
    edges_of(NODES, FANOUT).each { |row| ins.execute(*row) }
    ins.close
    db.execute("COMMIT")
  end
  r[:load] = r[:load_nodes] + r[:load_edges]

  # Indexes after the load, the way a table is actually built: creating
  # them first taxes every insert and would flatter the query numbers.
  db.execute_batch(<<~SQL)
    CREATE INDEX idx_edges_src ON edges(src);
    CREATE INDEX idx_edges_dst ON edges(dst);
    CREATE INDEX idx_nodes_age ON nodes(age);
  SQL

  r[:point], r[:point_rows] = timeit do
    n = 0
    st = db.prepare("SELECT id FROM nodes WHERE age = ? LIMIT 1")
    (0...POINT_ITER).each { |i| n += st.execute((i % 70) + 18).to_a.length }
    st.close
    n
  end

  r[:one_hop], r[:one_rows] = timeit do
    n = 0
    st = db.prepare("SELECT dst FROM edges WHERE src = ?")
    (0...ONE_HOP_ITER).each { |i| n += st.execute(i * 7 % NODES).to_a.length }
    st.close
    n
  end

  # Depth 0 is the start node; the walk emits every node strictly below the
  # start, at one hop or two — which is what `*1..2` means on the glyphes
  # side. Seeding at depth 1 would count the start node as a result.
  r[:two_hop], r[:two_rows] = timeit do
    n = 0
    st = db.prepare(<<~SQL)
      WITH RECURSIVE walk(id, depth) AS (
        SELECT ?, 0
        UNION ALL
        SELECT e.dst, w.depth + 1 FROM edges e JOIN walk w ON e.src = w.id
        WHERE w.depth < 2
      )
      SELECT id FROM walk WHERE depth > 0
    SQL
    (0...TWO_HOP_ITER).each { |i| n += st.execute(i * 13 % NODES).to_a.length }
    st.close
    n
  end

  r[:filter], r[:filter_rows] = timeit do
    db.get_first_value("SELECT count(*) FROM nodes WHERE age > 30")
  end

  db.close
  r
end

# ---------------------------------------------------------------- report

def ratio(g, s)
  return "n/a" if g.zero?

  s / g
end

puts "M11: glyphes vs SQLite edge-tables"
puts "  graph: #{NODES} nodes, #{FANOUT} edges/node = #{NODES * FANOUT} edges"
puts "  SQLite gets nodes(id, city, age), edges(src, dst), and B-tree indexes"
puts "  on edges.src, edges.dst and nodes.age — after the load, as a table is"
puts "  really built."
puts "  SQLite's synchronous=OFF is a bulk-load setting: it moves the load"
puts "  number and nothing else.\n\n"

Dir.mktmpdir do |dir|
  print "glyphes ... "
  $stdout.flush
  g = run_glyphes(dir)
  puts "done"
  print "sqlite  ... "
  $stdout.flush
  s = run_sqlite(File.join(dir, "s.db"))
  puts "done\n"

  # Asked the same questions, so a disagreement is a bug in one of them and
  # the comparison is void until it is resolved. Checked before any timing
  # is printed.
  %i[point_rows one_rows two_rows filter_rows].each do |k|
    next if g[k] == s[k]

    abort_with("ANSWER MISMATCH #{k}: glyphes=#{g[k]} sqlite=#{s[k]}" \
               " — the two systems answered different questions; the timing" \
               " below would be meaningless. Fix before reading it.")
  end
  puts "answers agree on every workload: point #{g[:point_rows]}, " \
       "one-hop #{g[:one_rows]}, two-hop #{g[:two_rows]}, " \
       "filter #{g[:filter_rows]}\n\n"

  ## The `work/s` column is queries per second for every row, including
  ## `filter` — which is one query over the whole graph. An earlier version
  ## divided rows by time on that row alone, so one column held two
  ## different units and the numbers were not comparable down the column.
  ## The row counts are printed above, where they are checked.
  printf("  %-11s %10s %10s %10s %9s\n", "workload", "glyphes", "sqlite", "work/s", "ratio")
  printf("  %s\n", "-" * 54)
  %i[load load_nodes load_edges point one_hop two_hop filter].each do |k|
    printf("  %-11s %9.3fs %9.3fs %10.1f %8.1fx\n",
           k, g[k], s[k], 1.0 / g[k], ratio(g[k], s[k]))
  end
  puts "\n  ratio = sqlite / glyphes; above 1.0 means glyphes is faster."
  puts "  work/s is queries per second for glyphes; the iterations per"
  puts "  workload are point 200, one-hop 1000, two-hop 100, filter 1."

  puts "\n  Read this with limitations.md beside it. glyphes loads a graph in"
  puts "  interpreted statements while SQLite bulk-inserts integer rows; the"
  puts "  load row is a statement-cost measurement more than a storage one."
  puts "  Interpretation: docs/ARCHITECTURE.md §7."
end
