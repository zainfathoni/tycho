# frozen_string_literal: true

require "json"
require "time"
require_relative "../lib/hq/domain/open_run_feed"

module OpenRunFeedTest
  module_function

  # Deliberately wide: it carries every field the feed must never emit, so a
  # future leak fails here rather than in production.
  class FakeRun
    attr_reader :run_id, :status, :started_at, :finished_at, :session_id, :command,
                :log_path, :model, :agent, :metadata

    def initialize(run_id:, status: "running", started_at: Time.now, finished_at: nil)
      @run_id = run_id
      @status = status
      @started_at = started_at
      @finished_at = finished_at
      @session_id = "native-session-should-never-appear"
      @command = "claude --dangerously-skip-permissions 'secret prompt'"
      @log_path = "/Users/zain/.tycho/logs/agents/web.raw.log"
      @model = "claude-opus-5"
      @agent = "claude"
      @metadata = { "memory_handoff" => { "outcome" => "secret" } }
    end
  end

  class FakeAgent
    attr_reader :key, :project_key, :runs, :pid, :workspace, :prompt, :summary,
                :structured_result, :session_id, :model

    def initialize(project_key:, runs:, pid: nil, archived: false, completed: false, own_group: true)
      @key = "web-agent-key"
      @project_key = project_key
      @runs = runs
      @pid = pid
      @archived = archived
      @completed = completed
      @own_group = own_group
      @workspace = "/Users/zain/Code/GitHub/zainfathoni/secret-repo"
      @prompt = "Do not leak this prompt."
      @summary = "Do not leak this summary."
      @structured_result = { "summary" => "secret" }
      @session_id = "native-session-should-never-appear"
      @model = "claude-opus-5"
    end

    def archived? = @archived
    def completed_status_available? = @completed
    def own_process_group?(_pid) = @own_group
  end

  UUID = "9f1c2c7e-6b1a-4f0e-9a3d-2b7c5e8d1a44"
  UUID_B = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
  LEGACY_ID = "a" * 64

  def run!
    assert_reports_only_required_fields
    assert_started_at_survives_manifest_round_trip
    assert_excludes_terminal_legacy_and_archived_runs
    assert_liveness_semantics
    assert_abandoned_earlier_runs_are_unknown
    assert_liveness_is_dropped_when_the_newest_run_is_terminal
    assert_pre_epoch_start_is_floored
    assert_ordering_is_stable
    puts "open_run_feed_test: ok"
  end

  def assert_reports_only_required_fields
    started = Time.utc(2026, 9, 6, 7, 12, 44)
    feed = HQ::OpenRunFeed.call(
      [FakeAgent.new(project_key: "cukup", runs: [FakeRun.new(run_id: UUID, started_at: started)], pid: nil)],
      now: Time.utc(2026, 9, 6, 8, 0, 0)
    )

    assert(feed.fetch("schema_version") == 1, "expected schema_version 1")
    assert(feed.fetch("generated_at") == "2026-09-06T08:00:00.000Z", "expected UTC millisecond generated_at")
    run = feed.fetch("runs").fetch(0)
    assert(run.keys.sort == %w[liveness project_key run_id started_at status],
           "expected exactly the contract fields, got #{run.keys.sort.inspect}")
    assert(run.fetch("run_id") == UUID, "expected the native run id")
    assert(run.fetch("project_key") == "cukup", "expected the project key")
    assert(run.fetch("status") == "running", "expected running status")

    # No prohibited value may appear anywhere in the serialized payload.
    serialized = JSON.generate(feed)
    %w[secret-repo Do\ not\ leak native-session-should-never-appear claude-opus-5
       .raw.log dangerously-skip-permissions web-agent-key memory_handoff].each do |forbidden|
      assert(!serialized.include?(forbidden), "expected #{forbidden.inspect} to be excluded from the feed")
    end
  end

  # A live run holds a full-precision Time; the manifest persists iso8601 at
  # one-second precision. Both must serialize identically or a consumer deriving
  # a deterministic identity from run_id would see one run report two instants.
  def assert_started_at_survives_manifest_round_trip
    live = Time.utc(2026, 9, 6, 7, 12, 44) + 0.318
    persisted = Time.iso8601(Time.at(live.to_i).iso8601)

    live_feed = HQ::OpenRunFeed.call([agent_with(live)])
    persisted_feed = HQ::OpenRunFeed.call([agent_with(persisted)])

    started = live_feed.fetch("runs").fetch(0).fetch("started_at")
    assert(started == "2026-09-06T07:12:44.000Z", "expected truncation to whole seconds, got #{started}")
    assert(started == persisted_feed.fetch("runs").fetch(0).fetch("started_at"),
           "expected a live run and its manifest round-trip to serialize identically")
  end

  def agent_with(started_at)
    FakeAgent.new(project_key: "cukup", runs: [FakeRun.new(run_id: UUID, started_at: started_at)])
  end

  def assert_excludes_terminal_legacy_and_archived_runs
    started = Time.utc(2026, 9, 6, 7, 0, 0)
    finished = FakeRun.new(run_id: UUID, status: "success", started_at: started, finished_at: started + 60)
    open_but_finished = FakeRun.new(run_id: UUID_B, status: "running", started_at: started, finished_at: started + 60)
    legacy = FakeRun.new(run_id: LEGACY_ID, started_at: started)

    agents = [
      FakeAgent.new(project_key: "cukup", runs: [finished, open_but_finished, legacy]),
      FakeAgent.new(project_key: "cukup", runs: [FakeRun.new(run_id: UUID, started_at: started)], archived: true)
    ]
    assert(HQ::OpenRunFeed.call(agents).fetch("runs").empty?,
           "expected terminal, already-finished, legacy-id, and archived runs to be excluded")
  end

  def assert_liveness_semantics
    cases = {
      HQ::OpenRunFeed::LIVENESS_UNKNOWN => FakeAgent.new(project_key: "p", runs: [open_run], pid: nil),
      HQ::OpenRunFeed::LIVENESS_ALIVE => FakeAgent.new(project_key: "p", runs: [open_run], pid: Process.pid),
      HQ::OpenRunFeed::LIVENESS_DEAD => FakeAgent.new(project_key: "p", runs: [open_run], pid: unused_pid),
      HQ::OpenRunFeed::LIVENESS_EXITED => FakeAgent.new(project_key: "p", runs: [open_run], pid: Process.pid,
                                                        completed: true)
    }
    cases.each do |expected, agent|
      actual = HQ::OpenRunFeed.call([agent]).fetch("runs").fetch(0).fetch("liveness")
      assert(actual == expected, "expected liveness #{expected}, got #{actual}")
    end

    # An alive pid that does not lead its own process group may have been
    # reused; report it as unknown rather than asserting a terminal belief.
    ambiguous = FakeAgent.new(project_key: "p", runs: [open_run], pid: Process.pid, own_group: false)
    assert(HQ::OpenRunFeed.call([ambiguous]).fetch("runs").fetch(0).fetch("liveness") ==
           HQ::OpenRunFeed::LIVENESS_UNKNOWN, "expected an ambiguous pid to report unknown liveness")
  end

  def assert_abandoned_earlier_runs_are_unknown
    started = Time.utc(2026, 9, 6, 7, 0, 0)
    abandoned = FakeRun.new(run_id: UUID, started_at: started)
    current = FakeRun.new(run_id: UUID_B, started_at: started + 120)
    agent = FakeAgent.new(project_key: "cukup", runs: [abandoned, current], pid: Process.pid)

    runs = HQ::OpenRunFeed.call([agent]).fetch("runs")
    assert(runs.length == 2, "expected both open runs to be reported")
    by_id = runs.to_h { |run| [run.fetch("run_id"), run.fetch("liveness")] }
    assert(by_id.fetch(UUID) == HQ::OpenRunFeed::LIVENESS_UNKNOWN,
           "expected an abandoned earlier run to report unknown liveness")
    assert(by_id.fetch(UUID_B) == HQ::OpenRunFeed::LIVENESS_ALIVE,
           "expected the newest run to own the agent pid")
  end

  # The agent pid and status file describe #last_run only. When the newest run
  # has finalized and an older run is still open, no agent-level signal belongs
  # to that open run, so it must not inherit "exited" from the terminal run.
  def assert_liveness_is_dropped_when_the_newest_run_is_terminal
    started = Time.utc(2026, 9, 6, 7, 0, 0)
    abandoned = FakeRun.new(run_id: UUID, started_at: started)
    terminal = FakeRun.new(run_id: UUID_B, status: "success", started_at: started + 60,
                           finished_at: started + 120)
    agent = FakeAgent.new(project_key: "cukup", runs: [abandoned, terminal],
                          pid: Process.pid, completed: true)

    runs = HQ::OpenRunFeed.call([agent]).fetch("runs")
    assert(runs.length == 1, "expected only the abandoned open run")
    assert(runs.fetch(0).fetch("liveness") == HQ::OpenRunFeed::LIVENESS_UNKNOWN,
           "expected an open run that does not own the agent signals to report unknown liveness")
  end

  # Time#to_i truncates toward zero, which moves a pre-epoch instant forward.
  # The feed must never report a start later than the recorded one.
  def assert_pre_epoch_start_is_floored
    started = Time.utc(1969, 12, 31, 23, 59, 59) + 0.5
    feed = HQ::OpenRunFeed.call([agent_with(started)])
    reported = Time.iso8601(feed.fetch("runs").fetch(0).fetch("started_at"))
    assert(reported <= started, "expected a floored start at or before the recorded instant")
    assert(reported == Time.utc(1969, 12, 31, 23, 59, 59),
           "expected flooring rather than truncation toward zero, got #{reported.iso8601}")
  end

  def assert_ordering_is_stable
    base = Time.utc(2026, 9, 6, 7, 0, 0)
    agents = [
      FakeAgent.new(project_key: "b", runs: [FakeRun.new(run_id: UUID_B, started_at: base + 60)]),
      FakeAgent.new(project_key: "a", runs: [FakeRun.new(run_id: UUID, started_at: base)])
    ]
    ids = HQ::OpenRunFeed.call(agents).fetch("runs").map { |run| run.fetch("run_id") }
    assert(ids == [UUID, UUID_B], "expected runs ordered by started_at then run_id")
    assert(HQ::OpenRunFeed.call(agents.reverse).fetch("runs").map { |run| run.fetch("run_id") } == ids,
           "expected ordering to be independent of agent order")
  end

  def open_run
    FakeRun.new(run_id: UUID, started_at: Time.utc(2026, 9, 6, 7, 0, 0))
  end

  def unused_pid
    candidate = 2**21
    candidate += 1 while HQ::ProcessLiveness.alive?(candidate)
    candidate
  end

  def assert(condition, message)
    raise message unless condition
  end
end

OpenRunFeedTest.run!
