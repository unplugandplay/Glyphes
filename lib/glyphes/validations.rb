## glyphes — the validation registry (RUBY.md §5.4)
##
## `Glyph::Base` runs these before it issues a write, so a validation
## failure means *nothing was written* — not "written and rolled back", not
## "written and warned about". The door is the whole point: a model
## `save` is the moment the graph is allowed to change, and validation is
## what decides whether it does.
##
## Uniqueness is the one validator that is NOT here, and its absence is the
## design: a `uniqueness` validation is *delegated to a real uniqueness
## constraint in the engine* (TXN.md §5). A Ruby-side uniqueness check is a
## check that can be raced (two callers both pass it, both write) and is a
## different mechanism from the one that actually makes uniqueness true.
## `validates :email, :uniqueness` is accepted and installed as a *reminder
## that a constraint should exist* — and the engine is the thing that
## enforces it, which is why the error surfaces as `ConstraintError` from
## the write, not as a Ruby error.

module Glyph
  # Holds the `validates` DSL per field and runs the checks. Kept in its
  # own file (RUBY.md §1's layout) so the validators read as a list —
  # adding one is a case here, not a change to Base.
  module Validations
    # field => [[kind, opts], …]. Order is declaration order: the first
    # failure message per field is the one Rails shows.
    # `validates :name, presence: true` (the Rails form the contract
    # documents) and `validates :name, :presence` are the same declaration;
    # the first takes several validators in one call
    # (`validates :name, presence: true, length: { minimum: 2 }`), which is
    # why this is not just `def validates(field, kind, opts = {})`.
    KINDS = %i[presence inclusion numericality length format uniqueness].freeze

    def validates(field, kind = nil, opts = {}, **kw)
      field = field.to_sym
      (@validations ||= {})[field] ||= []
      if kind
        # `validates :age, :numericality, greater_than: 0` — the trailing
        # keywords are *this validator's* options. Ruby hands them over as
        # `**kw` whatever the caller wrote, so they join `opts` when a kind
        # was named. Reading them as extra validators registered a
        # `greater_than` "validator" and dropped the rule that mattered.
        @validations[field] << [kind.to_sym, opts.merge(kw)]
      else
        # `validates :name, presence: true` and
        # `validates :age, numericality: { greater_than: 0 }`:
        # `{kind => options}`. `true` is the empty option set, not an
        # argument. A key that is not a validator is a typo, and silently
        # validating nothing is the worst possible reading of one.
        kw.each do |k, v|
          unless KINDS.include?(k.to_sym)
            raise ArgumentError,
                  "validates: #{k.inspect} is not a validator " \
                  "(#{KINDS.join(', ')})"
          end

          @validations[field] << [k.to_sym, v.is_a?(Hash) ? v : {}]
        end
      end
    end

    # The single place a kind becomes a check. Returns a message string or
    # nil — the Rails `errors` shape is field → [messages], and a
    # validator that returned a truthy value instead of a message would put
    # "true" in a user's error list.
    def validate_field(field, kind, opts, value)
      case kind
      when :presence
        if blank?(value)
          "can't be blank"
        end
      when :inclusion
        opts.fetch(:in).include?(value) ? nil : "is not included in the list"
      when :numericality
        validate_numericality(value, opts)
      when :length
        validate_length(value, opts)
      when :format
        value.to_s.match?(opts.fetch(:with)) ? nil : "is invalid"
      when :uniqueness
        # Installed as a marker; enforcement is the engine's constraint.
        # The check itself returns nil here — the write is what fails, with
        # a ConstraintError naming the value and the conflicting key.
        nil
      end
    end

    private

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    def validate_numericality(value, opts)
      unless value.is_a?(Numeric)
        return "is not a number"
      end

      if opts[:greater_than] && value <= opts[:greater_than]
        "must be greater than #{opts[:greater_than]}"
      elsif opts[:less_than] && value >= opts[:less_than]
        "must be less than #{opts[:less_than]}"
      elsif opts[:greater_than_or_equal_to] && value < opts[:greater_than_or_equal_to]
        "must be greater than or equal to #{opts[:greater_than_or_equal_to]}"
      elsif opts[:less_than_or_equal_to] && value > opts[:less_than_or_equal_to]
        "must be less than or equal to #{opts[:less_than_or_equal_to]}"
      end
    end

    def validate_length(value, opts)
      length = value.to_s.length
      if opts[:minimum] && length < opts[:minimum]
        "is too short (minimum is #{opts[:minimum]} characters)"
      elsif opts[:maximum] && length > opts[:maximum]
        "is too long (maximum is #{opts[:maximum]} characters)"
      elsif opts[:is] && length != opts[:is]
        "is the wrong length (should be #{opts[:is]} characters)"
      end
    end
  end
end