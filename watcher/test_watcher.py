"""Unit tests for the watcher's pure logic and I/O (with fakes). No cluster required."""
import json
import threading
import time
from datetime import datetime, timedelta, timezone

from leandro_watcher import (
    DedupGate,
    Incident,
    build_prompt,
    incident_from_event,
    incidents_from_pod,
    is_fresh,
    workload_of,
)


def test_workload_of_strips_deployment_hashes():
    assert workload_of("api-7d9c5b7f9b-x2x7z") == "api"
    # SafeEncodeString excludes vowels — "abcde" (a, e) could not occur as a
    # real pod-template-hash suffix; "zx9qk" is a realistic hash-like value.
    assert workload_of("coredns-5dd5756b68-zx9qk") == "coredns"


def test_workload_of_strips_statefulset_ordinal():
    assert workload_of("postgres-0") == "postgres"


def test_workload_of_keeps_plain_names():
    assert workload_of("boom") == "boom"


def test_workload_of_strips_non_hex_replicaset_hash():
    assert workload_of("myapp-79bfxq9nkl-2f4pj") == "myapp"
    assert workload_of("api-6889d5f6c8-x4z9k") == "api"


def test_workload_of_job_single_hash():
    assert workload_of("backup-x8k2p") == "backup"


def test_workload_of_keeps_wordlike_suffixes():
    """A trailing 5-char segment that contains a vowel is a real word, not a
    SafeEncodeString hash (bcdfghjklmnpqrstvwxz2456789 excludes vowels) —
    must not be stripped."""
    assert workload_of("redis-cache") == "redis-cache"
    assert workload_of("my-app-redis") == "my-app-redis"
    assert workload_of("foo-nginx") == "foo-nginx"


def test_workload_of_still_strips_hashlike():
    assert workload_of("api-6889d5f6c8-x4z9k") == "api"
    assert workload_of("backup-x8k2p") == "backup"


def test_incident_from_event_warning():
    ev = {
        "type": "Warning",
        "reason": "BackOff",
        "message": "Back-off restarting failed container",
        "involvedObject": {"kind": "Pod", "namespace": "prod", "name": "api-7d9c5b7f9b-x2x7z"},
    }
    inc = incident_from_event(ev)
    assert inc == Incident(
        namespace="prod",
        workload="api",
        reason="BackOff",
        pod="api-7d9c5b7f9b-x2x7z",
        message="Back-off restarting failed container",
    )


def test_incident_from_event_ignores_normal_and_non_pod():
    assert incident_from_event({"type": "Normal", "reason": "Pulled",
                               "involvedObject": {"kind": "Pod", "namespace": "x", "name": "y"}}) is None
    assert incident_from_event({"type": "Warning", "reason": "FailedScheduling",
                               "involvedObject": {"kind": "Deployment", "namespace": "x", "name": "y"}}) is None


def test_incident_from_event_ignores_boring_reasons():
    ev = {"type": "Warning", "reason": "DNSConfigForming",
          "involvedObject": {"kind": "Pod", "namespace": "x", "name": "y"}}
    assert incident_from_event(ev) is None


def test_incidents_from_pod_crashloop_and_oom():
    pod = {
        "metadata": {"namespace": "prod", "name": "api-7d9c5b7f9b-x2x7z"},
        "status": {
            "phase": "Running",
            "containerStatuses": [
                {"state": {"waiting": {"reason": "CrashLoopBackOff", "message": "back-off 5m"}}},
                {"state": {"terminated": {"reason": "OOMKilled", "message": ""}}},
            ],
        },
    }
    reasons = {i.reason for i in incidents_from_pod(pod)}
    assert reasons == {"CrashLoopBackOff", "OOMKilled"}


def test_incidents_from_pod_healthy_is_empty():
    pod = {"metadata": {"namespace": "prod", "name": "ok-1"},
           "status": {"phase": "Running",
                      "containerStatuses": [{"state": {"running": {}}}]}}
    assert incidents_from_pod(pod) == []


def test_dedup_gate_cooldown():
    gate = DedupGate(cooldown_seconds=3600)
    inc = Incident("prod", "api", "BackOff", "api-1", "boom")
    assert gate.accept(inc, now=1000.0)
    assert gate.accept(inc, now=2000.0) is None            # within cooldown
    assert gate.accept(inc, now=1000.0 + 3601)             # re-armed

    other = Incident("prod", "api", "OOMKilled", "api-1", "oom")
    assert gate.accept(other, now=2000.0)                  # different reason = new incident


def test_dedup_gate_folds_aliased_reasons_across_streams():
    """One crash loop surfaces as event `BackOff` AND pod `CrashLoopBackOff`
    (idem `Evicted`/phase `Failed`): must be ONE billed diagnosis, not two."""
    gate = DedupGate(cooldown_seconds=3600)
    assert gate.accept(Incident("prod", "api", "BackOff", "api-1", ""), now=1000.0)
    assert gate.accept(Incident("prod", "api", "CrashLoopBackOff", "api-1", ""),
                       now=1010.0) is None
    assert gate.accept(Incident("prod", "web", "Evicted", "web-1", ""), now=1000.0)
    assert gate.accept(Incident("prod", "web", "Failed", "web-1", ""),
                       now=1010.0) is None


def test_dedup_gate_reports_recurrence():
    gate = DedupGate(cooldown_seconds=100)
    inc = Incident("prod", "api", "OOMKilled", "api-1", "")
    assert gate.accept(inc, now=1000.0) == (1, None)
    assert gate.accept(inc, now=1200.0) == (2, 1000.0)
    assert gate.accept(inc, now=1400.0) == (3, 1200.0)


