## glyphes — the identifier guard
##
## Property names, order fields and labels are interpolated into statement
## text, because that is what a statement is. A name that is not a bare
## identifier is therefore not a query — it is an injection — and it is
## refused here, by name, at every point that interpolates one. The engine
## runs one statement per call, so the damage an injected fragment can do
## is bounded only by what that one statement can say, and a DETACH DELETE
## fits.
##
## It lives at the `Glyphes` level rather than under `Glyph` because the
## import layer needs it too: an import builds `CREATE (:Label {k: $k})`
## from a file's header, and a header is data.

module Glyphes
  module Ident
    PATTERN = /\A[a-zA-Z_][a-zA-Z_0-9]*\z/

    # Returns the name when it is a bare identifier, raises otherwise. The
    # message says what was refused and what would have been accepted: a
    # caller who typed `nmae` or `age; DETACH DELETE n` should not have to
    # guess which one was the problem.
    def self.assert!(name, what = "identifier")
      n = name.to_s
      return n if n.match?(PATTERN)

      raise ArgumentError,
            "#{what} #{n.inspect} is not a bare identifier " \
            "(letters, digits and underscore, not starting with a digit)"
    end
  end
end