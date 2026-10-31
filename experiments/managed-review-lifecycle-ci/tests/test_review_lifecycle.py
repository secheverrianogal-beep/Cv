from datetime import datetime, timedelta, timezone

import pytest

from src.review_lifecycle import AttemptConflict, AttemptStore, StaleLease, State, Target


T0 = datetime(2026, 10, 23, 10, 0, tzinfo=timezone.utc)
TARGET = Target("repo-123", 17, "a" * 40)


def test_duplicate_trigger_is_idempotent():
    store = AttemptStore()
    first = store.accept(TARGET, "delivery-1", T0)
    duplicate = store.accept(TARGET, "delivery-1", T0 + timedelta(seconds=1))
    assert duplicate.attempt_id == first.attempt_id
    assert duplicate.created_at == first.created_at


def test_distinct_trigger_cannot_start_duplicate_live_attempt_for_target():
    store = AttemptStore()
    first = store.accept(TARGET, "delivery-1", T0)
    duplicate = store.accept(TARGET, "delivery-2", T0 + timedelta(seconds=1))
    assert duplicate.attempt_id == first.attempt_id
    assert store.get(first.attempt_id).state == State.QUEUED


def test_terminal_attempt_allows_a_new_trigger_after_failure():
    store = AttemptStore()
    first = store.accept(TARGET, "delivery-1", T0)
    lease = store.claim(first.attempt_id, "worker-A", T0)
    store.transition(
        first.attempt_id, "worker-A", lease.lease_generation, State.FAILED,
        "provider_error", T0 + timedelta(seconds=2), error_code="provider_unavailable"
    )
    second = store.accept(TARGET, "delivery-2", T0 + timedelta(seconds=3))
    assert second.attempt_id != first.attempt_id
    assert second.state == State.QUEUED


def test_stale_worker_generation_is_fenced_out():
    store = AttemptStore()
    attempt = store.accept(TARGET, "delivery-1", T0)
    lease_a = store.claim(attempt.attempt_id, "worker-A", T0)
    # Simulate a lease handoff after the old lease was considered expired by the
    # durable production lease coordinator. The in-memory model uses a new claim.
    with store._lock:
        current = store._by_id[attempt.attempt_id]
        from dataclasses import replace
        store._by_id[attempt.attempt_id] = replace(current, lease_owner=None)
    lease_b = store.claim(attempt.attempt_id, "worker-B", T0 + timedelta(seconds=1))
    assert lease_b.lease_generation > lease_a.lease_generation
    with pytest.raises(StaleLease):
        store.transition(
            attempt.attempt_id, "worker-A", lease_a.lease_generation,
            State.RUNNING, "reviewing", T0 + timedelta(seconds=2)
        )


def test_watchdog_returns_timeout_if_no_external_call_started():
    store = AttemptStore(wall_timeout=timedelta(seconds=30))
    attempt = store.accept(TARGET, "delivery-1", T0)
    result = store.watchdog(attempt.attempt_id, T0 + timedelta(seconds=31))
    assert result.state == State.TIMED_OUT
    assert result.error_code == "wall_deadline_exceeded"


def test_watchdog_does_not_guess_outcome_after_ambiguous_provider_call():
    store = AttemptStore(wall_timeout=timedelta(seconds=30))
    attempt = store.accept(TARGET, "delivery-1", T0)
    lease = store.claim(attempt.attempt_id, "worker-A", T0)
    store.transition(
        attempt.attempt_id, "worker-A", lease.lease_generation, State.RUNNING,
        "provider_call", T0 + timedelta(seconds=1), provider_call_started=True
    )
    result = store.watchdog(attempt.attempt_id, T0 + timedelta(seconds=31))
    assert result.state == State.OUTCOME_UNKNOWN
    assert result.error_code == "external_outcome_unknown"


def test_head_change_supersedes_old_attempt_before_publication():
    store = AttemptStore()
    attempt = store.accept(TARGET, "delivery-1", T0)
    lease = store.claim(attempt.attempt_id, "worker-A", T0)
    result = store.transition(
        attempt.attempt_id, "worker-A", lease.lease_generation, State.PUBLISHING,
        "publishing", T0 + timedelta(seconds=1),
        provider_result_persisted=True, current_head_sha="b" * 40
    )
    assert result.state == State.SUPERSEDED
    assert result.error_code == "head_sha_changed"


def test_publication_receipt_is_idempotent_for_exact_target_and_head():
    store = AttemptStore()
    r1 = store.record_receipt(TARGET, TARGET.head_sha, "receipt-123")
    r2 = store.record_receipt(TARGET, TARGET.head_sha, "receipt-999")
    assert r1 == r2 == "receipt-123"
    with pytest.raises(AttemptConflict):
        store.record_receipt(TARGET, "b" * 40, "wrong-head")


def test_cannot_publish_before_provider_result_is_persisted():
    store = AttemptStore()
    attempt = store.accept(TARGET, "delivery-1", T0)
    lease = store.claim(attempt.attempt_id, "worker-A", T0)
    store.transition(
        attempt.attempt_id, "worker-A", lease.lease_generation, State.RUNNING,
        "reviewing", T0 + timedelta(seconds=1), provider_call_started=True
    )
    with pytest.raises(AttemptConflict):
        store.transition(
            attempt.attempt_id, "worker-A", lease.lease_generation, State.PUBLISHING,
            "publishing", T0 + timedelta(seconds=2)
        )