def test_dedup_state_round_trip(tmp_path):
    """A restart must not re-diagnose what the previous process already did."""
    state = tmp_path / "dedup.json"
    inc = Incident("prod", "api", "BackOff", "api-1", "boom")

    first = DedupGate(cooldown_seconds=3600, state_path=str(state))
    assert first.accept(inc, now=1000.0)
    assert state.exists(), "state must be persisted as soon as an incident is accepted"

    # Fresh process, same file: the entry survives (under its aliased key).
    second = DedupGate(cooldown_seconds=3600, state_path=str(state))
    assert second._seen == {("prod", "api", "CrashLoopBackOff"): (1000.0, 1)}


def test_dedup_state_rejects_loaded_entry_within_cooldown(tmp_path):
    state = tmp_path / "dedup.json"
    inc = Incident("prod", "api", "BackOff", "api-1", "boom")
    DedupGate(cooldown_seconds=3600, state_path=str(state)).accept(inc, now=1000.0)

    restarted = DedupGate(cooldown_seconds=3600, state_path=str(state))
    assert restarted.accept(inc, now=2000.0) is None         # still in cooldown
    assert restarted.accept(inc, now=1000.0 + 3601)          # re-armed after it


def test_dedup_state_serializes_tuple_keys_as_pipe_strings(tmp_path):
    state = tmp_path / "dedup.json"
    gate = DedupGate(cooldown_seconds=3600, state_path=str(state))
    now = time.time()
    gate.accept(Incident("prod", "api", "OOMKilled", "api-1", "oom"), now=now)
    assert json.loads(state.read_text()) == {"prod|api|OOMKilled": [now, 1]}


def test_dedup_state_loads_legacy_float_format(tmp_path):
    """Pre-recurrence dedup.json held bare floats — must migrate, not reset."""
    state = tmp_path / "dedup.json"
    state.write_text(json.dumps({"prod|api|OOMKilled": 1000.0}))
    gate = DedupGate(cooldown_seconds=3600, state_path=str(state))
    assert gate._seen == {("prod", "api", "OOMKilled"): (1000.0, 1)}


def test_dedup_state_purges_stale_entries_on_save(tmp_path):
    """Ephemeral Job/Spark pods must not grow dedup.json for life."""
    state = tmp_path / "dedup.json"
    old = time.time() - DedupGate.RETENTION_SECONDS - 10
    state.write_text(json.dumps({"prod|old-job|Failed": [old, 3]}))
    gate = DedupGate(cooldown_seconds=3600, state_path=str(state))
    gate.accept(Incident("prod", "api", "OOMKilled", "api-1", ""), now=time.time())
    assert ("prod", "old-job", "Failed") not in gate._seen
    assert "old-job" not in state.read_text()


def test_dedup_state_survives_corrupt_file(tmp_path):
    """Corrupt state degrades to an empty gate, never to a crash-loop."""
    state = tmp_path / "dedup.json"
    state.write_text("{not json")
    gate = DedupGate(cooldown_seconds=3600, state_path=str(state))
    assert gate._seen == {}
    assert gate.accept(Incident("prod", "api", "BackOff", "api-1", "x"), now=1.0)


def test_dedup_state_absent_file_is_not_an_error(tmp_path):
    gate = DedupGate(cooldown_seconds=3600, state_path=str(tmp_path / "nope.json"))
    assert gate._seen == {}


def _iso(started_at: float, offset_seconds: float) -> str:
    moment = datetime.fromtimestamp(started_at, tz=timezone.utc) + timedelta(seconds=offset_seconds)
    return moment.isoformat().replace("+00:00", "Z")


def test_is_fresh_rejects_events_older_than_start_minus_grace():
    started = 1_000_000.0
    assert is_fresh({"lastTimestamp": _iso(started, -3600)}, started, grace=60) is False
    assert is_fresh({"lastTimestamp": _iso(started, -61)}, started, grace=60) is False


def test_is_fresh_accepts_recent_and_within_grace():
    started = 1_000_000.0
    assert is_fresh({"lastTimestamp": _iso(started, +5)}, started, grace=60) is True
    assert is_fresh({"lastTimestamp": _iso(started, -30)}, started, grace=60) is True


def test_is_fresh_falls_back_to_event_time():
    started = 1_000_000.0
    assert is_fresh({"eventTime": _iso(started, -3600)}, started, grace=60) is False
    assert is_fresh({"eventTime": _iso(started, +1)}, started, grace=60) is True


def test_is_fresh_reads_snake_case_and_datetime_objects():
    """What kubernetes client to_dict() actually hands the extractor."""
    started = 1_000_000.0
    old = datetime.fromtimestamp(started - 3600, tz=timezone.utc)
    new = datetime.fromtimestamp(started, tz=timezone.utc)
    assert is_fresh({"last_timestamp": old}, started, grace=60) is False
    assert is_fresh({"last_timestamp": new}, started, grace=60) is True
    # naive datetimes are read as UTC, not as local time
    assert is_fresh({"event_time": old.replace(tzinfo=None)}, started, grace=60) is False


def test_is_fresh_keeps_undated_events():
    """Better to re-diagnose (dedup catches it) than to drop an incident."""
    assert is_fresh({}, 1_000_000.0, grace=60) is True
    assert is_fresh({"lastTimestamp": "not-a-date"}, 1_000_000.0, grace=60) is True


def test_build_prompt_contains_facts_and_logs():
    inc = Incident("prod", "api", "CrashLoopBackOff", "api-1", "back-off 5m")
    p = build_prompt(inc, logs="line1\nline2")
    for needle in ("prod", "api-1", "CrashLoopBackOff", "line1"):
        assert needle in p
    assert "diagnos" in p.lower()


