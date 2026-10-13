# Runner for the Ruby surface tests. Zero gems beyond minitest, which
# ships with Ruby (TESTING.md: no new dependencies, PRD pin P2).

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

Dir[File.expand_path("test_*.rb", __dir__)].sort.each { |f| require f }
