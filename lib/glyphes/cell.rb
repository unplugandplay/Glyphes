## glyphes — the value classes a cell materializes as (RUBY.md §4.1)
##
## The scalar tags cross as Ruby scalars (`nil`, `true`, Integer, Float,
## String) — there is nothing to wrap, and wrapping them would make
## `row.n == 30` false for no reason a caller could see. The three that
## carry *identity* or *structure* get a class, because a bare Integer for
## a node makes `row.n.properties` a NoMethodError three frames away, and a
## bare Array for a vector makes its type unrecoverable.

module Glyphes
  # A `GLY_VECTOR` cell. The payload crosses as float64s (the property
  # model stores f32; the ABI widens), so the elements are Floats — Ruby
  # has no f32 and a Float that silently rounded to f32 would make the
  # vector index's f32 arithmetic disagree with what Ruby scored.
  class Vector
    include Enumerable

    def initialize(values)
      @values = values
    end

    def each(&block) = @values.each(&block)
    def size = @values.size
    def length = @values.size
    def [](i) = @values[i]
    def to_a = @values.dup
    def first = @values.first
    def to_f = raise(ArgumentError, "a #{size}-dim vector is not a number")

    # Dot product with another vector or an array — the one operation
    # callers reach for, and doing it here keeps the f32-origin story
    # (see the file header) in one place instead of every call site.
    def dot(other)
      o = other.is_a?(Vector) ? other.to_a : other
      raise ArgumentError, "dimension mismatch" if o.size != size

      @values.zip(o).sum { |a, b| a * b }
    end

    def ==(other)
      case other
      when Vector then to_a == other.to_a
      when Array  then to_a == other
      else false
      end
    end

    def inspect = "#<Glyphes::Vector [#{@values.join(', ')}]>"
  end

  # A `GLY_POINT` cell: two float64, cartesian (CYPHER.md §6.4).
  #
  # A value class rather than a two-element Array, for the same reason
  # Vector is one: `p.distance_to(q)` is what callers reach for, and an
  # Array would make it a NoMethodError three frames away.
  class Point
    attr_reader :x, :y

    def initialize(x, y)
      @x = x
      @y = y
    end

    def distance_to(other)
      o = other.is_a?(Point) ? other : Point.new(*other)
      Math.sqrt((x - o.x)**2 + (y - o.y)**2)
    end

    def ==(other)
      other.is_a?(Point) && x == other.x && y == other.y
    end

    def to_s = "point({x: #{x.to_f}, y: #{y.to_f}})"
    def inspect = "#<Glyphes::Point (#{x.to_f}, #{y.to_f})>"
  end

  # A `GLY_PATH` cell: the nodes in traversal order, the edges between
  # them, and each edge's direction (0 = src→dst, 1 = dst→src).
  #
  # **No query produces one yet** — `MATCH p = (…)` is refused at parse
  # (CYPHER.md §2.6), and the variable-length walk binds a relationship
  # *list* rather than a path. The class and the ABI accessors are built
  # (ABI.md §2's settled representation) so that when path binding lands,
  # this is where the value arrives rather than a gap discovered then.
  class Path
    include Enumerable

    def initialize(nodes, edges, dirs)
      @nodes = nodes
      @edges = edges
      @dirs = dirs
    end

    def length = @nodes.size
    alias size length

    def nodes = @nodes.dup
    def relationships = @edges.dup

    # Each step as [edge_id, direction]; direction 0 is src→dst.
    def each_step
      return enum_for(:each_step) unless block_given?

      @edges.each_with_index { |e, i| yield e, @dirs[i] }
    end

    def each(&block)
      return enum_for(:each) unless block_given?

      @nodes.each(&block)
    end

    def [](i) = @nodes[i]
    def to_a = @nodes.dup
    def inspect = "#<Glyphes::Path #{length} nodes>"
  end
end