def test_deliver_writes_incident_file(tmp_path):
    from leandro_watcher import Incident, deliver
    inc = Incident("prod", "api", "OOMKilled", "api-1", "oom")
    path = deliver("# diag\ncause: memory", inc, incidents_dir=str(tmp_path), webhook_url=None)
    files = list(tmp_path.iterdir())
    assert len(files) == 1 and files[0] == path
    text = files[0].read_text()
    assert "cause: memory" in text and "OOMKilled" in files[0].name


def test_deliver_posts_webhook(tmp_path, monkeypatch):
    from leandro_watcher import Incident, deliver
    posted = {}

    def fake_post(url, json, timeout):  # noqa: A002 - mirrors requests signature
        posted["url"], posted["json"] = url, json

        class R:
            status_code = 200
        return R()

    monkeypatch.setattr("leandro_watcher.requests.post", fake_post)
    inc = Incident("prod", "api", "BackOff", "api-1", "x")
    deliver("diag body", inc, incidents_dir=str(tmp_path), webhook_url="https://chat.example/hook")
    assert posted["url"] == "https://chat.example/hook"
    assert "diag body" in posted["json"]["text"]


def test_run_diagnosis_invokes_hermes(monkeypatch):
    from leandro_watcher import Incident, run_diagnosis
    calls = {}

    class FakePopen:
        def __init__(self, cmd, stdout, stderr, text, start_new_session, env):
            calls["cmd"], calls["start_new_session"] = cmd, start_new_session
            calls["env"] = env
            self.returncode = 0
            self.pid = 12345

        def communicate(self, timeout):
            calls["timeout"] = timeout
            return "le diagnostic", ""

    monkeypatch.setattr("leandro_watcher.subprocess.Popen", FakePopen)
    inc = Incident("prod", "api", "BackOff", "api-1", "x")
    out = run_diagnosis(inc, logs=None, hermes_bin="hermes", timeout=42)
    assert out == "le diagnostic"
    assert calls["cmd"][0] == "hermes" and calls["cmd"][1] == "-z"
    assert "--usage-file" not in calls["cmd"]
    assert calls["timeout"] == 42
    assert calls["start_new_session"] is True
    # one-shots are tagged so session_search can tell them apart from DM chat
    assert calls["env"]["HERMES_SESSION_SOURCE"] == "leandro-alert"


def test_run_hermes_passes_usage_file(monkeypatch):
    import leandro_watcher as lw
    calls = {}

    class FakePopen:
        def __init__(self, cmd, stdout, stderr, text, start_new_session, env):
            calls["cmd"] = cmd
            self.returncode = 0
            self.pid = 1

        def communicate(self, timeout):
            return "ok", ""

    monkeypatch.setattr("leandro_watcher.subprocess.Popen", FakePopen)
    lw._run_hermes("p", "hermes", timeout=1, usage_file="/tmp/u.json")
    i = calls["cmd"].index("--usage-file")
    assert calls["cmd"][i + 1] == "/tmp/u.json"


def test_run_hermes_timeout_kills_the_whole_process_group(monkeypatch):
    """A timed-out hermes leaves grandchildren (uv → python → agent session)
    running and billing if only the parent is killed — the group must die."""
    import subprocess as sp

    import leandro_watcher as lw
    import pytest
    killed = {}

    class HungPopen:
        def __init__(self, cmd, stdout, stderr, text, start_new_session, env):
            self.pid = 4242

        def communicate(self, timeout):
            raise sp.TimeoutExpired(cmd="hermes", timeout=timeout)

        def wait(self):
            killed["waited"] = True

    monkeypatch.setattr("leandro_watcher.subprocess.Popen", HungPopen)
    monkeypatch.setattr("leandro_watcher.os.killpg",
                        lambda pgid, sig: killed.update(pgid=pgid, sig=sig))
    with pytest.raises(sp.TimeoutExpired):
        lw._run_hermes("prompt", "hermes", timeout=1)
    assert killed["pgid"] == 4242 and killed["waited"] is True


def test_pod_logs_falls_back_to_previous_container():
    """Current logs fail (container restarted, nothing current to read) —
    retry with previous=True before giving up, same timeouts."""
    from leandro_watcher import Incident, _pod_logs

    calls = []

    class FakeCore:
        def read_namespaced_pod_log(self, name, namespace, **kwargs):
            calls.append(kwargs)
            if not kwargs.get("previous"):
                raise RuntimeError("no current logs")
            return "prev logs"

    inc = Incident("prod", "api", "CrashLoopBackOff", "api-1", "boom")
    out = _pod_logs(FakeCore(), inc)
    assert out == "prev logs"
    assert len(calls) == 2
    assert not calls[0].get("previous")
    assert calls[1]["previous"] is True
    # same timeouts on both attempts
    for kwargs in calls:
        assert kwargs["tail_lines"] == 20
        assert kwargs["timeout_seconds"] == 10
        assert kwargs["_request_timeout"] == 10


def test_pod_logs_returns_none_when_both_attempts_fail():
    from leandro_watcher import Incident, _pod_logs

    class FakeCore:
        def read_namespaced_pod_log(self, name, namespace, **kwargs):
            raise RuntimeError("still no logs")

    inc = Incident("prod", "api", "CrashLoopBackOff", "api-1", "boom")
    assert _pod_logs(FakeCore(), inc) is None


def test_blind_guard_pings_once_then_rearms_after_ok():
    from leandro_watcher import BlindGuard
    guard = BlindGuard(blind_after=300, now=0.0)
    assert guard.broken(now=100) is False    # still within threshold
    assert guard.broken(now=301) is True     # crosses threshold, fires once
    assert guard.broken(now=400) is False    # already reported, stays silent
    guard.ok(now=500)                        # successful reconnect re-arms
    assert guard.broken(now=500) is False    # just went ok, not silent yet
    assert guard.broken(now=801) is True     # second outage after recovery


