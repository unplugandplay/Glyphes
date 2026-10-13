# frozen_string_literal: true
#
# The RubyGems extension stub (RUBY.md §1: "not an FFI shim").
#
# `gem install` evaluates this file before `require "glyphes"`. Its one job
# is to make the build visible: if the engine library has not been built,
# failing here with a sentence that says how to build it beats failing later
# inside ffi.rb with `could not open library`. A missing extension that
# silently does nothing produces the worst error a gem can produce — the
# require appears to work and every call raises.

engine = File.expand_path("../lib/libglyphes.so", __dir__)
engine_dylib = File.expand_path("../lib/libglyphes.dylib", __dir__)

unless File.exist?(engine) || File.exist?(engine_dylib)
  warn <<~MSG
    glyphes: the engine library is missing.

      Build it with:

        nimble buildLib        # or: nimble gate

      It compiles src/glyphes.nim into lib/libglyphes.so, which this gem
      loads through FFI. The Ruby files alone are a binding to nothing.
  MSG
  # Not a hard failure here: `require "glyphes"` gives the clearer error at
  # the FFI::Library line, and a hard raise would break `gem install` in
  # environments that build the .so out of band (a packaging pipeline, a
  # platform gem). The warning is the contract; the error is ffi.rb's.
end
