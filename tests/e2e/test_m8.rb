require "minitest/autorun"
require "tmpdir"
require "json"
require "glyphes"

# M8 — the model layer (RUBY.md §5). Gate R6: a Rails-shaped suite on
# Glyph::Base. Gate R5: a verb is one FFI crossing beyond its query.
# Gate R10: an association collection is lazy — `person.knows.first(5)`
# issues `LIMIT 5`, not "pull everything, take five".
class M8Test < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @db = Glyphes::Database.open(File.join(@dir, "m8.glyph"), create: true)
    Glyph::Base.store = @db
    setup_models
  end

  def teardown
    @db.close unless @db.closed?
    Glyph::Base.store = nil
    FileUtils.remove_entry(@dir)
  end

  def setup_models
    # Fresh anonymous-ish classes per test so no state leaks between them.
    @person = Class.new(Glyph::Base) do
      def self.name = "Person"
      validates :name, :presence
      validates :age, :numericality, greater_than: 0
      has_many :knows, class_name: "Person", type: "KNOWS"
      has_many :likes, class_name: "Like", type: "LIKES"
      has_one :profile, class_name: "Profile", type: "HAS_PROFILE"
    end
    @like = Class.new(Glyph::Base) do
      def self.name = "Like"
    end
    @profile = Class.new(Glyph::Base) do
      def self.name = "Profile"
    end
  end

  def person!(name, age)
    @person.create!(name: name, age: age)
  end

  # An edge out of an existing record, onto a freshly created node. The
  # source is addressed by its real id, so the association under test walks
  # the very node the model layer holds — and a second `MATCH` clause is
  # not needed (and not supported: a join is past the M5 contract).
  def edge!(from, type: "KNOWS", label: "Person", props: {})
    body = props.empty? ? "" : " {#{props.map { |k, v| "#{k}: '#{v}'" }.join(', ')}}"
    @db.exec("MATCH (a:#{from.class.label}) WHERE id(a) = $id " \
             "CREATE (a)-[:#{type}]->(b:#{label}#{body})",
             "id" => from.id)
  end

  # An edge from a freshly created node into an existing record.
  def edge_into!(to, type:, label: "Person", props: {})
    body = props.empty? ? "" : " {#{props.map { |k, v| "#{k}: '#{v}'" }.join(', ')}}"
    @db.exec("MATCH (b:#{to.class.label}) WHERE id(b) = $id " \
             "CREATE (a:#{label}#{body})-[:#{type}]->(b)",
             "id" => to.id)
  end

  # ---- lifecycle ------------------------------------------------------

  def test_new_is_not_persisted
    p = @person.new(name: "Ana", age: 34)
    refute p.persisted?
    assert p.new_record?
  end

  def test_save_persists_and_captures_the_id
    p = @person.new(name: "Ana", age: 34)
    assert p.save
    assert p.persisted?
    assert_operator p.id, :>, 0
  end

  def test_save_bang_raises_when_invalid
    p = @person.new(name: nil, age: 3)
    assert_raises(Glyphes::ValidationError) { p.save! }
  end

  def test_create_returns_nil_when_invalid_and_the_record_when_not
    assert_nil @person.create(name: nil, age: 3)
    assert @person.create(name: "Bo", age: 28)
  end

  def test_attributes_read_and_write
    p = @person.new(name: "Ana", age: 34)
    assert_equal "Ana", p.name
    p.name = "Anna"
    assert_equal "Anna", p.name
    assert_equal "Anna", p[:name]
  end

  def test_update_persists_the_change
    p = person!("Ana", 34)
    assert p.update(age: 35)
    assert_equal 35, @person.find(p.id).age
  end

  def test_update_bang_raises
    p = person!("Ana", 34)
    assert_raises(Glyphes::ValidationError) { p.update!(age: -1) }
  end

  def test_destroy_removes_the_record
    p = person!("Ana", 34)
    assert p.destroy
    refute p.persisted?
    assert_nil @person.find_by(name: "Ana")
  end

  def test_reload_rereads
    p = person!("Ana", 34)
    @db.exec("MATCH (n:Person) WHERE id(n) = $id SET n.name = 'Changed'",
              "id" => p.id)
    p.reload
    assert_equal "Changed", p.name
  end

  def test_touch_persists
    p = person!("Ana", 34)
    assert p.touch
  end

  def test_freeze_marks_the_record
    p = person!("Ana", 34)
    refute p.frozen?
    p.freeze
    assert p.frozen?
  end

  # ---- class verbs ----------------------------------------------------

  def test_find_raises_record_not_found
    assert_raises(Glyphes::RecordNotFound) { @person.find(999999) }
  end

  def test_find_by_returns_nil_when_missing
    assert_nil @person.find_by(name: "Nobody")
  end

  def test_first_and_last
    person!("Ana", 34)
    person!("Bo", 28)
    assert_equal "Ana", @person.order(:name).first.name
    assert_equal "Bo", @person.order(:name).last.name
  end

  def test_where_with_hash_and_string
    person!("Ana", 34)
    person!("Bo", 28)
    assert_equal 1, @person.where(age: 34).to_a.size
    assert_equal 1, @person.where("age >= $min", "min" => 30).to_a.size
  end

  def test_order_limit_offset
    5.times { |i| person!("P#{i}", 20 + i) }
    rel = @person.order(:age).limit(2)
    assert_equal 2, rel.to_a.size
    assert_equal [20, 21], rel.to_a.map(&:age)
    assert_equal 3, @person.offset(2).to_a.size
  end

  def test_pluck_returns_scalars_not_records
    person!("Ana", 34)
    names = @person.pluck(:name)
    assert_equal ["Ana"], names
  end

  def test_count_is_one_statement
    3.times { |i| person!("P#{i}", 20 + i) }
    assert_equal 3, @person.count
  end

  def test_exists_is_a_boolean_without_materializing
    person!("Ana", 34)
    assert @person.exists?(name: "Ana")
    refute @person.exists?(name: "Nobody")
  end

  def test_find_or_create_by
    p1 = @person.find_or_create_by(name: "Ana", age: 34)
    # find_or_create_by matches on *every* attribute given, so the lookup
    # passes only the identifying one. Asking for a different age is asking
    # for a different row — and a create, exactly as in Rails.
    p2 = @person.find_or_create_by(name: "Ana")
    assert_equal p1.id, p2.id   # the second call found the first
    assert_equal 34, p2.age     # and did not overwrite
  end

  def test_first_or_create
    assert_nil @person.first
    created = @person.first_or_create(name: "Ana", age: 34)
    assert created.persisted?
  end

  def test_update_all_is_one_statement
    3.times { |i| person!("P#{i}", 20 + i) }
    @person.update_all(city: "Lyon")
    assert_equal ["Lyon"], @person.pluck(:city).uniq
  end

  def test_delete_all
    3.times { |i| person!("P#{i}", 20 + i) }
    @person.delete_all
    assert_equal 0, @person.count
  end

  def test_destroy_all
    3.times { |i| person!("P#{i}", 20 + i) }
    @person.destroy_all
    assert_equal 0, @person.count
  end

  def test_upsert_merges
    @person.upsert({ name: "Ana", age: 34 }, { name: "Ana" })
    @person.upsert({ name: "Ana", city: "Lyon" }, { name: "Ana" })
    assert_equal 1, @person.count
    assert_equal "Lyon", @person.first.city
  end

  # ---- validations (R9) -----------------------------------------------

  def test_valid_populates_errors_in_rails_shape
    p = @person.new(name: nil, age: -1)
    refute p.valid?
    assert_equal ["can't be blank"], p.errors[:name]
    assert_equal ["must be greater than 0"], p.errors[:age]
  end

  def test_save_returns_false_and_writes_nothing_when_invalid
    p = @person.new(name: nil, age: 3)
    refute p.save
    assert_equal 0, @person.count
  end

  def test_validation_passes_and_clears_errors
    p = @person.new(name: nil, age: 1)
    refute p.valid?
    p.name = "Ana"
    assert p.valid?
    assert_empty p.errors
  end

  def test_save_bang_raises_with_all_messages
    p = @person.new(name: nil, age: -1)
    e = assert_raises(Glyphes::ValidationError) { p.save! }
    assert_match(/can't be blank/, e.message)
    assert_match(/greater than 0/, e.message)
    # The detail carries the Rails-shaped hash, so a caller can render it.
    assert_equal ["can't be blank"], e.detail[:name]
  end

  def test_uniqueness_is_delegated_to_a_constraint
    # The model does not check uniqueness in Ruby; the engine's constraint
    # does, and the error is a ConstraintError from the write.
    @db.exec("CREATE (:User {email: 'a@x'})")
    @db.index_create(kind: :range, label: "User", property: "email",
                     constraint: :unique)
    assert_raises(Glyphes::ConstraintError) do
      @db.exec("CREATE (:User {email: 'a@x'})")
    end
  end

  # ---- R5: a verb is one crossing -------------------------------------

  # R5 measures the *model layer's own* crossings, not the M4 seam's: one
  # `Database#query` is already several FFI calls (prepare, columns, step,
  # close), and that is the seam's business. What must be counted is the
  # `Database` verb a model verb issues, plus the view reads it does lazily
  # — the two places the model layer can add a crossing of its own.
  #
  # The counter sits on `Node`'s *reads*, not on the raw FFI symbols: one
  # `Node#properties` is a two-call cap protocol at the ABI (probe for the
  # length, then read), so counting FFI calls would measure the M7 seam
  # rather than this layer. R5 is about operations the model layer
  # performs. The module is installed once per process — `Glyphes::Node` is
  # a class, and prepending per test would stack counters and count every
  # read once per test that ever ran.
  CROSSINGS = []

  module ViewCounter
    def properties
      CROSSINGS << :properties
      super
    end

    def exist?
      CROSSINGS << :exist?
      super
    end
  end

  def crossings = CROSSINGS

  def db_counter(db)
    db.singleton_class.prepend(Module.new do
      define_method(:query) do |*a, **k|
        CROSSINGS << :query
        super(*a, **k)
      end
      define_method(:exec) do |*a, **k|
        CROSSINGS << :exec
        super(*a, **k)
      end
      define_method(:exec_returning) do |*a, **k|
        CROSSINGS << :exec_returning
        super(*a, **k)
      end
    end)
    db
  end

  def counting_ffi(db = @db)
    crossings.clear
    db_counter(db)
    # `properties` is an *instance* method of Node: the module goes on the
    # class, not on its singleton.
    Glyphes::Node.prepend(ViewCounter) unless
      Glyphes::Node.ancestors.include?(ViewCounter)
    crossings
  end

  def test_each_class_verb_is_one_crossing
    counting_ffi
    rec = @person.create!(name: "Ana", age: 34)
    assert_equal [:exec_returning], crossings      # the create, one crossing

    crossings.clear
    @person.where(age: 34).to_a
    assert_equal [:query], crossings                # the query, one crossing

    crossings.clear
    rec.reload
    # The query that finds the row, plus one read of it: reload is one
    # verb, and reading the row back is what reload *is*.
    assert_equal %i[query properties], crossings

    crossings.clear
    # A record the caller built already holds what it was assigned: no
    # crossing to read it back.
    assert_equal 34, rec.age
    assert_empty crossings

    crossings.clear
    # The one honest exception, pinned rather than hidden: an attribute a
    # *query* did not carry is a lazy read through the node view (pin Y5),
    # so it costs a crossing — for that record, when it is touched.
    queried = @person.where(age: 34).to_a.first
    crossings.clear
    assert_equal 34, queried.age
    assert_operator crossings.size, :>=, 1
  end

  def test_pluck_reads_a_whole_collection_in_one_crossing
    5.times { |i| person!("P#{i}", 20 + i) }
    counting_ffi
    assert_equal [20, 21, 22, 23, 24], @person.order(:age).pluck(:age)
    # pluck is the anti-N+1 door: scalars for the whole set, one crossing.
    assert_equal 1, crossings.size
  end

  def test_a_schema_change_clears_the_statement_caches
    @person.where(age: 34).to_a          # executed: the statement is cached
    refute_empty @person.statement_cache
    @db.index_create(kind: :range, label: "Person", property: "age")
    assert_empty @person.statement_cache
    assert_empty @like.statement_cache
  end

  def test_the_statement_cache_is_bounded
    # §9's open question, answered in code: a caller who interpolates user
    # input into `order` makes a new key per value, and the cache is the
    # one thing in this layer allowed to grow without a bound.
    600.times { |i| @person.order("field#{i}").to_a rescue nil }
    assert_operator @person.statement_cache.size, :<=,
                    @person::STATEMENT_CACHE_LIMIT
  end

  def test_a_relation_is_enumerable
    3.times { |i| person!("P#{i}", 20 + i) }
    rel = @person.order(:age)
    assert_kind_of Enumerable, rel
    assert_equal [20, 21, 22], rel.map(&:age)
    assert_equal ["P0"], rel.select { |r| r.age < 21 }.map(&:name)
    assert_equal 3, rel.count
  end

  # ---- the DSL as the contract writes it (RUBY.md §5.4) ----------------

  def test_validates_takes_the_rails_hash_form
    k = Class.new(Glyph::Base) do
      def self.name = "Doc"
      validates :title, presence: true
      validates :size, numericality: { greater_than: 0 }
    end
    d = k.new
    refute d.valid?
    assert_equal ["can't be blank"], d.errors[:title]
    # nil is not a number — Rails reads it that way too, and reading it as
    # "only checked when present" would let a blank field through.
    assert_equal ["is not a number"], d.errors[:size]
    zero = k.new(title: "t", size: 0)
    refute zero.valid?
    assert_equal ["must be greater than 0"], zero.errors[:size]
    assert k.new(title: "t", size: 1).valid?
  end

  def test_validates_rejects_a_name_that_is_not_a_validator
    k = Class.new(Glyph::Base) do
      def self.name = "Doc"
    end
    # A typo must not read as "this field is validated by nothing".
    assert_raises(ArgumentError) { k.validates(:title, presnce: true) }
  end

  def test_every_validator_kind_runs_before_the_write
    k = Class.new(Glyph::Base) do
      def self.name = "Thing"
      validates :city, inclusion: { in: %w[Lyon Nice] }
      validates :bio, length: { minimum: 3 }
      validates :email, format: { with: /@/ }
    end
    t = k.new(city: "Paris", bio: "x", email: "nope")
    refute t.valid?
    assert_equal ["is not included in the list"], t.errors[:city]
    assert_equal ["is too short (minimum is 3 characters)"], t.errors[:bio]
    assert_equal ["is invalid"], t.errors[:email]
    refute t.save
    assert_equal 0, k.count            # the door: nothing was written
  end

  def test_uniqueness_is_the_engine_not_a_ruby_check
    k = Class.new(Glyph::Base) do
      def self.name = "Acct"
      validates :email, uniqueness: true
    end
    @db.index_create(kind: :range, label: "Acct", property: "email",
                     constraint: :unique)
    k.create!(email: "a@x")
    # The validation itself passes — there is no Ruby-side raceable check.
    assert k.new(email: "a@x").valid?
    # The *constraint* is what makes it false, and it fails at the write.
    assert_raises(Glyphes::ConstraintError) { k.create!(email: "a@x") }
  end

  def test_scope_is_a_chainable_relation
    k = Class.new(Glyph::Base) do
      def self.name = "Ppl"
      scope :adults, -> { where("age >= $min", { "min" => 18 }) }
    end
    k.create!(name: "Ana", age: 34)
    k.create!(name: "Bo", age: 12)
    assert_kind_of Glyph::Relation, k.adults
    assert_equal ["Ana"], k.adults.to_a.map(&:name)
    assert_match(/WHERE n\.age >= \$min/, k.adults.to_cypher)
    assert_equal({ "min" => 18 }, k.adults.to_params)
    assert_equal 2, k.count
  end

  def test_callbacks_run_around_the_write
    k = Class.new(Glyph::Base) do
      def self.name = "Cb"
      before_save { |rec| rec.name = rec.name.to_s.strip }
    end
    rec = k.create!(name: "  Ana  ")
    assert_equal "Ana", k.find(rec.id).name
  end

  # ---- ordering and limits (R10) --------------------------------------

  def test_first_n_puts_the_limit_in_the_statement
    5.times { |i| person!("P#{i}", 20 + i) }
    rel = @person.order(:age).first(2)
    # R10: the five arrive as LIMIT 2, not as "everything, keep two".
    assert_match(/LIMIT 2/, rel.to_cypher)
    assert_equal [20, 21], rel.to_a.map(&:age)
    assert_equal 20, @person.order(:age).first.age
  end

  def test_last_is_a_reverse_order_in_the_statement
    person!("Ana", 34)
    person!("Bo", 28)
    # `last` reverses and limits, so the engine answers it; the relation
    # is not materialized in Ruby and sliced.
    rel = @person.order(:age).reverse_order.limit(1)
    assert_match(/ORDER BY n\.age DESC LIMIT 1/, rel.to_cypher)
    # Unordered `last` is insertion order reversed, which is only possible
    # because the store's id is the expression `id(n)` — not a property.
    assert_match(/ORDER BY id\(n\) DESC LIMIT 1/,
                 @person.all.reverse_order.limit(1).to_cypher)
    assert_equal "Bo", @person.last.name
    # Ordered by age, "last" is the oldest row (Ana) — the reverse of the
    # same statement, not the end of the scan.
    assert_equal "Ana", @person.order(:age).last.name
  end

  # ---- associations (R10) ---------------------------------------------

  def test_an_association_is_lazy_not_an_array
    p = person!("Ana", 34)
    assert_kind_of Glyph::Relation, p.knows
  end

  def test_has_many_traverses
    ana = person!("Ana", 34)
    # Attach to the node `person!` returned. `CREATE (a:Person {name:
    # 'Ana'})…` would make a *second* Ana, and the association reads from
    # the first — a fixture that silently proves nothing.
    edge!(ana, props: { name: "Bo" })
    assert_equal ["Bo"], ana.knows.to_a.map(&:name)
  end

  def test_has_many_limit_is_in_the_statement
    ana = person!("Ana", 34)
    3.times { |i| edge!(ana, props: { name: "B#{i}" }) }
    # R10: `.first(2)` issues LIMIT 2. Assert on the compiled statement, not
    # on timing — the point is that the LIMIT is in the query.
    rel = ana.knows.limit(2)
    assert_match(/LIMIT 2/, rel.to_cypher)
    assert_equal 2, rel.to_a.size
  end

  def test_belongs_to_points_back
    ana = person!("Ana", 34)
    bo = person!("Bo", 28)
    edge_into!(bo, type: "AUTHORED_BY", props: { name: "Ana" })
    @person.class_eval { belongs_to :author, class_name: "Person", type: "AUTHORED_BY" }
    assert_equal "Ana", bo.author.to_a.first.name
  end

  def test_has_one_returns_at_most_one
    ana = person!("Ana", 34)
    edge!(ana, type: "HAS_PROFILE", label: "Profile", props: { bio: "hi" })
    assert_equal 1, ana.profile.to_a.size
  end

  # ---- review regressions: the qualifier, the door, the view -----------

  def test_the_qualifier_leaves_keywords_and_literals_alone
    person!("ana", 34)
    person!("bo", 28)
    # The first qualifier turned `true` into `n.true` and the word inside
    # 'ana' into 'n.ana' — both compiled, both answered zero rows, and
    # nothing anywhere said why.
    assert_equal 1, @person.where("name = 'ana'").to_a.size
    assert_equal 1, @person.where("age >= 30 and name = 'ana'").to_a.size
    assert_equal 2, @person.where("name IS NOT NULL").to_a.size
  end

  def test_where_nil_is_is_null_not_a_null_comparison
    k = Class.new(Glyph::Base) { def self.name = "Naked" }
    @db.exec("CREATE (:Naked {name: 'ghost'})")
    @db.exec("CREATE (:Naked {name: 'real', age: 5})")
    # `where(age: nil)` is Rails for "the field is absent". `n.age = null`
    # is never true in Cypher; the literal translation answers zero rows
    # for every absent field, silently.
    assert_equal ["ghost"], k.where(age: nil).to_a.map(&:name)
    assert_empty k.where(name: nil).to_a
  end

  def test_an_association_can_be_ordered_and_lasted
    k = Class.new(Glyph::Base) do
      def self.name = "Assoc"
      has_many :knows, class_name: "Person", type: "KNOWS"
    end
    from = k.create!(name: "from")
    edge!(from, props: { name: "first" })
    edge!(from, props: { name: "second" })
    # `last` reverses by the store's id, which is `id(b)` here — the first
    # version emitted `b.id(n)`, a property of a variable the MATCH never
    # bound, and the one verb that reaches the path raised.
    assert_equal "second", from.knows.last.name
    # `order(:id)` is the store id here, the Rails reading of a primary-key
    # order — not "a property named id", which sorts as null and orders
    # arbitrarily.
    assert_equal %w[second first], from.knows.order(:id, :desc).to_a.map(&:name)
    assert_equal %w[first second], from.knows.order(:name).to_a.map(&:name)
  end

  def test_upsert_is_one_crossing
    crossings = counting_ffi
    crossings.clear
    @person.upsert({ name: "zed", age: 9 }, { name: "zed" })
    # The MERGE answers the id; building the record from it needs no query.
    assert_equal [:exec_returning], crossings
  end

  def test_a_lazy_read_is_not_a_change_and_update_hydrates
    person!("ana", 34)
    q = @person.where(age: 34).to_a.first
    refute q.changed?
    q.age                                  # a read, not an edit
    refute q.changed?
    # update on a not-yet-hydrated record used to validate nils the row
    # does not have — age: -1 passed, name: presence failed on a name the
    # node actually has.
    assert q.update(age: 40)
    assert_equal 40, @person.find(q.id).age
    assert_equal "ana", @person.find(q.id).name
  end

  def test_freeze_is_ruby_freeze
    p = person!("ana", 34)
    p.freeze
    assert p.frozen?
    assert_raises(FrozenError) { p.name = "hacked" }
    assert_raises(FrozenError) { p.save }
    # The fake freeze before it set a flag and let a "frozen" record write
    # to the store.
    refute @person.exists?(name: "hacked")
    assert @person.exists?(name: "ana")
  end

  def test_touch_goes_through_the_validation_door
    p = person!("ana", 34)
    p.age = -1                             # an edit nobody asked to save
    refute p.touch                         # the door holds
    assert_equal 34, @person.find(p.id).age
    p.age = 35
    assert p.touch
    assert_equal 35, @person.find(p.id).age
  end

  def test_names_that_are_not_identifiers_are_refused
    person!("ana", 34)
    # Every one of these is interpolated into statement text; a name that
    # is not a bare identifier is an injection, refused by name.
    assert_raises(ArgumentError) { @person.where("x OR n.name" => "ana").to_a }
    assert_raises(ArgumentError) { @person.order("age; DETACH DELETE n").to_a }
    assert_raises(ArgumentError) { @person.pluck("age DETACH") }
    assert_raises(ArgumentError) { @person.update_all("a b" => 1) }
    assert_raises(ArgumentError) { @person.upsert({ "a b" => 1 }) }
    assert_raises(ArgumentError) { @person.label("1bad") }
    assert_raises(ArgumentError) { person!("ana", 34)["a b"] = 1 }
  end

  def test_the_statement_cache_is_keyed_by_shape_not_by_values
    k = Class.new(Glyph::Base) { def self.name = "Shaped" }
    k.create!(name: "a", age: 1)
    k.where(age: 1).to_a
    k.where(age: 2).to_a
    k.where(age: 3).to_a
    # Same shape, different values: one entry. Keyed by values, an app
    # filtering on a moving value got no reuse out of the one cache §0
    # allows.
    assert_equal 1, k.statement_cache.size
  end

  # ---- statement cache (R5, §5.2) ------------------------------------

  def test_the_statement_cache_is_per_class_and_deterministic
    @person.where(age: 1).to_a
    rel1 = @person.where(age: 1)
    rel2 = @person.where(age: 2)
    # Same inputs, same statement: the cache is keyed by the compiled text,
    # and it holds statements, never data. Different inputs compile to
    # different statements — so the key has to include them.
    assert_equal rel1.inspect, @person.where(age: 1).inspect
    # A different *field* must be a different key, or the cache returns one
    # query's statement for another's params.
    refute_equal @person.where(age: 1).inspect, @person.where(name: "x").inspect
  end
end