def test_diagnosis_runner_serializes(monkeypatch):
    import leandro_watcher as lw
    order = []

    def fake_diag(inc, logs, hermes_bin, timeout):
        order.append(("start", inc.pod))
        time.sleep(0.05)
        order.append(("end", inc.pod))
        return "ok"

    monkeypatch.setattr(lw, "run_diagnosis", fake_diag)
    monkeypatch.setattr(lw, "deliver", lambda *a, **k: None)
    runner = lw.DiagnosisRunner(hermes_bin="h", timeout=1, incidents_dir="/tmp",
                                webhook_url=None, batch_max=1)
    runner.submit(lw.Incident("a", "w", "r", "p1", ""), None)
    runner.submit(lw.Incident("a", "w", "r", "p2", ""), None)
    runner.queue.join()
    # strict serialization: p1 must end before p2 starts
    assert order.index(("end", "p1")) < order.index(("start", "p2"))


def test_worker_survives_fallback_delivery_failure(monkeypatch):
    """The fallback deliver() writes to disk too. If it raises (full or
    read-only /var) the single worker thread must not die — otherwise the
    queue fills forever with nobody draining it, silently."""
    import leandro_watcher as lw
    delivered = []

    def broken_diagnosis(inc, logs, hermes_bin, timeout):
        raise RuntimeError("hermes unavailable")

    def flaky_deliver(report, inc, incidents_dir, webhook_url, **kwargs):
        if inc.pod == "p1":
            raise OSError("read-only file system")
        delivered.append(inc.pod)

    monkeypatch.setattr(lw, "run_diagnosis", broken_diagnosis)
    monkeypatch.setattr(lw, "deliver", flaky_deliver)
    runner = lw.DiagnosisRunner(hermes_bin="h", timeout=1, incidents_dir="/tmp",
                                webhook_url=None, batch_window=0.05)
    runner.submit(lw.Incident("a", "w", "r", "p1", ""), None)
    runner.queue.join()
    runner.submit(lw.Incident("a", "w", "r", "p2", ""), None)
    runner.queue.join()
    assert delivered == ["p2"], "worker must still drain the queue after a fallback failure"


def test_worker_sends_heads_up_before_diagnosis(monkeypatch):
    """The detection ack must reach the chat before the (minutes-long) LLM
    pass, carry the raw facts, and not depend on the diagnosis outcome."""
    import leandro_watcher as lw
    order = []

    def fake_diagnosis(inc, logs, hermes_bin, timeout):
        order.append("diagnosis")
        return "rapport"

    monkeypatch.setattr(lw, "run_diagnosis", fake_diagnosis)
    monkeypatch.setattr(lw, "_send_chat",
                        lambda target, text, hermes_bin: order.append(("chat", text)))
    monkeypatch.setattr(lw, "deliver", lambda *a, **k: None)
    runner = lw.DiagnosisRunner(hermes_bin="h", timeout=1, incidents_dir="/tmp",
                                webhook_url=None, batch_window=0.05,
                                chat_target="google_chat",
                                cluster_name="prod-cluster-1")
    runner.submit(lw.Incident("team-infra", "w", "ImagePullBackOff", "p1",
                              "401 Unauthorized from registry"), None)
    runner.queue.join()
    kind, text = order[0]
    assert kind == "chat", "heads-up must be sent before the diagnosis runs"
    assert "diagnostic en préparation" in text
    assert "prod-cluster-1" in text
    assert "*Pod* : `team-infra/p1`" in text
    assert "*Reason* : *ImagePullBackOff*" in text
    assert "401 Unauthorized" in text
    assert order[1] == "diagnosis"


def test_build_batch_prompt_lists_all_incidents():
    from leandro_watcher import build_batch_prompt
    items = [
        (Incident("ns1", "api", "OOMKilled", "api-1", "oom"), "log-a"),
        (Incident("ns2", "web", "BackOff", "web-1", "boom"), None),
    ]
    p = build_batch_prompt(items)
    for needle in ("2 incidents", "ns1", "api-1", "OOMKilled", "log-a",
                   "ns2", "web-1", "BackOff"):
        assert needle in p
    assert "à toi" in p


def test_build_batch_prompt_single_falls_back_to_plain_prompt():
    from leandro_watcher import build_batch_prompt, build_prompt
    inc = Incident("ns", "api", "BackOff", "api-1", "x")
    assert build_batch_prompt([(inc, "l")]) == build_prompt(inc, "l")


def _batching_runner(monkeypatch, batch_max=10):
    """Deterministic batching harness: first (single) diagnosis blocks until
    released, so later submissions pile up in the queue and get drained as
    one batch when the worker loops."""
    import leandro_watcher as lw
    calls = []
    first_started = threading.Event()
    release_first = threading.Event()

    def fake_single(inc, logs, hermes_bin, timeout):
        first_started.set()
        release_first.wait(timeout=5)
        calls.append([inc.pod])
        return "ok"

    def fake_batch(items, hermes_bin, timeout):
        calls.append([i.pod for i, _ in items])
        return "ok"

    monkeypatch.setattr(lw, "run_diagnosis", fake_single)
    monkeypatch.setattr(lw, "run_diagnosis_batch", fake_batch)
    monkeypatch.setattr(lw, "deliver", lambda *a, **k: None)
    monkeypatch.setattr(lw, "deliver_batch", lambda *a, **k: None)
    runner = lw.DiagnosisRunner(hermes_bin="h", timeout=1, incidents_dir="/tmp",
                                webhook_url=None, batch_max=batch_max,
                                batch_window=0.05)
    return runner, calls, first_started, release_first


