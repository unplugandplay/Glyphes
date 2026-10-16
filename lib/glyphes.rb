# frozen_string_literal: true

# glyphes — the SQLite of graphs.
#
# An embeddable labeled property graph: one file, one process,
# ActiveRecord-shaped, with vector and text search in the same statement
# as the traversal. See docs/PRD-GLYPHES.md.
#
#   require "glyphes"
#
#   Glyphes::Database.open("social.glyph", create: true) do |db|
#     db.stat[:generation]
#   end
#
# M0 ships the open/close/stat surface only. Statements, transactions and
# Cypher arrive at M3-M5 (docs/CYPHER.md, docs/EXEC.md), indexes at M6.

require "json"

require_relative "glyphes/version"
require_relative "glyphes/ffi"
require_relative "glyphes/errors"
require_relative "glyphes/cell"
require_relative "glyphes/node"
require_relative "glyphes/statement"
require_relative "glyphes/ident"
require_relative "glyphes/database"
require_relative "glyphes/follower"
require_relative "glyphes/validations"
require_relative "glyphes/relations"
require_relative "glyphes/active_record"

# Glyphes::VERSION is defined once, in version.rb (RUBY.md §1). A second
# definition here would be a constant that could drift from the first.
