# Parity harness for sensitive-key redaction.
#
# There is exactly one filter (StandardAudit::MetadataFilter) and two write
# paths that use it: StandardAudit.record and StandardAudit::Subscriber. Those
# paths previously carried independent copies of the filter and had already
# diverged. Driving both from one shared example is the point of the
# extraction — a future divergence fails here rather than in production.
#
# Host: define `write_metadata(metadata)` returning the persisted AuditLog.
RSpec.shared_examples "an audit metadata write path" do
  it "keeps ordinary metadata" do
    log = write_metadata(order_id: 42, note: "hello")

    expect(log.metadata["order_id"]).to eq(42)
    expect(log.metadata["note"]).to eq("hello")
  end

  it "strips a default sensitive key on an exact match" do
    log = write_metadata(password: "hunter2", email: "a@example.com")

    expect(log.metadata).not_to have_key("password")
    expect(log.metadata["email"]).to eq("a@example.com")
  end

  it "strips every default sensitive key" do
    keys = StandardAudit.config.sensitive_keys
    log = write_metadata(keys.index_with { "redact-me" }.merge(kept: "yes"))

    expect(log.metadata.keys).to eq(["kept"])
  end

  it "strips keys added by the host app" do
    StandardAudit.config.sensitive_keys += %i[client_secret]

    log = write_metadata(client_secret: "sk_live_x", kept: "yes")

    expect(log.metadata).not_to have_key("client_secret")
    expect(log.metadata["kept"]).to eq("yes")
  end

  it "matches string and symbol keys alike" do
    StandardAudit.config.sensitive_keys += %i[client_secret]

    log = write_metadata("client_secret" => "sk_live_x", "kept" => "yes")

    expect(log.metadata.keys).to eq(["kept"])
  end

  it "does not match by substring" do
    # Substring matching would strip input_tokens / token_digest /
    # password_reset_sent_at across the estate, and audit rows are append-only.
    log = write_metadata(input_tokens: 10, output_tokens: 20, token_digest: "abc", password_reset_sent_at: "t")

    expect(log.metadata.keys).to match_array(%w[input_tokens output_tokens token_digest password_reset_sent_at])
  end

  it "never strips reserved keys, even when listed as sensitive" do
    # This is the asymmetry the extraction resolved: the Subscriber copy of the
    # filter did not subtract RESERVED_METADATA_KEYS, so this behaviour held on
    # one path and not the other.
    StandardAudit.config.sensitive_keys += %i[_tags _source]

    log = write_metadata(_tags: { request: "abc" }, _source: "app/x.rb:1", kept: "yes")

    expect(log.metadata).to have_key("_tags")
    expect(log.metadata).to have_key("_source")
    expect(log.metadata["kept"]).to eq("yes")
  end

  it "writes an empty hash when everything was stripped" do
    log = write_metadata(password: "x", token: "y")

    expect(log.metadata).to eq({})
  end
end