def test_worker_batches_queued_incidents(monkeypatch):
    import leandro_watcher as lw
    runner, calls, first_started, release_first = _batching_runner(monkeypatch)
    runner.submit(lw.Incident("a", "w", "r", "p1", ""), None)
    assert first_started.wait(timeout=5)
    runner.submit(lw.Incident("a", "w", "r", "p2", ""), None)
    runner.submit(lw.Incident("a", "w", "r", "p3", ""), None)
    release_first.set()
    runner.queue.join()
    assert calls == [["p1"], ["p2", "p3"]]


def test_worker_respects_batch_max(monkeypatch):
    import leandro_watcher as lw
    runner, calls, first_started, release_first = _batching_runner(monkeypatch, batch_max=2)
    runner.submit(lw.Incident("a", "w", "r", "p1", ""), None)
    assert first_started.wait(timeout=5)
    for pod in ("p2", "p3", "p4", "p5", "p6"):
        runner.submit(lw.Incident("a", "w", "r", pod, ""), None)
    release_first.set()
    runner.queue.join()
    assert calls == [["p1"], ["p2", "p3"], ["p4", "p5"], ["p6"]]


def test_deliver_batch_writes_single_file(tmp_path):
    from leandro_watcher import deliver_batch
    incs = [Incident("ns1", "api", "OOMKilled", "api-1", "oom"),
            Incident("ns2", "web", "BackOff", "web-1", "boom")]
    path = deliver_batch("# rapport groupé", incs, incidents_dir=str(tmp_path),
                         webhook_url=None)
    files = list(tmp_path.iterdir())
    assert files == [path] and "batch-2" in path.name
    text = path.read_text()
    assert "ns1/api-1" in text and "ns2/web-1" in text and "rapport groupé" in text


def test_batch_timeout_scales_and_caps():
    import leandro_watcher as lw
    runner = lw.DiagnosisRunner(hermes_bin="h", timeout=900, incidents_dir="/tmp",
                                webhook_url=None, batch_window=0.0)
    assert runner._batch_timeout(1) == 900
    assert runner._batch_timeout(3) == 900 + 600
    assert runner._batch_timeout(50) == runner.BATCH_TIMEOUT_CAP


def test_batch_max_is_ceiling_clamped():
    import leandro_watcher as lw
    runner = lw.DiagnosisRunner(hermes_bin="h", timeout=1, incidents_dir="/tmp",
                                webhook_url=None, batch_max=100, batch_window=0.0)
    assert runner.batch_max == lw.DiagnosisRunner.BATCH_MAX_CEILING


def test_clip_logs_neutralizes_fences_and_marks_truncation():
    from leandro_watcher import _clip_logs
    assert "```" not in _clip_logs("evil ``` breakout", 100)
    clipped = _clip_logs("x" * 200, 100)
    assert clipped.endswith("(logs tronqués)") and len(clipped) < 200 + 20


def test_deliver_batch_filenames_do_not_collide(tmp_path):
    from leandro_watcher import deliver_batch
    incs = [Incident("ns", "w", "R", "p1", ""), Incident("ns", "w", "R", "p2", "")]
    p1 = deliver_batch("a", incs, incidents_dir=str(tmp_path), webhook_url=None)
    p2 = deliver_batch("b", incs, incidents_dir=str(tmp_path), webhook_url=None)
    assert p1 != p2 and len(list(tmp_path.iterdir())) == 2


def test_send_chat_invokes_hermes_send(monkeypatch):
    import leandro_watcher as lw
    calls = {}

    def fake_run(cmd, capture_output, text, timeout, input):
        calls["cmd"], calls["input"] = cmd, input

        class P:
            returncode = 0
            stderr = ""
        return P()

    monkeypatch.setattr("leandro_watcher.subprocess.run", fake_run)
    lw._send_chat("google_chat", "hello famiglia", hermes_bin="hermes")
    assert calls["cmd"][:4] == ["hermes", "send", "-t", "google_chat"]
    assert calls["input"] == "hello famiglia"


def test_send_chat_truncates_long_reports(monkeypatch):
    import leandro_watcher as lw
    captured = {}

    def fake_run(cmd, capture_output, text, timeout, input):
        captured["input"] = input

        class P:
            returncode = 0
            stderr = ""
        return P()

    monkeypatch.setattr("leandro_watcher.subprocess.run", fake_run)
    lw._send_chat("google_chat", "x" * 5000, hermes_bin="h")
    assert len(captured["input"]) < 4000
    assert "tronqué" in captured["input"]


def test_deliver_sends_to_chat_target(tmp_path, monkeypatch):
    import leandro_watcher as lw
    sent = []
    monkeypatch.setattr(lw, "_send_chat", lambda target, text, hermes_bin: sent.append((target, text)))
    inc = Incident("prod", "api", "OOMKilled", "api-1", "oom")
    lw.deliver("diag", inc, incidents_dir=str(tmp_path), webhook_url=None,
               chat_target="google_chat", hermes_bin="h")
    assert sent and sent[0][0] == "google_chat" and "diag" in sent[0][1]


def test_deliver_without_chat_target_does_not_send(tmp_path, monkeypatch):
    import leandro_watcher as lw
    sent = []
    monkeypatch.setattr(lw, "_send_chat", lambda *a, **k: sent.append(a))
    inc = Incident("prod", "api", "OOMKilled", "api-1", "oom")
    lw.deliver("diag", inc, incidents_dir=str(tmp_path), webhook_url=None)
    assert sent == []


def test_api_alive_true_and_false():
    from leandro_watcher import _api_alive

    class GoodCore:
        def get_api_resources(self, **kwargs):
            return object()

    class DeadCore:
        def get_api_resources(self, **kwargs):
            raise ConnectionError("down")

    assert _api_alive(GoodCore()) is True
    assert _api_alive(DeadCore()) is False


