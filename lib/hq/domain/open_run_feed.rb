# frozen_string_literal: true

require "time"
require_relative "process_liveness"

module HQ
  # A closed, privacy-clean feed of managed runs that have started and have not
  # yet been durably finalized. It exists so an external reconciler can observe
  # runtime that has not reached the usage-metrics surface, without reading
  # Tycho's private state files.
  #
  # Every emitted field is listed in FIELDS. The payload is built from an
  # explicit literal rather than by filtering a wider hash, so a new attribute
  # on ManagedAgent or AgentRun can never leak into the feed by default.
  class OpenRunFeed
    SCHEMA_VERSION = 1

    # The only run status this feed reports. Terminal runs belong to the
    # usage-metrics surface, which is the authority for finalized runtime.
    OPEN_STATUS = "running"

    # Runs minted by ManagedAgent#start_agent! carry SecureRandom.uuid. Legacy
    # runs backfilled by assign_missing_run_ids! carry a SHA-256 digest derived
    # from agent identity and are deliberately excluded: they are stable but not
    # random, and a consumer is promised a random identity.
    RANDOM_RUN_ID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    FIELDS = %i[run_id project_key started_at status liveness].freeze

    # Process observation only. Never a terminal fact.
    LIVENESS_ALIVE = "alive"      # pid recorded, alive, leads its own process group
    LIVENESS_EXITED = "exited"    # durable status file present; finalization pending
    LIVENESS_DEAD = "dead"        # pid recorded and no longer alive
    LIVENESS_UNKNOWN = "unknown"  # no pid recorded, or an ambiguous/possibly reused pid

    def self.call(agents, now: Time.now)
      new(agents, now: now).call
    end

    def initialize(agents, now: Time.now)
      @agents = Array(agents)
      @now = now
    end

    def call
      {
        "schema_version" => SCHEMA_VERSION,
        "generated_at" => utc_millis(@now),
        "runs" => runs
      }
    end

    private

    def runs
      @agents.reject { |agent| archived?(agent) }
             .flat_map { |agent| agent_runs(agent) }
             .sort_by { |run| [run.fetch("started_at"), run.fetch("run_id")] }
    end

    def agent_runs(agent)
      all = Array(agent.runs)
      open = all.select { |run| open_run?(run) }
      return [] if open.empty?

      # The agent's pid and its status file both describe #last_run only
      # (ManagedAgent#status_file_paths derives from last_run.run_id). So the
      # observation applies to exactly one run: the newest, and only when the
      # newest open run is also the newest run overall. Every other open run was
      # abandoned without finalization and owns no agent-level signal, so its
      # liveness is genuinely unknown rather than dead or exited.
      owner = open.last.equal?(all.last) ? open.last : nil
      observed = owner ? liveness(agent) : nil
      open.map { |run| payload(agent, run, run.equal?(owner) ? observed : LIVENESS_UNKNOWN) }
    end

    def open_run?(run)
      return false unless run.respond_to?(:run_id)
      return false unless run.status.to_s == OPEN_STATUS
      return false unless RANDOM_RUN_ID.match?(run.run_id.to_s)
      return false if run.finished_at

      run.started_at.respond_to?(:to_i)
    end

    def payload(agent, run, observed)
      {
        "run_id" => run.run_id.to_s,
        "project_key" => agent.project_key.to_s,
        "started_at" => utc_millis(run.started_at),
        "status" => run.status.to_s,
        "liveness" => observed
      }
    end

    # Floored to whole seconds and rendered with three fractional digits.
    # Flooring (not #to_i, which truncates toward zero) keeps the value at or
    # before the recorded instant for every input, so the feed can never report
    # a start later than the one Tycho durably recorded.
    #
    # AgentRun#to_hash persists started_at at one-second precision, so a live
    # in-memory Time and the same run read back after a restart must produce
    # identical output. A consumer deriving a deterministic event identity from
    # run_id would otherwise see the same run report two different instants.
    def utc_millis(value)
      Time.at(value.to_f.floor).utc.iso8601(3)
    end

    def archived?(agent)
      agent.respond_to?(:archived?) && agent.archived?
    end

    def liveness(agent)
      return LIVENESS_EXITED if completed?(agent)

      pid = agent.pid
      return LIVENESS_UNKNOWN unless pid
      return LIVENESS_DEAD unless ProcessLiveness.alive?(pid)
      return LIVENESS_UNKNOWN unless own_group?(agent, pid)

      LIVENESS_ALIVE
    rescue StandardError
      LIVENESS_UNKNOWN
    end

    def completed?(agent)
      agent.respond_to?(:completed_status_available?) && agent.completed_status_available?
    rescue StandardError
      false
    end

    def own_group?(agent, pid)
      return true unless agent.respond_to?(:own_process_group?)

      agent.own_process_group?(pid)
    rescue StandardError
      false
    end
  end
end
