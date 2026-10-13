# frozen_string_literal: true
require_relative "lib/glyphes/version"

Gem::Specification.new do |spec|
  spec.name = "glyphes"
  spec.version = Glyphes::VERSION
  spec.summary = "A graph database with keyword and vector retrieval in Cypher"
  spec.description = <<~DESC
    glyphes is an embedded graph database: one file, one writer, a Cypher
    surface, and three index families behind the same registry — a range
    index for predicates, an inverted index with BM25 for keywords, and an
    HNSW index for vectors. A constraint is not a second mechanism; it is
    one of those indexes with a second client.
  DESC
  spec.authors = ["glyphes"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir[
    "lib/**/*.rb",
    "src/glyphes.h",
    "docs/*.md",
    "glyphes.nimble",
    "*.gemspec"
  ]
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/glyphes.rb"]

  # The engine is a shared library the FFI binding loads; it is built with
  # `nimble buildLib` (or `nimble gate`), not by `gem install`. That is why
  # this is an FFI gem and not a C extension: the .so is a build artifact,
  # not a compiled source of ours (RUBY.md §1 — ffi.rb is the only file that
  # knows FFI exists).
  spec.add_dependency "ffi", "~> 1.17"
end