def test_spark_executor_shutdown_is_filtered():
    """Executors killed by their driver at normal job end surface as
    Failed/Error — benign, happens at the end of nearly every SparkApp.
    Real app failures still show on the driver pod, which stays watched."""
    from leandro_watcher import is_ignorable
    exec_failed = Incident("spark", "job-exec", "Failed",
                           "orchestr-yjo7lqvd-f10fdc9fdb7d23d3-exec-2", "")
    exec_error = Incident("spark", "job-exec", "Error",
                          "orchestr-yjo7lqvd-f10fdc9fdb7d23d3-exec-12", "")
    assert is_ignorable(exec_failed) is True
    assert is_ignorable(exec_error) is True


def test_spark_executor_real_failures_still_pass():
    from leandro_watcher import is_ignorable
    oom = Incident("spark", "job-exec", "OOMKilled", "orchestr-abc-exec-2", "")
    pull = Incident("spark", "job-exec", "ImagePullBackOff", "orchestr-abc-exec-3", "")
    driver_failed = Incident("spark", "job", "Failed", "orchestr-abc-driver", "")
    assert is_ignorable(oom) is False
    assert is_ignorable(pull) is False
    assert is_ignorable(driver_failed) is False


def test_non_spark_pods_never_ignored():
    from leandro_watcher import is_ignorable
    assert is_ignorable(Incident("prod", "api", "Failed", "api-7d9c5b7f9b-x2x7z", "")) is False


def test_failedmount_kube_api_access_is_filtered():
    """NodeRestriction auth-graph race during Spark submission bursts: the
    kubelet's TokenRequest is refused for a few seconds, then retried fine."""
    from leandro_watcher import is_ignorable
    inc = Incident("spark", "tg-spark-driver", "FailedMount",
                   "tg-spark-0440-spark-driver-stezcf3cys",
                   'MountVolume.SetUp failed for volume "kube-api-access-x7k2p" : '
                   "failed to fetch token: no relationship found between node X")
    assert is_ignorable(inc) is True


def test_failedmount_other_volumes_still_alert():
    from leandro_watcher import is_ignorable
    inc = Incident("prod", "api", "FailedMount", "api-1",
                   'MountVolume.SetUp failed for volume "data-pvc" : timed out')
    assert is_ignorable(inc) is False


def test_incident_from_event_node_not_ready():
    """Node failures are emitted on the Node object — a Pod-only filter is
    blind to them. Node names must not go through hash stripping (worker-0)."""
    from leandro_watcher import incident_from_event
    ev = {"type": "Warning", "reason": "NodeNotReady",
          "message": "Node worker-0 status is now: NodeNotReady",
          "involvedObject": {"kind": "Node", "name": "worker-0"}}
    inc = incident_from_event(ev)
    assert inc is not None
    assert inc.namespace == "cluster" and inc.workload == "worker-0"


def test_incident_from_event_pvc_provisioning_failed():
    from leandro_watcher import incident_from_event
    ev = {"type": "Warning", "reason": "ProvisioningFailed",
          "message": "no storage class found",
          "involvedObject": {"kind": "PersistentVolumeClaim",
                             "namespace": "prod", "name": "data-pvc"}}
    inc = incident_from_event(ev)
    assert inc is not None and inc.namespace == "prod" and inc.workload == "data-pvc"


def test_incident_from_event_boring_node_reasons_ignored():
    from leandro_watcher import incident_from_event
    ev = {"type": "Warning", "reason": "ImageGCFailed",
          "involvedObject": {"kind": "Node", "name": "worker-0"}}
    assert incident_from_event(ev) is None


def test_incidents_from_pod_skips_stale_terminated():
    """The pod stream replays *current* state: a Job pod dead for days (never
    cleaned up) must not be re-diagnosed at every cooldown expiry, forever."""
    started = 1_000_000.0
    pod = {"metadata": {"namespace": "prod", "name": "old-job-x8k2p"},
           "status": {"phase": "Failed",
                      "containerStatuses": [{"state": {"terminated": {
                          "reason": "Error",
                          "finished_at": _iso(started, -3 * 86400)}}}]}}
    assert incidents_from_pod(pod, started_at=started, grace=60) == []


def test_incidents_from_pod_keeps_fresh_and_undated_terminated():
    started = 1_000_000.0
    fresh = {"metadata": {"namespace": "prod", "name": "api-1"},
             "status": {"containerStatuses": [{"state": {"terminated": {
                 "reason": "OOMKilled", "finished_at": _iso(started, +5)}}}]}}
    undated = {"metadata": {"namespace": "prod", "name": "api-2"},
               "status": {"containerStatuses": [{"state": {"terminated": {
                   "reason": "OOMKilled"}}}]}}
    assert [i.reason for i in incidents_from_pod(fresh, started_at=started)] == ["OOMKilled"]
    assert [i.reason for i in incidents_from_pod(undated, started_at=started)] == ["OOMKilled"]


def test_normalize_watch_obj_mirrors_snake_case_keys():
    """A silent regression here blanks out pod-stream detection entirely."""
    from leandro_watcher import _normalize_watch_obj
    data = {"involved_object": {"kind": "Pod"},
            "status": {"container_statuses": [{"state": {}}]}}
    out = _normalize_watch_obj(data)
    assert out["involvedObject"] == {"kind": "Pod"}
    assert out["status"]["containerStatuses"] == [{"state": {}}]
    assert _normalize_watch_obj(None) is None
    assert _normalize_watch_obj({}) == {}


def test_ns_allowlist(monkeypatch):
    import leandro_watcher as lw
    monkeypatch.setattr(lw, "_NS_ALLOWLIST", frozenset({"prod"}))
    assert lw._ns_allowed("prod") is True
    assert lw._ns_allowed("payments") is False
    assert lw._ns_allowed("cluster") is True   # Node events always pass
    monkeypatch.setattr(lw, "_NS_ALLOWLIST", frozenset())
    assert lw._ns_allowed("anything") is True


