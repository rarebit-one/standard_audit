require "json"
require "openssl"

module StandardAudit
  # The row digest. There are two algorithms; which one a row uses is decided
  # by its `created_at` against `config.canonical_checksum_since` (default
  # StandardAudit::CANONICAL_CHECKSUM_CUTOVER), at write time and again at
  # verification, from the same stored timestamp. Nothing extra is stored.
  #
  # == Legacy (rows created before the cutover)
  #
  # `SHA256("<parent>|field=value|field=value|…")`, where a Hash value was
  # serialised with `to_json` in whatever key order the Ruby hash had. That is
  # the bug in fundbright/delivery-ops#689: at write time the hash is the one
  # the caller built (insertion order), but PostgreSQL `jsonb` — and MySQL
  # `JSON` — store object keys in their own order (shortest first, then
  # bytewise), so the value read back serialises differently and the digest
  # cannot be reproduced. SQLite keeps JSON as text, so the gem's own suite
  # never saw it. Kept byte-for-byte so legacy rows are verified exactly as
  # they were signed.
  #
  # == Canonical (rows created at or after the cutover)
  #
  # `SHA256(canonical_json({"fields" => {…}, "previous_checksum" => …, "v" => 2}))`.
  # Every input is reduced to a form the database cannot change:
  #
  # * Hash / Array values (the `metadata` jsonb column, or any other JSON
  #   column a host adds to the hashed set) are first round-tripped through
  #   `ActiveSupport::JSON.encode` + `JSON.parse` — the same encoding the
  #   column type applies on write — so symbol keys, Time values, BigDecimals
  #   and the like hash as the JSON the database actually stores. Object keys
  #   are then sorted bytewise at every depth; array order is kept (arrays are
  #   ordered in every JSON store).
  # * Integral floats hash as integers (`1.0` → `1`, `1e20` →
  #   `100000000000000000000`), because a JSON store is free to hand back
  #   either spelling of the same number.
  # * Times hash as UTC ISO 8601 with microseconds, as in the legacy digest.
  # * Strings are escaped at the byte level (`"`, `\` and C0 controls only),
  #   so the output does not depend on the json gem's escaping options.
  # * nil stays `null`, distinct from `""` — the legacy digest conflated them.
  # * Fields are encoded as a JSON object rather than joined with `|`, so a
  #   value containing `|field=` can no longer move content between adjacent
  #   fields without changing the digest.
  #
  # Known limit: a host with `ActiveSupport.parse_json_times = true` reads
  # ISO 8601 strings in JSON back as Time objects, which re-encode at
  # millisecond precision in the app's zone. A metadata string that was not
  # already in that exact form would then hash differently on read. The
  # setting is off by default.
  module Checksum
    LEGACY = 1
    CANONICAL = 2
    ALGORITHMS = [LEGACY, CANONICAL].freeze

    TIME_FORMAT = "%Y-%m-%dT%H:%M:%S.%6NZ".freeze
    ESCAPE = /["\\\x00-\x1f]/n

    module_function

    # The algorithm for a row created at `created_at`: canonical at or after
    # `config.canonical_checksum_since`, legacy before it. A row not yet
    # timestamped is judged by the current time — what a write now would use.
    def algorithm_for(created_at)
      created_at ||= Time.current
      created_at >= StandardAudit.config.canonical_checksum_since ? CANONICAL : LEGACY
    end

    def digest(attrs, fields:, previous_checksum: nil, version:)
      digester(attrs, fields: fields, version: version).call(previous_checksum)
    end

    # A callable `parent -> digest` for one row. The row's own serialisation
    # is built once, so trying many candidate parents (the recovery search)
    # costs one SHA-256 each.
    def digester(attrs, fields:, version:)
      case version
      when LEGACY then legacy_digester(attrs, fields: fields)
      when CANONICAL then canonical_digester(attrs, fields: fields)
      else raise ArgumentError, "unknown checksum algorithm #{version.inspect} (known: #{ALGORITHMS.join(", ")})"
      end
    end

    # The legacy digest, unchanged since 0.3. Do not "fix" this: it is how
    # every pre-cutover row is signed, and it must keep reproducing them.
    def legacy_digest(attrs, fields:, previous_checksum: nil)
      legacy_digester(attrs, fields: fields).call(previous_checksum)
    end

    def legacy_digester(attrs, fields:)
      canonical = fields.map { |f|
        value = attrs[f]
        value = value.to_json if value.is_a?(Hash)
        value = value.utc.strftime(TIME_FORMAT) if time_like?(value)
        "#{f}=#{value}"
      }.join("|")

      lambda do |previous_checksum|
        input = previous_checksum.present? ? "#{previous_checksum}|#{canonical}" : canonical
        OpenSSL::Digest::SHA256.hexdigest(input)
      end
    end

    def canonical_digest(attrs, fields:, previous_checksum: nil)
      canonical_digester(attrs, fields: fields).call(previous_checksum)
    end

    # SHA-256 of canonical_json(canonical_payload(...)). The payload's keys
    # sort as "fields" < "previous_checksum" < "v", so the row's part is
    # serialised once and only the parent is spliced in per call — the
    # result is byte-identical to serialising the whole payload.
    def canonical_digester(attrs, fields:)
      head = String.new("{\"fields\":", encoding: Encoding::BINARY)
      canonical_json(fields.to_h { |f| [f, canonical_value(attrs[f])] }, head)
      head << ",\"previous_checksum\":"
      tail = ",\"v\":#{CANONICAL}}"

      lambda do |previous_checksum|
        parent = previous_checksum.presence
        OpenSSL::Digest::SHA256.hexdigest(head + (parent ? json_string(parent.to_s, String.new(encoding: Encoding::BINARY)) : "null") + tail)
      end
    end

    # The documented canonical payload for a row ("v" => 2 names the format), as a plain Hash.
    def canonical_payload(attrs, fields:, previous_checksum: nil)
      {
        "fields" => fields.to_h { |f| [f, canonical_value(attrs[f])] },
        "previous_checksum" => previous_checksum.presence,
        "v" => CANONICAL
      }
    end

    # The stored-form value of one field, before canonical encoding.
    def canonical_value(value)
      case value
      when nil, String, Integer, Float, true, false then value
      when Hash, Array then json_round_trip(value)
      else time_like?(value) ? value.utc.strftime(TIME_FORMAT) : value.to_s
      end
    end

    # What a JSON column hands back for `value`: encoded exactly as
    # ActiveRecord's JSON type encodes on write, then parsed. Key ORDER is
    # the one thing this does not settle — canonical_json does.
    def json_round_trip(value)
      JSON.parse(ActiveSupport::JSON.encode(value), max_nesting: false, create_additions: false)
    end

    # Deterministic JSON: object keys sorted bytewise at every depth, no
    # whitespace, integral floats as integers, byte-level string escaping.
    # Returns a binary String.
    def canonical_json(value, out = String.new(encoding: Encoding::BINARY))
      case value
      when Hash
        out << "{"
        value.map { |k, v| [k.to_s.b, v] }.sort_by(&:first).each_with_index do |(k, v), i|
          out << "," if i.positive?
          json_string(k, out)
          out << ":"
          canonical_json(v, out)
        end
        out << "}"
      when Array
        out << "["
        value.each_with_index do |v, i|
          out << "," if i.positive?
          canonical_json(v, out)
        end
        out << "]"
      when nil then out << "null"
      when true then out << "true"
      when false then out << "false"
      when Integer then out << value.to_s
      when Float then out << (value.finite? && value == value.floor ? value.to_i.to_s : value.to_s)
      else json_string(value.to_s, out)
      end
      out
    end

    def json_string(string, out)
      out << '"'
      out << string.b.gsub(ESCAPE) do |c|
        case c
        when '"' then '\\"'
        when "\\" then "\\\\"
        else format("\\u%04x", c.ord)
        end
      end
      out << '"'
    end

    def time_like?(value)
      value.respond_to?(:strftime) && value.respond_to?(:utc)
    end

    # True when some JSON object inside `value` has more than one key, i.e.
    # a store that reorders keys could have changed how the legacy digest serialised
    # it. A row with no such object cannot fail the legacy digest because of key order.
    def key_order_ambiguous?(value)
      case value
      when Hash then value.size > 1 || value.each_value.any? { |v| key_order_ambiguous?(v) }
      when Array then value.any? { |v| key_order_ambiguous?(v) }
      else false
      end
    end
  end
end

require "standard_audit/checksum/key_order_search"
