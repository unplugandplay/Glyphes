# glyphes — the error hierarchy (RUBY.md §2).
#
# One class per GlyStatus error code, so a caller can rescue the
# specific failure and not "anything from the database". Gate R1: every
# status value is reachable from Ruby with its own class.

module Glyphes
  class Error < StandardError
    # The GlyStatus value that produced this error, for callers that
    # want to branch on the code rather than the class.
    attr_reader :status

    # Engine message, verbatim. Never empty for an error that came from
    # the engine — a bare "ERR" tells a caller nothing.
    attr_reader :detail

    def initialize(message, status:, detail: nil)
      @status = status
      @detail = detail
      super(message)
    end
  end

  # GLY_ERR_SQL: Cypher parse or semantic error.
  class SqlError < Error; end

  # GLY_ERR_UNSUPPORTED: valid Cypher, outside the 0.1 contract. The
  # message names the construct and cites docs/CYPHER.md (CYPHER.md §0).
  class UnsupportedError < Error; end

  # GLY_ERR_CONSTRAINT: uniqueness / not-null violation. `detail` carries
  # the offending value and the conflicting key, because "constraint
  # failed" in a 10^6-row import says nothing about which row to fix.
  class ConstraintError < Error
    attr_reader :offending_value, :conflicting_key

    def initialize(message, status:, detail: nil,
                   offending_value: nil, conflicting_key: nil)
      super(message, status: status, detail: detail)
      @offending_value = offending_value
      @conflicting_key = conflicting_key
    end
  end

  # GLY_ERR_CLOSED and GLY_ERR_STALE: a handle or a Cell outlived what
  # owns it. This is the class that turns an FFI lifetime mistake into a
  # Ruby exception instead of a segfault (ABI.md B3, RUBY.md Y4).
  class ClosedError < Error; end

  # GLY_ERR_BUSY: a second concurrent transaction (TXN.md §1).
  class BusyError < Error; end

  # GLY_ERR_IO: WAL or snapshot filesystem error (WAL.md §6).
  class IoError < Error; end

  # GLY_ERR_LIMIT: a configured budget was exceeded (TXN.md §6).
  class LimitError < Error; end

  # GLY_ERR_READONLY: a write attempted on a read-only database.
  class ReadOnlyError < Error; end

  # GLY_ERR_NOMEM.
  class MemoryError < Error; end

  # GLY_ERR_CORRUPT: the database file is damaged — a frame or a snapshot
  # region failed its CRC, or a magic did not match. It is its own class
  # because it is the one failure where the *only* useful response is to
  # restore a backup, and a host that cannot tell it from an I/O error will
  # retry a file that will never open. A torn tail is not this: that is a
  # frame that was never finished, it is dropped, and the database opens.
  class CorruptError < Error
    def initialize(msg = nil, status: nil, detail: nil)
      super(msg || "glyphes: the database file is damaged",
            status: status || FFI::GLY_ERR_CORRUPT, detail: detail)
    end
  end

  # GLY_ERR: the generic failure, and the class for any status the
  # engine could not classify. A test asserts no *other* status degrades
  # to this one by omission.
  class InternalError < Error; end

  # Rails' `ActiveRecord::RecordNotFound`, by name: `find` of a missing
  # record raises this, `find_by` returns nil. The distinction is the whole
  # point of having both verbs, so it is one class rather than a status a
  # caller has to decode.
  class RecordNotFound < Error
    def initialize(message, detail: nil)
      super(message, status: FFI::GLY_ERR_SQL, detail: detail)
    end
  end

  # Raised by the model layer's validation door before a write is issued
  # (RUBY.md §5.4). Not an engine status: no engine call was made.
    class ValidationError < Error
    # The Rails-shaped {field => [messages]} hash (R9), so a caller can
    # render it without parsing the message.
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      summary = errors.map { |field, msgs| "#{field} #{msgs.join(', ')}" }.join("; ")
      # No engine status: nothing was sent. SQL says "the statement was
      # refused", which is what happened, without pretending an engine
      # call returned it.
      super(summary, status: FFI::GLY_ERR_SQL, detail: errors)
    end
  end

  module ErrorMapping
    BY_STATUS = {
      FFI::GLY_ERR             => InternalError,
      FFI::GLY_ERR_CLOSED      => ClosedError,
      FFI::GLY_ERR_STALE       => ClosedError,
      FFI::GLY_ERR_SQL         => SqlError,
      FFI::GLY_ERR_CONSTRAINT  => ConstraintError,
      FFI::GLY_ERR_IO          => IoError,
      FFI::GLY_ERR_READONLY    => ReadOnlyError,
      FFI::GLY_ERR_BUSY        => BusyError,
      FFI::GLY_ERR_LIMIT       => LimitError,
      FFI::GLY_ERR_NOMEM       => MemoryError,
      FFI::GLY_ERR_UNSUPPORTED => UnsupportedError,
      FFI::GLY_ERR_CORRUPT     => CorruptError
    }.freeze

    NAMES = {
      FFI::GLY_ERR             => "GLY_ERR",
      FFI::GLY_ERR_CLOSED      => "GLY_ERR_CLOSED",
      FFI::GLY_ERR_STALE       => "GLY_ERR_STALE",
      FFI::GLY_ERR_SQL         => "GLY_ERR_SQL",
      FFI::GLY_ERR_CONSTRAINT  => "GLY_ERR_CONSTRAINT",
      FFI::GLY_ERR_IO          => "GLY_ERR_IO",
      FFI::GLY_ERR_READONLY    => "GLY_ERR_READONLY",
      FFI::GLY_ERR_BUSY        => "GLY_ERR_BUSY",
      FFI::GLY_ERR_LIMIT       => "GLY_ERR_LIMIT",
      FFI::GLY_ERR_NOMEM       => "GLY_ERR_NOMEM",
      FFI::GLY_ERR_UNSUPPORTED => "GLY_ERR_UNSUPPORTED",
      FFI::GLY_ERR_CORRUPT     => "GLY_ERR_CORRUPT"
    }.freeze
  end
end
