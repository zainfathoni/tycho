# frozen_string_literal: true

require "json"
require "tmpdir"
require "time"
require_relative "../lib/hq/domain/interaction_log"

module InteractionLogTest
  module_function

  def run!
    assert_records_only_contract_fields
    assert_rejects_unknown_kinds_and_blank_projects
    assert_records_are_append_only_and_stable
    assert_window_filter_matches_metrics_query_contract
    assert_malformed_lines_are_skipped_not_repaired
    assert_pruning_preserves_surviving_records
    puts "interaction_log_test: ok"
  end

  def with_log(now: nil)
    Dir.mktmpdir("hq-interaction-log-test") do |dir|
      options = { path: File.join(dir, "interactions.jsonl") }
      options[:now] = now if now
      yield HQ::InteractionLog.new(**options), options.fetch(:path)
    end
  end

  def assert_records_only_contract_fields
    with_log do |log, path|
      record = log.record!(project_key: "cukup", kind: HQ::InteractionLog::PROMPT_SUBMITTED,
                           observed_at: Time.utc(2026, 9, 6, 7, 12, 44) + 0.318)

      assert(record.keys.sort == %w[kind observation_id observed_at project_key schema_version],
             "expected exactly the contract fields, got #{record.keys.sort.inspect}")
      assert(record.fetch("observed_at") == "2026-09-06T07:12:44.318Z", "expected UTC millisecond precision")
      assert(record.fetch("project_key") == "cukup", "expected the project key")
      assert(File.stat(path).mode & 0o077 == 0, "expected an owner-only log file")

      # Every stored line carries exactly the contract keys and nothing else, so
      # no content-bearing field -- text, draft, length, attachment detail, agent
      # key, run id, or author -- can reach the file.
      File.read(path).each_line do |line|
        keys = JSON.parse(line).keys.sort
        assert(keys == HQ::InteractionLog::FIELDS.sort, "expected only contract keys on disk, got #{keys.inspect}")
      end
      assert(record.fetch("kind") == HQ::InteractionLog::PROMPT_SUBMITTED, "expected the submission kind")
      assert(record.fetch("schema_version") == 1, "expected a versioned record")
    end
  end

  def assert_rejects_unknown_kinds_and_blank_projects
    with_log do |log, path|
      assert(log.record!(project_key: "cukup", kind: "keystroke").nil?, "expected an unknown kind to be refused")
      assert(log.record!(project_key: "  ", kind: HQ::InteractionLog::PROMPT_SUBMITTED).nil?,
             "expected a blank project key to be refused")
      assert(!File.exist?(path) || File.read(path).strip.empty?, "expected refused records to write nothing")
    end
  end

  # A reader derives a stable identity from observation_id, which holds only
  # because a record is written once and never rewritten.
  def assert_records_are_append_only_and_stable
    with_log do |log|
      first = log.record!(project_key: "cukup", kind: HQ::InteractionLog::PROMPT_SUBMITTED)
      second = log.record!(project_key: "cukup", kind: HQ::InteractionLog::INQUIRY_ANSWERED)
      third = log.record!(project_key: "other", kind: HQ::InteractionLog::RUN_TAKEN_OVER)

      ids = [first, second, third].map { |record| record.fetch("observation_id") }
      assert(ids.uniq.length == 3, "expected distinct observation ids")

      before = log.entries
      assert(before.length == 3, "expected every record to be readable")
      assert(before.map { |record| record.fetch("observation_id") } == ids, "expected append order preserved")
      assert(log.entries == before, "expected repeated reads to return identical records")

      log.record!(project_key: "cukup", kind: HQ::InteractionLog::PROMPT_SUBMITTED)
      assert(log.entries.first(3) == before, "expected a later append to leave earlier records untouched")
    end
  end

  def assert_window_filter_matches_metrics_query_contract
    base = Time.utc(2026, 9, 6, 3, 0, 0)
    with_log(now: -> { base }) do |log|
      log.record!(project_key: "cukup", kind: HQ::InteractionLog::PROMPT_SUBMITTED, observed_at: base)
      log.record!(project_key: "cukup", kind: HQ::InteractionLog::PROMPT_SUBMITTED, observed_at: base + 3600)

      # from is inclusive, to is exclusive.
      window = log.entries(from: base, to: base + 3600)
      assert(window.length == 1, "expected an inclusive from and an exclusive to, got #{window.length}")

      feed = log.feed("from" => "2026-09-06", "to" => "2026-09-07", "timezone" => "UTC")
      assert(feed.fetch("schema_version") == 1, "expected a versioned feed")
      assert(feed.fetch("observations").length == 2, "expected the UTC day to contain both records")

      # Asia/Jakarta is UTC+7, so 03:00Z is 10:00 local and 04:00Z is 11:00 local.
      jakarta = log.feed("from" => "2026-09-06T11:00:00", "timezone" => "Asia/Jakarta")
      assert(jakarta.fetch("observations").length == 1,
             "expected an offset-free boundary to resolve in the named timezone")

      begin
        log.feed("from" => "not-a-time", "timezone" => "UTC")
        raise "expected an invalid boundary to raise"
      rescue ArgumentError
        nil
      end
    end
  end

  def assert_malformed_lines_are_skipped_not_repaired
    with_log do |log, path|
      good = log.record!(project_key: "cukup", kind: HQ::InteractionLog::PROMPT_SUBMITTED)
      File.open(path, "a") do |file|
        file.puts("{not json")
        file.puts(JSON.generate("schema_version" => 1, "observation_id" => "x", "project_key" => "p"))
        file.puts(JSON.generate("schema_version" => 1, "observation_id" => "y", "project_key" => "p",
                                "kind" => "keystroke", "observed_at" => "2026-09-06T00:00:00.000Z"))
        file.print('{"partial":')
      end

      entries = log.entries
      assert(entries.length == 1, "expected only the complete valid record, got #{entries.length}")
      assert(entries.fetch(0) == good, "expected the surviving record to be unchanged")
    end
  end

  def assert_pruning_preserves_surviving_records
    now = Time.utc(2026, 9, 6, 0, 0, 0)
    with_log(now: -> { now }) do |log, path|
      old_record = log.record!(project_key: "cukup", kind: HQ::InteractionLog::PROMPT_SUBMITTED,
                               observed_at: now - (400 * 24 * 60 * 60))
      recent = log.record!(project_key: "cukup", kind: HQ::InteractionLog::PROMPT_SUBMITTED,
                           observed_at: now - 60)
      File.write(path, File.read(path) + ("#{" " * 1024}\n" * 9000))
      assert(File.size(path) > HQ::InteractionLog::PRUNE_ABOVE_BYTES, "expected the log to exceed the prune threshold")

      appended = log.record!(project_key: "cukup", kind: HQ::InteractionLog::INQUIRY_ANSWERED)
      entries = log.entries
      ids = entries.map { |record| record.fetch("observation_id") }

      assert(!ids.include?(old_record.fetch("observation_id")), "expected an expired record to be dropped")
      assert(ids == [recent.fetch("observation_id"), appended.fetch("observation_id")],
             "expected surviving records in original order")
      assert(entries.fetch(0) == recent, "expected pruning to leave a surviving record byte-identical")
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

InteractionLogTest.run!