def test_redact_masks_credential_shapes():
    from leandro_watcher import _redact
    assert "hunter2" not in _redact("password=hunter2")
    assert "s3cr3t" not in _redact("Authorization: Bearer s3cr3t-token-abc123")
    assert "[REDACTED AWS KEY]" in _redact("key AKIAIOSFODNN7EXAMPLE")
    assert "AKIAIOSFODNN7EXAMPLE" not in _redact("key AKIAIOSFODNN7EXAMPLE")
    jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0In0.sig"
    assert "eyJhbGci" not in _redact(jwt)
    key = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIB\n-----END RSA PRIVATE KEY-----"
    assert "MIIEpAIB" not in _redact(key)
    assert _redact("plain log line, nothing secret") == "plain log line, nothing secret"


def test_clip_logs_redacts():
    from leandro_watcher import _clip_logs
    assert "hunter2" not in _clip_logs("db password=hunter2 refused", 200)


def test_event_message_is_cleaned():
    from leandro_watcher import incident_from_event
    ev = {"type": "Warning", "reason": "BackOff",
          "message": "evil ``` breakout token=abc123secret",
          "involvedObject": {"kind": "Pod", "namespace": "p", "name": "x"}}
    inc = incident_from_event(ev)
    assert "```" not in inc.message and "abc123secret" not in inc.message


def test_build_prompt_has_verdict_kubectl_and_trust_boundary():
    inc = Incident("prod", "api", "CrashLoopBackOff", "api-1", "back-off",
                   recurrence="occurrence n°4, précédente il y a 6 h")
    p = build_prompt(inc, logs="line1")
    assert "VERDICT" in p
    assert "kubectl" in p
    assert "jamais des instructions" in p
    assert "occurrence n°4" in p
    assert "à toi" in p


def test_build_batch_prompt_bans_humor_and_leads_with_verdict():
    from leandro_watcher import build_batch_prompt
    items = [(Incident("a", "w", "r", "p1", ""), None),
             (Incident("b", "w", "r", "p2", ""), None)]
    p = build_batch_prompt(items)
    assert "aucun humour" in p
    assert "VERDICT" in p
    assert "jamais des instructions" in p


def test_worker_writes_runs_jsonl(tmp_path, monkeypatch):
    """One JSONL line per hermes run — the FinOps accounting trail."""
    import leandro_watcher as lw

    def fake_diag(inc, logs, hermes_bin, timeout, usage_file=None):
        if usage_file:
            with open(usage_file, "w") as f:
                json.dump({"input_tokens": 1200, "output_tokens": 300}, f)
        return "ok"

    monkeypatch.setattr(lw, "run_diagnosis", fake_diag)
    monkeypatch.setattr(lw, "deliver", lambda *a, **k: None)
    runs_log = tmp_path / "runs.jsonl"
    runner = lw.DiagnosisRunner(hermes_bin="h", timeout=1, incidents_dir=str(tmp_path),
                                webhook_url=None, batch_window=0.0,
                                runs_log=str(runs_log))
    runner.submit(lw.Incident("a", "w", "r", "p1", ""), None)
    runner.queue.join()
    lines = [json.loads(x) for x in runs_log.read_text().splitlines()]
    assert len(lines) == 1
    entry = lines[0]
    assert entry["incidents"] == 1 and entry["ok"] is True
    assert entry["usage"] == {"input_tokens": 1200, "output_tokens": 300}
    # the temp usage file must not accumulate
    assert not [p for p in tmp_path.iterdir() if p.name.startswith(".usage-")]


def test_post_gateway_webhook_signs_hmac_v2(monkeypatch):
    """Generic HMAC V2: X-Webhook-Signature-V2 = HMAC-SHA256("<ts>.<body>")."""
    import hashlib
    import hmac as hmac_mod

    import leandro_watcher as lw
    captured = {}

    def fake_post(url, data, timeout, headers):
        captured.update(url=url, data=data, headers=headers)

        class R:
            status_code = 202   # gateway "accepted" — 200 means "ignored"
            text = "ok"
        return R()

    monkeypatch.setattr("leandro_watcher.requests.post", fake_post)
    assert lw.post_gateway_webhook("http://127.0.0.1:8644/webhooks/leandro",
                                   "s3cret", "le brief") is True
    ts = captured["headers"]["X-Webhook-Timestamp"]
    expected = hmac_mod.new(b"s3cret", ts.encode() + b"." + captured["data"],
                            hashlib.sha256).hexdigest()
    assert captured["headers"]["X-Webhook-Signature-V2"] == expected
    assert json.loads(captured["data"]) == {"brief": "le brief"}


def test_post_gateway_webhook_false_on_refusal_or_error(monkeypatch):
    import leandro_watcher as lw

    class Refused:
        status_code = 401
        text = "Invalid signature"

    monkeypatch.setattr("leandro_watcher.requests.post",
                        lambda *a, **k: Refused())
    assert lw.post_gateway_webhook("http://x", "s", "p") is False

    class Ignored:
        # 200 = the gateway's filter dropped the event: no agent run will
        # happen, so this must NOT count as delegated.
        status_code = 200
        text = "ignored"

    monkeypatch.setattr("leandro_watcher.requests.post",
                        lambda *a, **k: Ignored())
    assert lw.post_gateway_webhook("http://x", "s", "p") is False

    def boom(*a, **k):
        raise ConnectionError("gateway down")

    monkeypatch.setattr("leandro_watcher.requests.post", boom)
    assert lw.post_gateway_webhook("http://x", "s", "p") is False


