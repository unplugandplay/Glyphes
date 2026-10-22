# The two value types X5 added, as a *host* sees them.
#
# The engine's rule (pin C19) is that a value crosses the ABI without
# becoming text — and the binding's side of that rule is this file. A
# point that crossed as `0` would be a wrong answer the engine never
# gave, produced by the binding reading the wrong field.

require "minitest/autorun"
require "date"
require_relative "../../lib/glyphes"

class TypesTest < Minitest::Test
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

  def one(sql)
    @db.query(sql).to_a.first.first
  end

  def test_a_date_crosses_as_a_ruby_date
    d = one("RETURN date('2026-10-21') AS d")
    assert_instance_of Date, d
    assert_equal [2026, 10, 21], [d.year, d.month, d.day]
    assert_equal "2026-10-21", d.iso8601
  end

  def test_a_point_crosses_as_a_point
    p = one("RETURN point({x: 1.0, y: 2.0}) AS p")
    assert_instance_of Glyphes::Point, p
    assert_in_delta 1.0, p.x
    assert_in_delta 2.0, p.y
    assert_equal "point({x: 1.0, y: 2.0})", p.to_s
    assert_equal p, Glyphes::Point.new(1.0, 2.0)
  end

  def test_a_point_is_not_a_silent_zero
    ## The bug this file exists for: a GLY_POINT cell has `aux = 0` and
    ## its coordinates in `ptr`, so the binding's `else` answered 0.
    p = one("RETURN point({x: 0.0, y: 3.5}) AS p")
    refute_equal 0, p
    assert_in_delta 3.5, p.y
  end

  def test_the_distance_is_the_cartesian_one
    d = one("RETURN point.distance(point({x: 0, y: 0}), point({x: 3, y: 4})) AS d")
    assert_in_delta 5.0, d
    p = Glyphes::Point.new(0.0, 0.0)
    assert_in_delta 5.0, p.distance_to(Glyphes::Point.new(3.0, 4.0))
  end
end
