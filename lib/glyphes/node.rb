## glyphes — Node and Edge views (RUBY.md §4.1–4.2)
##
## **Views, not copies.** A Node holds a database handle and an id, never a
## property map. `node.properties` is resolved against the store at the
## moment it is called, so a Node handed to another method re-reads current
## state: a node that changed after the query still reports what it is now.
## The alternative — materialising the properties when the cell arrives —
## is a cache, and RUBY.md §0 ("the Ruby layer translates and marshals; it
## never caches") exists because a Ruby-side cache makes `db.query` and the
## views disagree, and the bug gets reported as "the database is
## inconsistent".
##
## Each accessor is one engine call. `db.query` remains available for
## everything else — these three conveniences are for the graph-shaped work
## where a Cypher round-trip would be silly, not a second query language.

module Glyphes
  # `Node.new(db, id)` — RUBY.md §4.2's reading of a node without Cypher.
  # Also what a `GLY_NODE` cell materializes as.
  class Node
    attr_reader :id

    def initialize(db, id)
      # A Database, or anything holding the same handle — the cell path
      # passes the handle directly so a cell does not have to keep the
      # Database alive to resolve a label.
      @db = db.respond_to?(:handle) ? db.handle : db
      @id = id.to_i
    end

    def handle = @db

    # One call: `{"id":n,"labels":[…]}`. A deleted node raises rather than
    # reporting no labels — "this node has no labels" and "this node is
    # gone" must not look the same.
    def labels
      json = FFI.json_call(@db, :glyphes_node_labels, @id, "node_labels")
      JSON.parse(json)["labels"]
    end

    def label
      # The common case: one label per node in this slice, so this avoids a
      # second parse. Multi-label nodes are not a thing yet (CYPHER.md
      # C13 refuses more than one), and `labels` is there when they are.
      labels.first
    end

    def properties
      json = FFI.json_call(@db, :glyphes_node_props, @id, "node_props")
      JSON.parse(json)["properties"]
    end

    # Re-read on every call, by construction — see the file header.
    def [](key) = properties[key]

    def exist?
      labels
      true
    rescue Glyphes::Error
      false
    end

    # Two nodes are the same node when they are the same id in the same
    # database. Comparing anything else would mean reading the store to
    # answer `==`, which is not what a value type's `==` should cost.
    def ==(other)
      other.is_a?(Node) && other.id == id && other.handle == @db
    end
    alias eql? ==

    def hash = [Node, @db, id].hash

    def to_i = id
    def inspect = "#<Glyphes::Node id=#{id}>"
    alias to_s inspect
  end

  # `GLY_EDGE` cell materializes as this: id, type, endpoints (RUBY.md §4.1).
  # The type and endpoints are resolved on demand from `glyphes_edge_info`.
  class Edge
    attr_reader :id

    def initialize(db, id)
      @db = db.respond_to?(:handle) ? db.handle : db
      @id = id.to_i
    end

    def handle = @db

    def type
      JSON.parse(FFI.json_call(@db, :glyphes_edge_info, @id, "edge_info"))["type"]
    end

    def src = Node.new(@db, JSON.parse(info_json)["src"])
    def dst = Node.new(@db, JSON.parse(info_json)["dst"])

    def [](key) = properties[key]

    def properties
      # Edge properties cross the same cap protocol as node properties; the
      # engine returns `{}` for an edge with none rather than a null.
      json = FFI.json_call(@db, :glyphes_edge_props, @id, "edge_props")
      JSON.parse(json)["properties"] || {}
    end

    def ==(other)
      other.is_a?(Edge) && other.id == id && other.handle == @db
    end
    alias eql? ==

    def hash = [Edge, @db, id].hash

    def inspect
      "#<Glyphes::Edge id=#{id}>"
    end
    alias to_s inspect

    private

    def info_json = FFI.json_call(@db, :glyphes_edge_info, @id, "edge_info")
  end
end