## glyphes — import and export (RUBY.md §6)
##
## The engine never sees a file format (`PRD.md` P9). A CSV row is a Ruby
## string that Ruby's CSV parses; a Parquet page is bytes this layer lays
## down itself. What crosses the boundary is Cypher and parameter maps, and
## nothing else — which is why the whole of this file is plain Ruby.
##
## Three properties shape every line:
##
##   **One transaction.** The whole file, not each batch (Y12). A
##   half-imported file is the worst outcome a bulk load can have: it looks
##   like a completed import, and nothing says which half is real.
##
##   **Batched.** `exec` runs per `batch:` (default 5 000). One statement
##   per row would be 10^6 round-trips for the R8 gate; one statement for
##   the file is a query the parser cannot plan. The batch is the unit.
##
##   **No silent drops** (Y13, gate R11). A column nobody asked for is an
##   error, not a skip: a typo in a header (`nmae` for `name`) is exactly
##   the bug that loses data with no error anywhere.

require "csv"
require "json"

require "glyphes/parquet"

module Glyphes
  # `db.import` / `db.export`, as their own module so the Database surface
  # stays a list of verbs rather than a second implementation inline.
  module ImportExport
    # The default batch size. Five thousand rows is a statement the planner
    # handles and a parameter map that still fits in the engine's message;
    # both ends of that range are guesses a benchmark settles, not axioms.
    DEFAULT_BATCH = 5_000

    # ---- import -------------------------------------------------------

    # db.import "people.csv", into: :Person, keys: %i[name city age]
    #
    # Returns the number of rows written.
    def import(path, into:, keys: nil, skip: 0, types: {}, batch: DEFAULT_BATCH,
               vector: nil, dim: nil)
      format = format_of(path)
      columns, rows = read_rows(path, format, skip: skip, keys: keys)
      check_keys!(columns, keys)
      coerced = rows.each_with_index.map { |row, i| coerce_row(row, types, path, i) }
      check_vector_width!(coerced, vector, dim, path) if vector

      label = Ident.assert!(into, "label")
      vector_name = prepare_vector(label, vector, dim)

      written = 0
      transaction do
        coerced.each_slice(batch) do |slice|
          slice.each { |row| write_node(label, row) }
          written += slice.length
        end
        # Y12 / §6.1: create → import → `index_build`, never
        # create-with-index-live. Building once at the end is 10–40x
        # faster than maintaining the index per row, and it is the same
        # graph either way.
        index_build(vector_name) if vector_name
      end
      written
    end

    # One CREATE per row. A batch is a transaction boundary, not a
    # multi-row statement: the grammar has no multi-create, and inventing
    # one for the import path would mean two ways to write a node in the
    # engine. Values travel as *parameters* — a CSV cell is data, and data
    # in statement text is an injection (M8 review).
    def write_node(label, row)
      props = row.reject { |_, v| v.nil? }
      if props.empty?
        return exec("CREATE (:#{label})")
      end

      props.each_key { |k| Ident.assert!(k, "attribute") }
      pairs = props.keys.map { |k| "#{k}: $#{k}" }.join(", ")
      exec("CREATE (:#{label} { #{pairs} })", props)
    end

    # `vector:` names the property to index and `dim:` its width. The
    # index is created before the rows so the file is searchable the moment
    # the import returns, and built after the load (Y12).
    def prepare_vector(label, vector, dim)
      return nil if vector.nil?

      if dim.nil?
        raise ArgumentError, "import: vector: needs dim: (the vector width)"
      end

      index_create(kind: :vector, label: label.to_s, property: vector.to_s,
                   dim: dim)
    end

    # Read a file into [column_names, rows_of_hashes]. The formats share
    # this shape, which is the only reason the rest of the import does not
    # care which one it was handed.
    def read_rows(path, format, skip: 0, keys: nil)
      case format
      when :csv     then read_csv(path, skip: skip, keys: keys)
      when :jsonl   then read_jsonl(path, keys: keys)
      when :parquet then read_parquet(path)
      else
        raise ArgumentError, "import: #{format} is not a format this gem reads"
      end
    end

    # The columns this function returns are always the file's *actual*
    # headers. `keys:` selects and orders after the R11 check runs against
    # them — returning the requested keys instead (the first version) made
    # the check compare the keys with themselves, so it never fired and a
    # misspelled header silently dropped its column: the exact failure
    # Y13 forbids, wearing a test that said it was covered.
    # `skip:` skips leading *lines* and the line after them is the header
    # (RUBY.md §6.1: "skip: handles headers"). A file with a comment or a
    # title row before the real header needs the header to be found *after*
    # the skip — reading the first line as the header regardless turns those
    # junk lines into column names.
    def read_csv(path, skip:, keys:)
      headers = nil
      rows = []
      lines = 0
      CSV.foreach(path) do |record|
        lines += 1
        if headers.nil?
          headers = record if lines > skip
          next
        end
        rows << headers.zip(record).to_h
      end
      headers ||= []
      [headers, select_keys(rows, keys)]
    end

    # Keep only the requested keys, in the requested order.
    def select_keys(rows, keys)
      return rows if keys.nil?

      names = keys.map(&:to_s)
      rows.map { |row| names.to_h { |n| [n, row[n]] } }
    end

    # Every object's keys are collected, not just the first row's: a file
    # whose second record has a column the first does not is still a file
    # with that column, and R11 is about the file, not about row one.
    def read_jsonl(path, keys:)
      columns = []
      seen = {}
      rows = []
      File.foreach(path) do |line|
        next if line.strip.empty?

        hash = JSON.parse(line)
        hash.each_key do |k|
          next if seen[k]

          seen[k] = true
          columns << k
        end
        rows << hash
      end
      [columns, select_keys(rows, keys)]
    end

    def read_parquet(path)
      columns, data, num_rows = Parquet.read(path)
      names = columns.map(&:name)
      rows = Array.new(num_rows)
      num_rows.times do |i|
        row = {}
        names.each_with_index { |n, ci| row[n] = data[ci][i] }
        rows[i] = row
      end
      [names, rows]
    end

    # R11 / Y13: a column in the file that nobody asked to import is an
    # error. The alternative — ignoring it — turns a typo in a header into
    # a column of nulls and no message.
    def check_keys!(columns, keys)
      return if keys.nil?

      unknown = columns.map(&:to_s) - keys.map(&:to_s)
      return if unknown.empty?

      raise ArgumentError,
            "import: the file has #{unknown.inspect}, which #{keys.inspect} does not " \
            "name. A column nobody asked for is dropped data, so this raises " \
            "rather than skipping it — check the header for a typo."
    end

    # `types:` coerces, because CSV has no types: every value arrives as a
    # string. A coercion that cannot happen raises here, naming the row and
    # the field, instead of writing the string "abc" into an integer column.
    def coerce_row(row, types, path, index)
      coerced = {}
      row.each do |key, value|
        key = key.to_s
        next if value.nil?

        type = types[key] || types[key.to_sym]
        coerced[key] = type ? coerce(value, type, path, index, key) : value
      end
      coerced
    end

    def coerce(value, type, path, index, key)
      case type.to_sym
      when :integer, :int, :long
        return value if value.is_a?(Integer)
        # Integers arrive from JSON and Parquet already typed; only a CSV
        # string needs converting, and "12abc" is not 12.
        unless value.to_s.strip.match?(/\A[+-]?\d+\z/)
          raise ArgumentError,
                "import: #{path} row #{index + 1} column #{key} is #{value.inspect}, " \
                "which is not an integer (types: #{type})"
        end

        value.to_s.strip.to_i
      when :float, :double
        return value.to_f if value.is_a?(Numeric)

        unless value.to_s.strip.match?(/\A[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?\z/)
          raise ArgumentError,
                "import: #{path} row #{index + 1} column #{key} is #{value.inspect}, " \
                "which is not a float (types: #{type})"
        end

        value.to_s.strip.to_f
      when :boolean, :bool
        coerce_boolean(value, path, index, key)
      when :string, :str, :text
        value.to_s
      when :vector
        coerce_vector(value, path, index, key)
      else
        raise ArgumentError, "import: unknown type #{type.inspect} for column #{key}"
      end
    end

    def coerce_boolean(value, path, index, key)
      return value if value == true || value == false

      case value.to_s.strip.downcase
      when "true", "t", "yes", "y", "1" then true
      when "false", "f", "no", "n", "0" then false
      else
        raise ArgumentError,
              "import: #{path} row #{index + 1} column #{key} is #{value.inspect}, " \
              "which is not a boolean"
      end
    end

    # A vector column arrives as a JSON array, from JSONL or from a Parquet
    # list. The dim: check is the import's own: a vector whose length does
    # not match the index would silently never be found by a search.
    def coerce_vector(value, path, index, key)
      return value if value.is_a?(Array)

      begin
        JSON.parse(value.to_s)
      rescue JSON::ParserError
        raise ArgumentError,
              "import: #{path} row #{index + 1} column #{key} is #{value.inspect}, " \
              "which is not a vector"
      end
    end

    # A vector whose length is not the index's width is refused at the
    # door: the row would import cleanly and then be unfindable by every
    # search against that index, which is the failure mode that looks like
    # "the search is just bad".
    def check_vector_width!(rows, vector, dim, path)
      rows.each_with_index do |row, i|
        value = row[vector.to_s]
        next if value.nil?

        length = value.is_a?(Array) ? value.length : nil
        next if length.nil? || length == dim

        raise ArgumentError,
              "import: #{path} row #{i + 1} column #{vector} has width " \
              "#{length}, but the vector index is dim #{dim}"
      end
    end

    # ---- export -------------------------------------------------------

    # db.export result, to: "people.csv"
    #
    # The Result is drained once, in slices, and written row by row. The
    # format comes from the extension: `.csv`, `.jsonl`, `.parquet`.
    def export(result, to:)
      format = format_of(to)
      columns, rows = drain(result)
      case format
      when :csv     then write_csv(to, columns, rows)
      when :jsonl   then write_jsonl(to, columns, rows)
      when :parquet then write_parquet(to, columns, rows)
      else
        raise ArgumentError, "export: #{format} is not a format this gem writes"
      end
      to
    end

    # Drain a Result (or anything enumerable of rows) into [columns, rows].
    # A row over the boundary is an *array of values*; the names live on the
    # result. A Node value flattens to its property map (§6.2) — a node in a
    # CSV is its properties, not an object reference.
    def drain(result)
      names = result.respond_to?(:columns) ? result.columns.map(&:to_s) : nil
      columns = []
      seen = {}
      rows = []
      each_result_row(result) do |row|
        flat = flatten_row(row, names)
        flat.each_key do |k|
          next if seen[k]

          seen[k] = true
          columns << k
        end
        rows << flat
      end
      [columns, rows]
    end

    def each_result_row(result, &block)
      if result.respond_to?(:each_slice)
        result.each_slice(256) { |batch| batch.each(&block) }
      else
        result.each(&block)
      end
    end

    # One row's values as a flat map: a Node/Edge becomes its properties,
    # a list stays a list, and a nested list is refused by the parquet
    # writer (which has no nested type) rather than being stringified.
    def flatten_row(row, names = nil)
      if row.is_a?(Hash)
        return row.map { |k, v| [k.to_s, v] }.to_h
      elsif row.is_a?(Array) && names
        return names.zip(row).to_h
      end

      flat = {}
      row.each do |key, value|
        k = key.to_s
        flat[k] =
          case value
          when Glyphes::Node, Glyphes::Edge
            value.respond_to?(:properties) ? value.properties : value.to_s
          when Array
            value.map { |v| v.is_a?(Glyphes::Node) ? v.properties : v }
          else
            value
          end
      end
      flat
    end

    def write_csv(path, columns, rows)
      CSV.open(path, "w") do |csv|
        csv << columns
        rows.each do |row|
          csv << columns.map { |c| csv_value(row[c]) }
        end
      end
    end

    def write_jsonl(path, columns, rows)
      File.open(path, "w") do |f|
        rows.each do |row|
          f.puts(JSON.generate(columns.to_h { |c| [c, json_value(row[c])] }))
        end
      end
    end

    # Parquet requires flat values: a nested map or list of maps has no
    # type here, and stringifying it into a column would make the file
    # readable and wrong. `to: :parquet` with a nested value raises (§6.2).
    def write_parquet(path, columns, rows)
      cols = columns.map { |name| parquet_column_for(name, rows, path) }
      data = columns.map do |name|
        col = cols.find { |c| c.name == name }
        rows.map { |row| parquet_value(row[name], name, path) }
             .then { |vals| col.physical_type == Glyphes::ParquetType::BOOLEAN ? vals.map { |v| v.nil? ? nil : !!v } : vals }
      end
      Parquet.write(path, cols, data, rows.length)
    end

    def parquet_column_for(name, rows, path)
      Parquet.infer_column(name, rows.map { |r| r[name] })
    end

    def parquet_value(value, name, path)
      case value
      when nil, true, false, Integer, Float, String then value
      when Array
        raise ArgumentError,
              "export: #{path} column #{name} has a list value; Parquet has no " \
              "nested type here, so a list column is refused rather than " \
              "stringified (RUBY.md §6.2)"
      when Hash
        raise ArgumentError,
              "export: #{path} column #{name} has a nested map; Parquet has no " \
              "nested type here, so a map column is refused rather than " \
              "stringified (RUBY.md §6.2)"
      else
        value.to_s
      end
    end

    def csv_value(value)
      case value
      when nil then ""
      when Array, Hash then JSON.generate(value)
      else value.to_s
      end
    end

    def json_value(value)
      case value
      when Glyphes::Node, Glyphes::Edge
        value.properties
      else
        value
      end
    end

    # ---- shared -------------------------------------------------------

    def format_of(path)
      ext = File.extname(path.to_s).downcase
      case ext
      when ".csv"     then :csv
      when ".jsonl", ".ndjson" then :jsonl
      when ".parquet", ".pq" then :parquet
      else
        raise ArgumentError,
              "#{ext.empty? ? "a file with no extension" : ext} is not a format " \
              "this gem knows; use .csv, .jsonl, or .parquet"
      end
    end
  end
end