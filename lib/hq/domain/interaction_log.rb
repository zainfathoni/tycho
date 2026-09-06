# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "fileutils"
require_relative "constants"
require_relative "usage_metrics/query"

module HQ
  # A durable, append-only record of explicit human interactions with managed
  # agents: submitting a prompt, answering an inquiry, or taking over a run
  # another agent owns.
  #
  # It exists because no other Tycho store answers "when did a person act?" in a
  # form an external reader may use. Prompt-queue entries are deleted once
  # dispatched, lifecycle hooks are best-effort notifications, and memory.jsonl
  # is private and destructively rebuilt by rebuild_memory_from_raw_log!, which
  # would churn identities and lose the original instant.
  #
  # The file is written once per observation and has no rebuild path. Unlike
  # usage_metrics.json, records are never upserted; unlike memory.jsonl, they are
  # never regenerated. That is what lets a reader derive a stable identity from
  # observation_id. Pruning drops whole expired records and never edits, renumbers,
  # or re-times a surviving one.
  #
  # Only the fields in FIELDS are stored. No message text, draft, length,
  # attachment detail, agent key, run id, or author identity is recorded.
  class InteractionLog
    SCHEMA_VERSION = 1

    PROMPT_SUBMITTED = "prompt_submitted"
    INQUIRY_ANSWERED = "inquiry_answered"
    RUN_TAKEN_OVER = "run_taken_over"
    KINDS = [PROMPT_SUBMITTED, INQUIRY_ANSWERED, RUN_TAKEN_OVER].freeze

    FIELDS = %w[schema_version observation_id project_key kind observed_at].freeze

    RETENTION_DAYS = 365
    # Pruning rewrites the file, so it runs only when the log has grown past this
    # size. The common append stays a constant-time write under an exclusive lock.
    PRUNE_ABOVE_BYTES = 8 * 1024 * 1024

    # Resolved lazily so a caller that redirects AGENTS_FILE -- tests, or an
    # isolated log root -- gets a matching interaction log without extra wiring.
    def self.default_path
      File.join(File.dirname(AGENTS_FILE), "interactions.jsonl")
    end

    def initialize(path: nil, now: -> { Time.now })
      @path = path || self.class.default_path
      @now = now
    end

    attr_reader :path

    # Returns the stored record, or nil when the kind is unknown or the project
    # key is blank. Callers treat a nil or a raised error as "not observed": a
    # failure here must never block the human action being recorded.
    def record!(project_key:, kind:, observed_at: nil)
      key = project_key.to_s.strip
      return nil if key.empty?
      return nil unless KINDS.include?(kind.to_s)

      record = {
        "schema_version" => SCHEMA_VERSION,
        "observation_id" => SecureRandom.uuid,
        "project_key" => key,
        "kind" => kind.to_s,
        "observed_at" => utc_millis(observed_at || @now.call)
      }
      append(record)
      record
    end

    # `from` is inclusive and `to` is exclusive, both Time values.
    def entries(from: nil, to: nil)
      read.filter_map do |record|
        observed = begin
          Time.iso8601(record["observed_at"])
        rescue ArgumentError
          next
        end
        next if from && observed < from
        next if to && observed >= to

        record
      end
    end

    # Accepts the same window contract as `metrics query`: `from` inclusive,
    # `to` exclusive, and a named IANA timezone required for offset-free values.
    def feed(filters = {})
      options = filters.transform_keys(&:to_s)
      timezone = options.fetch("timezone", "UTC")
      from = UsageMetrics::Query.parse_boundary(options["from"], timezone:, end_boundary: false)
      to = UsageMetrics::Query.parse_boundary(options["to"], timezone:, end_boundary: true)
      {
        "schema_version" => SCHEMA_VERSION,
        "generated_at" => utc_millis(@now.call),
        "from" => from&.utc&.iso8601(3),
        "to" => to&.utc&.iso8601(3),
        "observations" => entries(from:, to:)
      }
    end

    private

    def append(record)
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        prune_unlocked(file) if file.size > PRUNE_ABOVE_BYTES
        file.seek(0, IO::SEEK_END)
        file.puts(JSON.generate(record))
        file.flush
        file.fsync
      end
    end

    def prune_unlocked(file)
      file.rewind
      cutoff = utc_millis(@now.call - (RETENTION_DAYS * 24 * 60 * 60))
      kept = parse(file.read).select { |record| record["observed_at"].to_s >= cutoff }
      file.rewind
      file.truncate(0)
      kept.each { |record| file.puts(JSON.generate(record)) }
      file.flush
    end

    def read
      return [] unless File.exist?(@path)

      File.open(@path, File::RDONLY) do |file|
        file.flock(File::LOCK_SH)
        parse(file.read)
      end
    rescue StandardError
      []
    end

    # A partially written trailing line, or any record missing a field, is
    # skipped rather than repaired. A reader is never handed a guessed value.
    def parse(text)
      text.to_s.each_line.filter_map do |line|
        stripped = line.strip
        next if stripped.empty?

        record = begin
          JSON.parse(stripped)
        rescue JSON::ParserError
          next
        end
        next unless record.is_a?(Hash)
        next unless FIELDS.all? { |field| record.key?(field) }
        next unless KINDS.include?(record["kind"])

        record.slice(*FIELDS)
      end
    end

    def utc_millis(value)
      value.utc.iso8601(3)
    end
  end
end
