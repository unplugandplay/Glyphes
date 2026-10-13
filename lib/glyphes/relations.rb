## glyphes — Relation, the lazy query the model layer speaks (RUBY.md §5.3)
##
## **A Relation is a query, not a collection.** Every chainable method
## returns a new Relation carrying the compiled statement; nothing executes
## until the chain is materialized (`to_a`, `first`, `each`, `count`,
## `exists?`, `pluck`, `destroy_all`). That is what makes
## `person.knows.first(5)` issue `LIMIT 5` (R10) instead of pulling every
## related node and taking five — and it is also Rails's collection-proxy
## behaviour, which is the reason the model layer can read like Rails
## without hiding the query (RUBY.md §5.5).
##
## `through:` composes in Cypher, not in Ruby: two hops in one statement, no
## intermediate Ruby array, no N+1 beyond what the query itself implies.

module Glyph
  # One deferred statement against a model class. Immutable-ish: chaining
  # returns a fresh Relation, so a Relation can be stored, passed around
  # and re-chained without the query underneath changing under the caller.
  class Relation
    # §9 asked `Relation` or `Enumerator`. Both, minus the part that hurts:
    # `Relation` is the object (so `person.knows.where(...)` reads the way
    # Rails writes it, and so `to_cypher` can show the statement), and
    # `Enumerable` gives the ergonomics an Enumerator would have.
    include Enumerable

    attr_accessor :model, :where_hash, :where_params, :order_field, :order_dir,
                  :limit_n, :offset_n, :pluck_fields, :clause

    def initialize(model)
      @model = model
      @where_hash = {}
      @where_params = {}
      @order_field = nil
      @order_dir = :asc
      @limit_n = nil
      @offset_n = nil
      @pluck_fields = []
      @relation_path = []       # for association relations
      @clause = nil            # an explicit WHERE fragment, for relations
      @source_id = nil          # the record this association hangs off
      @assoc_name = nil
      @assoc_opts = {}
      @assoc_kind = nil
    end

    # ---- chaining (returns a new Relation) ------------------------------

    def where(conds = {}, params = {})
      n = dup_chain
      if conds.is_a?(Hash)
        n.where_hash = @where_hash.merge(conds)
        n.where_params = @where_params.merge(stringify_params(params))
      else
        # A raw Cypher condition with $params: `where("age >= $min", min: 18)`.
        # A *bare* field is qualified with the model alias — `age` alone is
        # "variable age is not defined by any MATCH" from the engine, which
        # is correct and unhelpful to someone writing the Rails-shaped
        # `where("age >= $min")`. An already-qualified `n.age` and a
        # `$param` are left alone.
        n.clause = [@clause, qualify_clause(conds)].compact.join(" AND ")
        n.where_params = @where_params.merge(stringify_params(params))
      end
      n
    end

    def order(field = nil, dir = nil)
      n = dup_chain
      n.order_field = field if field
      n.order_dir = (dir || :asc).to_sym
      n
    end

    # Reversing an unordered relation changes nothing the engine can act
    # on, so `last` on a relation with no `order` is not "the last row" —
    # it is whichever row the scan happened to end on. Two orders are
    # deterministic here and both mean something: an explicit one, and
    # insertion order (the store's internal id is the write order).
    def reverse_order
      n = dup_chain
      n.order_dir = @order_dir == :desc ? :asc : :desc
      n.order_field = @order_field || :id
      n
    end

    def limit(n)  = (c = dup_chain; c.limit_n = n; c)
    def offset(n) = (c = dup_chain; c.offset_n = n; c)
    # `pluck` is a *terminal* verb, not a chain step: it issues the query
    # and returns the scalars. Chaining it (`Person.pluck(:a).where(...)`)
    # makes no sense — there is no "rows of plucked fields" to filter — so
    # it runs here and `Class.pluck` delegates to exactly this.
    def pluck(*fields)
      fields.flatten.each { |f| Glyphes::Ident.assert!(f, "pluck field") }
      c = dup_chain
      c.pluck_fields = fields.flatten
      c.to_a
    end

    # ---- execution (this is where an FFI crossing happens) --------------

    def to_a
      cypher, params = compile
      result = @model.database.query(cypher, params)
      rows = result.to_a
      @pluck_fields.empty? ? rows.map { |r| instantiate(r) } : rows.flatten(1)
    end
    alias to_ary to_a

    def each(&block)
      return to_enum(:each) unless block

      to_a.each(&block)
      self
    end

    # `relation.first` is the first row; `relation.first(5)` is *five
    # rows*, and the five arrive as a `LIMIT 5` in the statement (R10) —
    # not as "pull everything, keep five", which is the crossing this layer
    # exists to avoid. `person.knows.first(5)` therefore returns a Relation
    # the caller can chain, and `.to_a` materializes it.
    # The statement this relation would issue, and its parameters. The
    # R5/R10 gates assert on this — "a verb is one statement", "`first(5)`
    # says LIMIT 5" — because timing cannot show either.
    def to_cypher
      compile.first
    end

    def to_params
      compile.last
    end

    def first(n = nil)
      return limit(n) if n
      return to_a.first unless @assoc_name || @limit_n

      # With an explicit limit the first row is not knowable from the
      # statement, so ask for one row.
      to_a.first
    end

    # `last` reverses the order and takes the first row, so the engine
    # answers it with `ORDER BY … DESC LIMIT 1` rather than the layer
    # materializing the whole set and calling `.last` in Ruby.
    def last
      reverse_order.limit(1).to_a.first
    end

    # `count` is `RETURN count(*)` — one statement that answers the number,
    # not `to_a.size`, which would pull every row over the boundary to
    # count it in Ruby.
    def count
      cypher, params = compile(count: true)
      @model.database.query(cypher, params).to_a.flatten.first.to_i
    end

    # `exists?` is `LIMIT 1` and a peek — one row crossing the boundary to
    # answer a boolean, rather than materializing a collection to take its
    # length.
    def exists?
      cypher, params = compile(exists: true)
      !@model.database.query(cypher, params).to_a.empty?
    end

    def any? = exists?

    def size = count
    def empty? = !exists?
    def inspect
      cypher, = compile
      "#<Glyph::Relation #{cypher}>"
    end

    # ---- writes through the relation -------------------------------------

    # One statement for the whole set, not a Ruby loop: `update_all` on a
    # million nodes is one crossing and one engine batch, which is the
    # whole reason it exists beside `map(&:update)`.
    def update_all(updates)
      cypher, params = compile(write: true)
      updates.each_key { |k| Glyphes::Ident.assert!(k, "update_all key") }
      sets = updates.map { |k, v| "n.#{k} = $set_#{k}" }.join(", ")
      full = cypher.sub("RETURN n", "SET #{sets}")
      params = params.merge(updates.transform_keys { |k| "set_#{k}" })
      @model.database.exec(full, params)
    end

    def delete_all
      cypher, params = compile(write: true)
      cypher = cypher.sub("RETURN n", "DELETE n")
      @model.database.exec(cypher, params)
    end

    def destroy_all
      to_a.map(&:destroy)
    end

    # `upsert` is a MERGE: one statement, atomic per node. The match keys
    # become the WHERE of a MERGE; the attributes become the ON CREATE /
    # ON MATCH payload. With no match keys it merges on the full attribute
    # hash, which is the "same document" idempotent-import shape.
    def upsert(attrs = {}, match = {})
      attrs.each_key { |k| Glyphes::Ident.assert!(k, "upsert attribute") }
      where_hash = match.empty? ? attrs : match
      where_hash.each_key { |k| Glyphes::Ident.assert!(k, "upsert match key") }
      cypher = "MERGE (n:#{@model.label} { " +
               where_hash.keys.map { |k| "#{k}: $#{k}" }.join(", ") + " }) " +
               "ON CREATE SET n += $attrs ON MATCH SET n += $attrs " +
               "RETURN id(n) AS id"
      params = stringify_params(where_hash).merge("attrs" => attrs)
      _, id = @model.database.exec_returning(cypher, params)
      # The MERGE just told us the id: the node exists, so the record is
      # its id and its view. Re-reading it with a query made upsert the one
      # verb in the layer that crossed twice (R5).
      record_from_id(id)
    end

    # Address one node by id. Public because `Base.find` composes it; the
    # relation it returns is the same lazy Relation as any other.
    def by_id(id)
      c = dup_chain
      c.clause = ["id(n) = $by_id", @clause].compact.join(" AND ")
      c.where_params = @where_params.merge("by_id" => id)
      c
    end

    private

    # A returned node cell becomes a model instance holding that id. The
    # instance's attributes are *not* materialized here — a query that
    # returns `n` did not ask for the properties, and reading them would
    # be one crossing per row (the N+1 this layer exists to avoid). The
    # record reads them on demand, through `Node#properties`, exactly like
    # Rails' lazy attribute read.
    def instantiate(row)
      cell = row.is_a?(Array) ? row.first : row
      record_from_id(cell.respond_to?(:id) ? cell.id : cell)
    end

    # A record around a node known to exist: its id, and the view it reads
    # attributes through lazily (pin Y5).
    def record_from_id(node_id)
      rec = @model.new
      rec.instance_variable_set(:@attributes, { id: node_id })
      rec.instance_variable_set(:@original, { id: node_id })
      rec.instance_variable_set(:@persisted, true)
      rec.instance_variable_set(:@node, Glyphes::Node.new(@model.database, node_id))
      rec
    end

    def find_by_id(id)
      m = Relation.new(@model)
      m.send(:by_id, id).to_a.first
    end

    # Qualify bare property names in a user-supplied WHERE fragment:
    # `age >= $min` → `n.age >= $min`. Not a parser — a word scan that
    # names the model alias. Five things must survive untouched: a `$`
    # parameter, an already-qualified or dotted path (`n.age`), a function
    # call (`labels(n)`), a keyword (`true`, `and`, `IS NULL`), and a
    # string literal. The second version qualified `true` → `n.true` and
    # the `ana` inside `'ana'` — both compiled fine and both answered
    # **zero rows**, silently, which is the worst failure a qualifier can
    # have: the query the caller wrote is not the query that ran. Anything
    # malformed still reaches the engine, which is the real parser.
    QUALIFY_SKIP = %w[and or xor not in is null true false
                      starts ends contains].freeze

    def qualify_clause(clause)
      # String literals are split out first: a word scan has no quote
      # awareness, and `'ana'` must reach the engine as `'ana'`.
      clause.to_s.split(/('(?:[^']|'')*')/, -1).flat_map.with_index do |part, i|
        next [part] if i.odd?

        part.scan(/(?<![\w.$:])([a-zA-Z_][a-zA-Z_0-9]*)(?!\s*\()|([^a-zA-Z_0-9]+|.)/)
            .map { |w, junk| w ? qualify_word(w) : junk }
      end.join
    end

    def qualify_word(word)
      return word if word == "n" || word == "b"
      return word if QUALIFY_SKIP.include?(word.downcase)

      word.match?(/\A[a-z_]/) ? "n.#{word}" : word
    end

    def stringify_params(params)
      (params || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end

    def dup_chain
      copy = Relation.new(@model)
      copy.where_hash = @where_hash.dup
      copy.where_params = @where_params.dup
      copy.order_field = @order_field
      copy.order_dir = @order_dir
      copy.limit_n = @limit_n
      copy.offset_n = @offset_n
      copy.pluck_fields = @pluck_fields.dup
      copy.instance_variable_set(:@clause, @clause)
      copy.instance_variable_set(:@relation_path, @relation_path.dup)
      copy.instance_variable_set(:@source_id, @source_id)
      copy.instance_variable_set(:@assoc_name, @assoc_name)
      copy.instance_variable_set(:@assoc_opts, @assoc_opts)
      copy.instance_variable_set(:@assoc_kind, @assoc_kind)
      copy
    end

    # ---- the compiler --------------------------------------------------

    # The statement cache is keyed by everything that changes the text, and
    # the value is the statement — never data (§0). A compiled statement is
    # deterministic for its inputs, which is what makes caching it
    # different from caching a result.
    #
    # The where *values* are not part of the key: `where(age: 1)` and
    # `where(age: 2)` compile to the same text and differ only in the param
    # map, which is built fresh on every call. Keying on the values turned
    # the cache into a per-value cache — an app filtering by a moving value
    # (a session id, a timestamp) got no reuse at all out of the one cache
    # §0 allows. The keys, in insertion order, are the shape: the same keys
    # in a different order is a different conjunction, and a different text.
    def compile(count: false, exists: false, write: false)
      cache = @model.statement_cache
      key = [count, exists, write, @relation_path, @clause, @where_hash.keys,
             @order_field, @order_dir, @limit_n, @offset_n, @pluck_fields]
      cypher = cache[key] ||= build_cypher(count: count, exists: exists,
                                          write: write)
      # After the insert, not before: bounding first leaves the cache one
      # entry over the cap, which is the kind of off-by-one that only
      # shows up in the test that counts.
      @model.bound_statement_cache!
      params = build_params
      [cypher, params]
    end

    def build_cypher(count: false, exists: false, write: false)
      return build_assoc_cypher(count: count, exists: exists) if @assoc_name

      clause = "MATCH (n:#{@model.label})"
      conds = @where_hash.map do |k, v|
        Glyphes::Ident.assert!(k, "where key")
        # `where(age: nil)` is Rails for "the field is absent" — a property
        # that is not there. `n.age = null` is never true in Cypher, so the
        # literal translation answers zero rows for every absent field,
        # silently.
        v.nil? ? "n.#{k} IS NULL" : "n.#{k} = $#{k}"
      end
      conds << @clause if @clause && !@clause.empty?
      clause += " WHERE #{conds.join(' AND ')}" unless conds.empty?

      if count
        "#{clause} RETURN count(*) AS c"
      elsif exists
        "#{clause} RETURN n LIMIT 1"
      elsif write
        "#{clause} RETURN n"
      else
        ret = if @pluck_fields.empty?
                "n"
              else
                @pluck_fields.map { |f| f.to_s.start_with?("n.") ? f : "n.#{f}" }.join(", ")
              end
        out = "#{clause} RETURN #{ret}"
        out += " ORDER BY #{order_expr} #{@order_dir == :desc ? 'DESC' : 'ASC'}" if @order_field
        out += " SKIP #{@offset_n}" if @offset_n
        out += " LIMIT #{@limit_n}" if @limit_n
        out
      end
    end

    # An association is one statement, not a per-record query. `has_many`
    # walks out, `belongs_to` walks in, `has_one` is a has_many that stops
    # at one, and `through:` chains both hops in the same MATCH (RUBY.md
    # §5.3: composed in Cypher, so there is no intermediate Ruby array and
    # no N+1 beyond what the query itself implies).
    def build_assoc_cypher(count: false, exists: false)
      opts = @assoc_opts || {}
      via = opts[:via] || derive_type(@assoc_name)
      target_label = opts[:class_name] || @model.label
      [via, target_label, opts[:through]].compact.each do |piece|
        Glyphes::Ident.assert!(piece, "association name")
      end
      dir = (@assoc_kind == :belongs_to) ? "<-[:#{via}]-" : "-[:#{via}]->"

      clause =
        if opts[:through]
          # Two hops in one MATCH: (a)-[:VIA]->(mid)<-[:THROUGH]-(b)
          mid_label = opts[:class_name] || @model.label
          "MATCH (a)-[:#{via}]->(mid:#{mid_label})<-[:#{opts[:through]}]-(b:#{target_label}) WHERE id(a) = $src_id"
        else
          "MATCH (a)#{dir}(b:#{target_label}) WHERE id(a) = $src_id"
        end

      if count
        return "#{clause} RETURN count(*) AS c"
      elsif exists
        return "#{clause} RETURN b LIMIT 1"
      end

      ret = @pluck_fields.empty? ? "b" : @pluck_fields.map { |f| f.to_s.start_with?("b.") ? f : "b.#{f}" }.join(", ")
      out = "#{clause} RETURN #{ret}"
      out += " ORDER BY #{assoc_order_expr} #{@order_dir == :desc ? 'DESC' : 'ASC'}" if @order_field
      out += " SKIP #{@offset_n}" if @offset_n
      # has_one is a has_many that stops at one: the LIMIT belongs in the
      # statement, not in `to_a.first`, so the query says what it means.
      out += " LIMIT 1" if @assoc_kind == :has_one || @limit_n.nil? && false
      out += " LIMIT #{@limit_n}" if @limit_n && @assoc_kind != :has_one
      out
    end

    # The association's rows are `b`; ordering by the store id is `id(b)`.
    # The first version emitted `b.id(n)` — a property named `id` of a
    # variable `n` that this MATCH never bound — and `knows.last`, the one
    # verb that reaches this path, raised instead of answering.
    def assoc_order_expr
      f = @order_field.to_s
      return "id(b)" if f.start_with?("id(")
      return "id(b)" if f == "id"

      Glyphes::Ident.assert!(f.start_with?("b.") ? f[2..] : f, "order field")
      f.start_with?("b.") ? f : "b.#{f}"
    end

    def derive_type(name)
      # Rails derives the relationship type from the association name
      # (`knows` → KNOWS, `likes` → LIKES); an explicit `type:` wins.
      (@assoc_opts || {})[:type] || name.to_s.upcase
    end

    def order_expr
      # ORDER BY names a *variable*, and the only bound variable in a
      # model query is the alias — `ORDER BY age` is "undefined variable
      # name" from the engine, which is correct: nothing named `age` is in
      # scope, `n.age` is the expression. A bare field is qualified here.
      f = @order_field.to_s
      # `id(n)` is the store's internal id, not a property — it is the only
      # ordering that means "insertion order", and it must reach the engine
      # as written. `n.id` is a *property* named id, which sorts as null on
      # a graph with no such property and leaves the order arbitrary — so a
      # bare `order(:id)`, the Rails reading of a primary-key order, means
      # the store id here, not that property.
      return f if f.start_with?("id(")
      return "id(n)" if f == "id"

      Glyphes::Ident.assert!(f.start_with?("n.") ? f[2..] : f, "order field")
      f.start_with?("n.", "b.") ? f : "n.#{f}"
    end

    def build_params
      # A nil where value became IS NULL, not a parameter: binding null to
      # `n.age = $age` would be the zero-rows bug again.
      params = stringify_params(@where_hash.compact)
      params.merge!(stringify_params(@where_params))
      params["src_id"] = @source_id if @source_id
      params
    end
  end
end