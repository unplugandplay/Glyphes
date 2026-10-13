## glyphes — Glyph::Base, the model layer (RUBY.md §5)
##
## Rails-shaped, over the graph, with three rules that shape every line:
##
##   §0  The model layer translates and marshals. No cache of *data*, no
##       hidden state, no materialization behind the caller's back. The one
##       cache here is a compiled-statement cache keyed by
##       `(method, where, order, limit)` — deterministic by construction
##       (the same inputs compile to the same Cypher), and exempt for that
##       reason alone (RUBY.md §5.2, pin in §8).
##   R5  Every verb is exactly one FFI crossing beyond its query. A verb
##       that needed two queries would be two round-trips where the caller
##       wrote one.
##   R7  Every verb is reachable in raw Cypher — this is a convenience over
##       `db.query`, not a second query language that hides queries.
##
## What it deliberately does NOT do (RUBY.md §5.5) is load-bearing: no
## polymorphic belongs_to (the label *is* the type), no `joins`, no
## lazy-loading or N+1 guard (it hides the query, which is what you are
## debugging), no attribute type casting, no association caching.

require "json"

module Glyph
  class Base
    # Bounded (§9). The cache key is (shape, where, order, limit), so a
    # caller who interpolates user input into `order` generates a new key
    # per value — unbounded, and the only unbounded thing in the layer. FIFO
    # at the cap rather than LRU: an LRU needs an order on a Hash that only
    # exists to throw entries away, and the shape that fills it is the shape
    # whose entries are worth nothing anyway.
    STATEMENT_CACHE_LIMIT = 512

    include Validations
    # The validator registry supplies the `validates` DSL (it takes the
    # Rails hash form as well); the class body below only holds the storage
    # it writes to. `extend` belongs here, not inside `class << self` —
    # there it would extend the metaclass's metaclass and no model would
    # ever see the method.
    extend Validations
    # The process-wide store. §0 permits exactly one piece of ambient
    # state (the compiled-statement cache) and a database handle is not
    # data — it is the door every verb goes through. A model points
    # `Glyph::Base.store` at the database it wants.
    # The store is set on Glyph::Base (`Glyph::Base.store = db`) and every
    # subclass reads it through here. A per-class `store` that defaulted
    # to nil on each subclass (which `self.store = nil` in a class body
    # does) meant setting the Base store had no effect on Person — the
    # setting silently did nothing and every write said "no store set".
    # Reading falls back up the chain.
    class << self
      def store
        @store ||= (superclass.respond_to?(:store) ? superclass.store : nil)
      end

      def store=(db)
        @store = db
      end
    end

    class << self
      attr_reader :validations, :scopes, :relation_defs, :callbacks,
                  :before_save_callbacks, :after_save_callbacks

      # Every model class ever defined. The statement caches are per class,
      # so a schema change (an index appearing or disappearing) has to be
      # able to reach all of them — and "who exists" cannot be answered by
      # walking ObjectSpace in a library.
      def models
        @models ||= []
      end

      def inherited(sub)
        super
        models << sub
        sub.instance_variable_set(:@validations, {}.merge(validations))
        sub.instance_variable_set(:@scopes, scopes.dup)
        sub.instance_variable_set(:@relation_defs, relation_defs.dup)
        sub.instance_variable_set(:@before_save_callbacks, before_save_callbacks.dup)
        sub.instance_variable_set(:@after_save_callbacks, after_save_callbacks.dup)
        sub.instance_variable_set(:@statement_cache, {})
      end

      # `label :Human` overrides inference. The default is the class name —
      # `Person` → `:Person` — which is what makes the DSL read like Rails
      # without a second declaration.
      def label(name = nil)
        if name
          Glyphes::Ident.assert!(name, "label")
          @label = name.to_sym
        else
          # `name` first: an anonymous subclass that defines
          # `self.name` (a test, or a class built by `Class.new`) has the
          # right label there. `to_s` on an anonymous class is
          # `#<Class:0x…>`, which becomes a Cypher identifier and a
          # syntax error — the label must come from `name`, not `to_s`.
          # `self.name` — the bare `name` here is this method's parameter,
          # so the first version inferred from nil and fell back to to_s.
          inferred = (respond_to?(:name) && !self.name.nil? && !self.name.empty? ?
                      self.name.to_s.split("::").last : to_s.split("::").last)
          # A direct subclass of Base gets its own inferred label; only a
          # *sub-sub*class (whose parent already has a concrete label, e.g.
          # `class Employee < Person`) inherits it. The first version read
          # `superclass.label` for any subclass, so every model inherited
          # "Base" and every CREATE became `CREATE (n:Base …)`.
          @label ||= if superclass.respond_to?(:label) && superclass != Base &&
                        superclass.label.to_s != "Base"
                       superclass.label
                     else
                       inferred.to_sym
                     end
        end
      end

      # ---- the database -------------------------------------------------

      def database
        store || raise(Glyphes::Error.new(
          "no store set: call Glyph::Base.store = db",
          status: Glyphes::FFI::GLY_ERR))
      end

      # ---- class verbs -------------------------------------------------

      def new(attrs = {}) = super

      def create(attrs = {})
        rec = new(attrs)
        rec.save ? rec : nil
      end

      def create!(attrs = {})
        rec = new(attrs)
        rec.save!
        rec
      end

      def find(id)
        rec = Relation.new(self).by_id(id).to_a.first
        raise Glyphes::RecordNotFound.new("Couldn't find #{label} with id=#{id}") unless rec

        rec
      end

      def find_by(attrs) = Relation.new(self).where(attrs).to_a.first
      def first        = Relation.new(self).to_a.first
      def last         = Relation.new(self).last
      def all          = Relation.new(self)
      def where(conds = {}, params = {}) = Relation.new(self).where(conds, params)
      def order(field = nil, dir = nil) = Relation.new(self).order(field, dir)
      def limit(n) = Relation.new(self).limit(n)
      def offset(n) = Relation.new(self).offset(n)
      def pluck(*fields) = Relation.new(self).pluck(*fields)
      def count = Relation.new(self).count
      def exists?(conds = {}) = Relation.new(self).where(conds).exists?

      def find_or_create_by(attrs)
        found = find_by(attrs)
        return found if found

        create(attrs)
      end

      def first_or_create(attrs = {})
        found = first
        return found if found

        create(attrs)
      end

      def update_all(updates) = Relation.new(self).update_all(updates)
      def delete_all = Relation.new(self).delete_all
      def destroy_all = Relation.new(self).to_a.map(&:destroy)
      def upsert(attrs = {}, match = {}) = Relation.new(self).upsert(attrs, match)

      # ---- registration -------------------------------------------------

      # `validates` itself lives in Glyph::Validations (it takes the Rails
      # hash form there too); this is only the accessor the module writes
      # through. Declaring it here as well silently shadowed the module's
      # version on every subclass, so `validates :name, presence: true`
      # registered `{presence: true}` as a validator *kind* and checked
      # nothing.
      def validations = (@validations ||= {})

      # `scope :adults, -> { where("age >= $min", {min: 18}) }`. The lambda
      # runs against a fresh Relation and *its* result is the scope: a
      # `tap` here kept the receiver and dropped the `where` the lambda had
      # just built, so every scope silently meant "all rows".
      def scope(name, body)
        scopes[name.to_sym] = body
        define_singleton_method(name) do |*args|
          Relation.new(self).instance_exec(*args, &body)
        end
      end

      def has_many(name, opts = {})   = (relation_defs[name.to_sym] = opts.merge(kind: :has_many))
      def belongs_to(name, opts = {}) = (relation_defs[name.to_sym] = opts.merge(kind: :belongs_to))
      def has_one(name, opts = {})    = (relation_defs[name.to_sym] = opts.merge(kind: :has_one))

      def before_save(&blk) = before_save_callbacks << blk
      def after_save(&blk)  = after_save_callbacks << blk

      # ---- the one place Cypher is built -------------------------------

      # Every verb and every relation goes through a Relation, and a
      # Relation builds its statement here. "What does this verb issue" has
      # one answer, and R5 is structural rather than a promise.
      def compile_match(where_hash, where_params, order, dir, limit_n, offset_n,
                        pluck_fields = [], return_expr = "n", alias_name = "n")
        clause = "MATCH (#{alias_name}:#{label})"
        conds = where_hash.map { |k, v| "#{alias_name}.#{k} = $#{k}" }
        conds += (where_params[:clauses] || [])
        clause += " WHERE #{conds.join(' AND ')}" unless conds.empty?
        clause += " RETURN #{return_expr}"
        clause += " ORDER BY #{order} #{dir == :desc ? 'DESC' : 'ASC'}" if order
        clause += " SKIP #{offset_n}" if offset_n
        clause += " LIMIT #{limit_n}" if limit_n
        [clause, where_params.reject { |k, _| k == :clauses }]
      end

      # The compiled-statement cache. Keyed by everything that changes the
      # text; the value is the statement and the parameter key order. This
      # is the one cache §0 allows, and it holds statements, never data.
      def statement_cache
        @statement_cache ||= {}
      end

      # Cleared on a schema change (RUBY.md §5.2). The compiled *text* of a
      # model query does not depend on which indexes exist, so this is not
      # about correctness of the statement — it is that a cached statement
      # is a statement the store already planned, and the plan a store holds
      # for a schema that no longer exists is not a plan anyone should keep.
      def clear_all_statement_caches!
        models.each(&:clear_statement_cache!)
      end

      def clear_statement_cache!
        statement_cache.clear
      end

      # Called after a compile: keeps the cache from being the only part of
      # a program that grows forever.
      def bound_statement_cache!
        cache = statement_cache
        return if cache.size <= STATEMENT_CACHE_LIMIT

        overflow = cache.size - STATEMENT_CACHE_LIMIT
        cache.keys.first(overflow).each { |k| cache.delete(k) }
      end
    end

    @validations = {}
    @scopes = {}
    @relation_defs = {}
    @before_save_callbacks = []
    @after_save_callbacks = []

    attr_reader :errors
    attr_accessor :node_view

    def initialize(attrs = {})
      @attributes = {}
      @original = {}
      @persisted = false
      @errors = {}
      @node = nil            # the view a query-returned record reads lazily
      assign_attributes(attrs)
    end

    # ---- attributes ---------------------------------------------------

    def [](key) = @attributes[key.to_sym]

    # Every attribute name enters through here — new, update, assign — so
    # this is the one place a name can be checked before it is ever
    # interpolated into `SET n.#{k}` or `CREATE (n {#{k}: …})`.
    def []=(key, value)
      Glyphes::Ident.assert!(key, "attribute")
      @attributes[key.to_sym] = value
    end
    def attributes = @attributes.dup
    def id = @attributes[:id]

    def method_missing(name, *args)
      attr = name.to_s
      if attr.end_with?("=")
        self[attr[0..-2]] = args.first
      elsif @attributes.key?(name)
        @attributes[name]
      elsif self.class.relation_defs.key?(name)
        # An association is a lazy Relation (R10): `person.knows.first(5)`
        # issues `LIMIT 5`, and `person.knows.to_a` materializes. It is
        # never an Array, and never cached (§0).
        #
        # This is checked *before* the node-view fallback below. A record
        # a query returned carries a view, and a property that happens to
        # share a name with an association would otherwise be answered from
        # the view — silently returning nil for `person.knows` instead of
        # the association. A declared association is the more specific
        # answer, so it wins.
        association_relation(name, args)
      elsif @node && @node.exist?
        # A record a query returned carries the node view, and an attribute
        # it was not given is read through it (pin Y5: Node/Edge/Path are
        # views resolved lazily). This is Rails' lazy attribute read, and
        # it costs one crossing for the record the caller actually touches
        # — not one per record in a collection the caller never looked at,
        # which is the N+1 the layer exists to avoid.
        v = @node.properties[attr]
        unless v.nil? || frozen?
          # The read value is the persisted value: seeding the original
          # keeps `changed?` honest. Seeding only @attributes made a mere
          # read look like a change — and a `touch` would then write a row
          # the caller never edited.
          @attributes[name] = v
          @original[name] = v unless @original.key?(name)
        end
        v
      else
        super
      end
    end

    def respond_to_missing?(name, include_private = false)
      name.to_s.end_with?("=") || @attributes.key?(name) ||
        self.class.relation_defs.key?(name) || super
    end

    # ---- associations (RUBY.md §5.3) ---------------------------------

    # Builds the relation's WHERE for this record's association. The
    # composition is one Cypher statement with the right pattern — a
    # `has_many` is `MATCH (a)-[:KNOWS]->(b)`, a `belongs_to` reverses the
    # arrow, a `has_one` adds `LIMIT 1`, and `through:` chains two hops in
    # the same MATCH. Nothing is materialized until the caller asks.
    def association_relation(name, _args)
      opts = self.class.relation_defs[name]
      raise Glyphes::Error.new("#{self.class.name}##{name}: not persisted",
                               status: Glyphes::FFI::GLY_ERR) unless @persisted

      rel = Relation.new(target_class(name))
      rel.instance_variable_set(:@source_id, id)
      rel.instance_variable_set(:@assoc_name, name)
      rel.instance_variable_set(:@assoc_opts, opts)
      rel.instance_variable_set(:@assoc_kind, opts[:kind])
      rel
    end

    def target_class(name)
      opts = self.class.relation_defs[name]
      cn = opts[:class_name]
      return self.class if cn.nil? || cn.to_s == self.class.name.to_s

      # Resolve a class_name to a registered model when one is available;
      # otherwise the relation still runs (it matches on label only).
      (self.class.store && Object.const_get(cn.to_s)) rescue self.class
    end

    def persisted? = @persisted
    def new_record? = !@persisted
    def changed?
      @attributes.any? { |k, v| @original[k] != v }
    end

    # ---- persistence --------------------------------------------------

    # The write door. One statement, one crossing. Returns false when a
    # validation failed (Rails semantics) — the whole reason `save` and
    # `save!` are two methods.
    def save
      return false unless valid?

      run_callbacks(:before_save)
      if @persisted
        persist_write
      else
        persist_create
      end
      @original = @attributes.dup
      @persisted = true
      run_callbacks(:after_save)
      true
    end

    def save!
      unless save
        raise Glyphes::ValidationError.new(@errors)
      end
      true
    end

    def update(attrs = {})
      assign_attributes(attrs)
      save
    end

    def update!(attrs = {})
      assign_attributes(attrs)
      save!
    end

    # Every property of this record's node, materializing a record a query
    # returned. Used by reload, and by callers who want the row, not a view.
    def read_all_attributes
      materialize!
      @attributes.merge(id: id)
    end

    def reload
      unless @persisted
        raise Glyphes::Error.new("reload: not persisted",
                                 status: Glyphes::FFI::GLY_ERR)
      end

      # `fresh.attributes` is id-only for a query-returned record (the rest
      # is lazy), so copying it would keep the *stale* values this reload
      # exists to replace. Reload reads the row once and takes every value
      # from it — one crossing, by design: reload is a terminal verb, not a
      # collection walk.
      fresh = self.class.find(id)
      assign_attributes(fresh.read_all_attributes)
      @original = @attributes.dup
      self
    end

    def destroy
      return false unless @persisted

      self.class.database.exec(
        "MATCH (n:#{self.class.label}) WHERE id(n) = $id DETACH DELETE n",
        { "id" => id })
      @persisted = false
      true
    end

    # Rails' touch skips validations, because Rails' touch writes only the
    # timestamps it owns. Ours writes the whole row — there is no dirty
    # tracking (§5.5), so "what touch writes" is "every attribute the
    # record holds", including edits the caller never asked touch to save.
    # Letting that past the validation door would make touch the way
    # around the door, so touch goes through it: same door as save, and a
    # record holding an invalid edit refuses to touch.
    def touch
      return false unless @persisted

      save
    end

    # Ruby's freeze, plus the state a record mutates. Freezing only the
    # record is the trap this method exists to close: `p.name = x` does not
    # touch the record's ivars, it mutates the Hash an ivar holds — and a
    # frozen record whose attribute hash stayed writable accepted writes,
    # then `save` wrote them to the store. `frozen?` is Ruby's own; there
    # is no flag to drift out of sync with the real state.
    def freeze
      @attributes.freeze
      @original.freeze
      super
    end

    # ---- validations (RUBY.md §5.4) -----------------------------------

    # Rails-shaped: a boolean, and `errors` populated. Uniqueness is NOT
    # checked here — it is delegated to a real uniqueness constraint in
    # the engine (TXN.md §5), because a Ruby-side uniqueness check is a
    # check that can be raced and is a different mechanism from the one
    # that makes uniqueness true.
    def valid?(_context = nil)
      # A record a query returned holds an id and a view; its validated
      # fields may not be in @attributes yet, and validating nils the row
      # does not have fails the record on properties it actually has.
      # Hydrating once here is one crossing and makes every check below
      # read the row the node actually carries.
      materialize! unless self.class.validations.empty?
      @errors = {}
      self.class.validations.each do |field, checks|
        checks.each do |kind, opts|
          message = validate_field(field, kind, opts, self[field])
          next unless message

          (@errors[field] ||= []) << message
        end
      end
      @errors = @errors.reject { |_, m| m.empty? }
      @errors.empty?
    end

    def ==(other)
      other.is_a?(self.class) && !id.nil? && other.id == id
    end

    def inspect
      state = @persisted ? "persisted" : "new"
      attrs = @attributes.reject { |k, _| k == :id }.inspect
      "#<#{self.class.name} #{attrs} #{state}>"
    end

    private

    # Pull the node's properties into @attributes once. A record a query
    # returned is an id and a view; anything that needs the whole row
    # (validations, reload) needs this, and anything that seeds a single
    # attribute lazily must seed @original alongside, or a read masquerades
    # as a change.
    def materialize!
      # No exist? probe: a node view raises a proper not-found from the
      # properties read itself, and an extra crossing spent converting one
      # exception into another is the crossing R5 says verbs do not have.
      return unless @node

      @node.properties.each do |k, v|
        sym = k.to_sym
        next if @attributes.key?(sym)

        @attributes[sym] = v
        @original[sym] = v
      end
    end

    def error_summary
      @errors.map { |f, m| "#{f} #{m.join(', ')}" }.join("; ")
    end

    def assign_attributes(attrs)
      (attrs || {}).each { |k, v| self[k] = v }
    end

    def run_callbacks(kind)
      list = kind == :before_save ? self.class.before_save_callbacks : self.class.after_save_callbacks
      list.each do |cb|
        cb.arity.zero? ? instance_exec(&cb) : cb.call(self)
      end
    end

    def persist_create
      props = @attributes.reject { |k, _| k == :id }
      # The property map lives *inside* the pattern's parentheses
      # (`CREATE (n:Person { … })`), not after them — the first version
      # emitted `CREATE (n:Person) { … }`, which is a syntax error whose
      # message points at the brace and says nothing about the paren.
      map = props.empty? ? "" : " { " + props.keys.map { |k| "#{k}: $#{k}" }.join(", ") + " }"
      cypher = "CREATE (n:#{self.class.label}#{map})"
      # `RETURN id(n)` so the record knows its own address in one crossing
      # (R5). The engine's exec_returning hands back the id; without it a
      # read-back query would race a concurrent writer for this node.
      _, new_id = self.class.database.exec_returning("#{cypher} RETURN id(n) AS id",
                                                    write_params)
      @attributes[:id] = new_id
    end

    # The update of a persisted row: every property the record holds, one
    # statement. There is no dirty diff (§5.5) — the row is written whole,
    # which is also what makes touch safe to skip validations.
    def persist_write
      sets = @attributes.reject { |k, _| k == :id }
                     .map { |k, _| "n.#{k} = $#{k}" }.join(", ")
      return if sets.empty?

      # The WHERE's $id travels with the SETs' params: write_params drops
      # :id (it is not a property), so the update query must add it back or
      # `id(n) = $id` binds null, matches nothing, and updates zero rows —
      # silently, because a SET that matches nothing is not an error.
      params = write_params.merge("id" => id)
      self.class.database.exec(
        "MATCH (n:#{self.class.label}) WHERE id(n) = $id SET #{sets}",
        params)
    end

    def write_params
      @attributes.each_with_object({}) { |(k, v), h| h[k.to_s] = v unless k == :id }
    end
  end
end