def test_worker_falls_back_to_subprocess_when_gateway_refuses(monkeypatch, tmp_path):
    """Delegation is an optimization, never a new failure mode: a dead
    gateway must degrade to the plain `hermes -z` path."""
    import leandro_watcher as lw
    ran = []
    monkeypatch.setattr(lw, "post_gateway_webhook", lambda *a: False)
    monkeypatch.setattr(lw, "run_diagnosis",
                        lambda inc, logs, b, t, **k: ran.append(inc.pod) or "ok")
    monkeypatch.setattr(lw, "deliver", lambda *a, **k: None)
    runner = lw.DiagnosisRunner(hermes_bin="h", timeout=1, incidents_dir=str(tmp_path),
                                webhook_url=None, batch_window=0.0,
                                gateway_webhook_url="http://127.0.0.1:8644/webhooks/leandro",
                                gateway_webhook_secret="s")
    runner.submit(lw.Incident("a", "w", "r", "p1", ""), None)
    runner.queue.join()
    assert ran == ["p1"]


def test_worker_delegates_to_gateway_when_accepted(monkeypatch, tmp_path):
    import leandro_watcher as lw
    posted, ran = [], []
    monkeypatch.setattr(lw, "post_gateway_webhook",
                        lambda url, secret, prompt: posted.append(prompt) or True)
    monkeypatch.setattr(lw, "run_diagnosis",
                        lambda *a, **k: ran.append(1) or "ok")
    runner = lw.DiagnosisRunner(hermes_bin="h", timeout=1, incidents_dir=str(tmp_path),
                                webhook_url=None, batch_window=0.0,
                                gateway_webhook_url="http://x",
                                gateway_webhook_secret="s")
    runner.submit(lw.Incident("a", "w", "r", "p1", "boom"), None)
    runner.queue.join()
    assert len(posted) == 1 and "p1" in posted[0]
    assert ran == []
    # "accepted" is not "delivered": a facts trace must exist on disk
    traces = [p for p in tmp_path.iterdir() if "delegated" in p.name]
    assert len(traces) == 1 and "p1" in traces[0].read_text()


def test_usage_tempfile_cleaned_when_diagnosis_raises(tmp_path, monkeypatch):
    """The timeout path (most likely failure in prod) must not leak
    .usage-*.json files run after run."""
    import leandro_watcher as lw

    def boom(inc, logs, hermes_bin, timeout, usage_file=None):
        raise RuntimeError("hermes timed out")

    monkeypatch.setattr(lw, "run_diagnosis", boom)
    monkeypatch.setattr(lw, "deliver", lambda *a, **k: None)
    runs_log = tmp_path / "runs.jsonl"
    runner = lw.DiagnosisRunner(hermes_bin="h", timeout=1, incidents_dir=str(tmp_path),
                                webhook_url=None, batch_window=0.0,
                                runs_log=str(runs_log))
    runner.submit(lw.Incident("a", "w", "r", "p1", ""), None)
    runner.queue.join()
    assert not [p for p in tmp_path.iterdir() if p.name.startswith(".usage-")]
    entry = json.loads(runs_log.read_text().splitlines()[0])
    assert entry["ok"] is False


def test_runner_creates_runs_log_dir_and_sweeps_orphans(tmp_path, monkeypatch):
    import leandro_watcher as lw
    monkeypatch.setattr(lw, "run_diagnosis", lambda *a, **k: "ok")
    monkeypatch.setattr(lw, "deliver", lambda *a, **k: None)
    orphan_dir = tmp_path / "deep" / "dir"
    orphan_dir.mkdir(parents=True)
    orphan = orphan_dir / ".usage-orphan.json"
    orphan.write_text("{}")
    missing_dir_log = tmp_path / "not" / "yet" / "runs.jsonl"
    lw.DiagnosisRunner(hermes_bin="h", timeout=1, incidents_dir=str(tmp_path),
                       webhook_url=None, batch_window=0.0,
                       runs_log=str(missing_dir_log))
    assert missing_dir_log.parent.is_dir()   # created, accounting alive
    lw.DiagnosisRunner(hermes_bin="h", timeout=1, incidents_dir=str(tmp_path),
                       webhook_url=None, batch_window=0.0,
                       runs_log=str(orphan_dir / "runs.jsonl"))
    assert not orphan.exists()               # orphan swept at startup


def test_ping_blind_posts_to_ntfy(monkeypatch):
    import leandro_watcher as lw
    posts = []

    def fake_post(url, **kwargs):
        posts.append((url, kwargs))

        class R:
            status_code = 200

            def raise_for_status(self):
                pass
        return R()

    monkeypatch.setattr("leandro_watcher.requests.post", fake_post)
    monkeypatch.setenv("LEANDRO_NTFY_URL", "https://ntfy.sh/leandro-x")
    lw._ping_blind(None, 400.0)
    assert any(u == "https://ntfy.sh/leandro-x" for u, _ in posts)


def test_deliver_header_references_incident_file(tmp_path, monkeypatch):
    import leandro_watcher as lw
    sent = []
    monkeypatch.setattr(lw, "_send_chat", lambda target, text, hermes_bin: sent.append(text))
    inc = Incident("prod", "api", "OOMKilled", "api-1", "oom")
    path = lw.deliver("diag", inc, incidents_dir=str(tmp_path), webhook_url=None,
                      chat_target="google_chat", hermes_bin="h")
    # Chat copy: correlation id only — the filename promises a document that
    # space readers cannot open (the archive is VM-local).
    assert path.name not in sent[0]
    assert f"réf : `{path.stem}`" in sent[0]
    # the reference sits in the head, which survives Chat truncation
    assert sent[0].index(path.stem) < sent[0].index("diag")
    # the on-disk copy keeps the real filename for operator archaeology
    assert path.name in path.read_text()
