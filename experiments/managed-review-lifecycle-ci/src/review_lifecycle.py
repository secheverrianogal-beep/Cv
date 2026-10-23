"""Reference model for safe managed-review job lifecycle handling.

This module is an executable contract prototype, not a production service patch.
A production implementation must provide durable database transactions, provider
idempotency/reconciliation, and GitHub publication outbox semantics.
"""
from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone
from enum import Enum
from threading import RLock
from typing import Optional


class State(str, Enum):
    ACCEPTED = "accepted"
    QUEUED = "queued"
    CLAIMED = "claimed"
    RUNNING = "running"
    PUBLISHING = "publishing"
    COMPLETED_WITH_FINDINGS = "completed_with_findings"
    COMPLETED_NO_FINDINGS = "completed_no_findings"
    FAILED = "failed"
    TIMED_OUT = "timed_out"
    CANCELLED = "cancelled"
    SUPERSEDED = "superseded"
    OUTCOME_UNKNOWN = "outcome_unknown"


TERMINAL = {
    State.COMPLETED_WITH_FINDINGS,
    State.COMPLETED_NO_FINDINGS,
    State.FAILED,
    State.TIMED_OUT,
    State.CANCELLED,
    State.SUPERSEDED,
    State.OUTCOME_UNKNOWN,
}


@dataclass(frozen=True)
class Target:
    repository_id: str
    pull_number: int
    head_sha: str


@dataclass(frozen=True)
class Attempt:
    attempt_id: int
    target: Target
    trigger_id: str
    state: State
    phase: str
    created_at: datetime
    updated_at: datetime
    deadline_at: datetime
    heartbeat_at: Optional[datetime] = None
    lease_owner: Optional[str] = None
    lease_generation: int = 0
    provider_call_started: bool = False
    provider_result_persisted: bool = False
    receipt_id: Optional[str] = None
    error_code: Optional[str] = None


class AttemptConflict(RuntimeError):
    pass


class StaleLease(RuntimeError):
    pass


class AttemptStore:
    """Thread-safe in-memory reference store used by the regression tests.

    A database implementation should enforce trigger_id uniqueness and one live
    lease per target transactionally. The lock here only models those invariants.
    """

    def __init__(self, wall_timeout: timedelta = timedelta(minutes=20)) -> None:
        if wall_timeout <= timedelta(0):
            raise ValueError("wall_timeout must be positive")
        self.wall_timeout = wall_timeout
        self._lock = RLock()
        self._next_id = 1
        self._by_id: dict[int, Attempt] = {}
        self._by_trigger: dict[str, int] = {}
        self._active_target: dict[Target, int] = {}
        self._receipts: dict[tuple[Target, str], str] = {}

    @staticmethod
    def _now(now: Optional[datetime]) -> datetime:
        stamp = now or datetime.now(timezone.utc)
        if stamp.tzinfo is None:
            raise ValueError("timestamps must be timezone-aware")
        return stamp.astimezone(timezone.utc)

    def accept(self, target: Target, trigger_id: str, now: Optional[datetime] = None) -> Attempt:
        stamp = self._now(now)
        if not target.repository_id or target.pull_number <= 0 or not target.head_sha:
            raise ValueError("target must include repo ID, positive PR number, and exact head SHA")
        if not trigger_id:
            raise ValueError("trigger_id is required for idempotency")
        with self._lock:
            existing_id = self._by_trigger.get(trigger_id)
            if existing_id is not None:
                old = self._by_id[existing_id]
                if old.target != target:
                    raise AttemptConflict("same trigger_id cannot be reused for another target")
                return old
            active_id = self._active_target.get(target)
            if active_id is not None:
                active = self._by_id[active_id]
                if active.state not in TERMINAL:
                    # Duplicate trigger for a currently active target: return the
                    # existing attempt rather than duplicate paid model work.
                    self._by_trigger[trigger_id] = active_id
                    return active
                self._active_target.pop(target, None)
            attempt = Attempt(
                attempt_id=self._next_id,
                target=target,
                trigger_id=trigger_id,
                state=State.QUEUED,
                phase="queued",
                created_at=stamp,
                updated_at=stamp,
                deadline_at=stamp + self.wall_timeout,
            )
            self._next_id += 1
            self._by_id[attempt.attempt_id] = attempt
            self._by_trigger[trigger_id] = attempt.attempt_id
            self._active_target[target] = attempt.attempt_id
            return attempt

    def claim(self, attempt_id: int, worker_id: str, now: Optional[datetime] = None) -> Attempt:
        stamp = self._now(now)
        if not worker_id:
            raise ValueError("worker_id is required")
        with self._lock:
            attempt = self._require(attempt_id)
            if attempt.state in TERMINAL:
                raise AttemptConflict("terminal attempt cannot be claimed")
            if attempt.deadline_at <= stamp:
                raise AttemptConflict("expired attempt must be processed by watchdog")
            if attempt.lease_owner is not None and attempt.lease_owner != worker_id:
                raise AttemptConflict("attempt currently has an owner lease")
            claimed = replace(
                attempt,
                state=State.CLAIMED,
                phase="claimed",
                updated_at=stamp,
                heartbeat_at=stamp,
                lease_owner=worker_id,
                lease_generation=attempt.lease_generation + 1,
            )
            self._by_id[attempt_id] = claimed
            return claimed

    def transition(
        self,
        attempt_id: int,
        worker_id: str,
        generation: int,
        state: State,
        phase: str,
        now: Optional[datetime] = None,
        *,
        provider_call_started: Optional[bool] = None,
        provider_result_persisted: Optional[bool] = None,
        error_code: Optional[str] = None,
        receipt_id: Optional[str] = None,
        current_head_sha: Optional[str] = None,
    ) -> Attempt:
        stamp = self._now(now)
        with self._lock:
            attempt = self._require(attempt_id)
            self._assert_lease(attempt, worker_id, generation)
            if attempt.state in TERMINAL:
                raise AttemptConflict("terminal state is immutable")
            if current_head_sha is not None and current_head_sha != attempt.target.head_sha:
                updated = replace(
                    attempt,
                    state=State.SUPERSEDED,
                    phase="head_changed",
                    updated_at=stamp,
                    lease_owner=None,
                    error_code="head_sha_changed",
                )
                self._finish(updated)
                return updated
            if state in {State.ACCEPTED, State.QUEUED, State.CLAIMED}:
                raise AttemptConflict("cannot transition backwards")
            if state == State.PUBLISHING and not attempt.provider_result_persisted and not provider_result_persisted:
                raise AttemptConflict("persist provider result before publishing")
            updated = replace(
                attempt,
                state=state,
                phase=phase,
                updated_at=stamp,
                heartbeat_at=stamp,
                provider_call_started=(
                    attempt.provider_call_started
                    if provider_call_started is None
                    else provider_call_started
                ),
                provider_result_persisted=(
                    attempt.provider_result_persisted
                    if provider_result_persisted is None
                    else provider_result_persisted
                ),
                error_code=error_code,
                receipt_id=receipt_id,
            )
            if state in TERMINAL:
                self._finish(updated)
            else:
                self._by_id[attempt_id] = updated
            return updated

    def heartbeat(self, attempt_id: int, worker_id: str, generation: int, now: Optional[datetime] = None) -> Attempt:
        stamp = self._now(now)
        with self._lock:
            attempt = self._require(attempt_id)
            self._assert_lease(attempt, worker_id, generation)
            if attempt.state in TERMINAL:
                raise AttemptConflict("terminal attempt cannot heartbeat")
            updated = replace(attempt, heartbeat_at=stamp, updated_at=stamp)
            self._by_id[attempt_id] = updated
            return updated

    def watchdog(self, attempt_id: int, now: Optional[datetime] = None) -> Attempt:
        """Expire an attempt without inventing the outcome of external side effects."""
        stamp = self._now(now)
        with self._lock:
            attempt = self._require(attempt_id)
            if attempt.state in TERMINAL or stamp < attempt.deadline_at:
                return attempt
            unknown = attempt.provider_call_started and not attempt.provider_result_persisted
            terminal_state = State.OUTCOME_UNKNOWN if unknown else State.TIMED_OUT
            updated = replace(
                attempt,
                state=terminal_state,
                phase="watchdog_expired",
                updated_at=stamp,
                lease_owner=None,
                error_code="external_outcome_unknown" if unknown else "wall_deadline_exceeded",
            )
            self._finish(updated)
            return updated

    def record_receipt(self, target: Target, head_sha: str, receipt_id: str) -> str:
        """Idempotent publication receipt key for the exact reviewed HEAD."""
        if head_sha != target.head_sha:
            raise AttemptConflict("receipt SHA must match the reviewed target SHA")
        key = (target, head_sha)
        with self._lock:
            prior = self._receipts.get(key)
            if prior is not None:
                return prior
            self._receipts[key] = receipt_id
            return receipt_id

    def get(self, attempt_id: int) -> Attempt:
        with self._lock:
            return self._require(attempt_id)

    def _require(self, attempt_id: int) -> Attempt:
        try:
            return self._by_id[attempt_id]
        except KeyError as exc:
            raise KeyError(f"unknown attempt_id {attempt_id}") from exc

    @staticmethod
    def _assert_lease(attempt: Attempt, worker_id: str, generation: int) -> None:
        if attempt.lease_owner != worker_id or attempt.lease_generation != generation:
            raise StaleLease("worker lease is stale or no longer owns the attempt")

    def _finish(self, attempt: Attempt) -> None:
        self._by_id[attempt.attempt_id] = attempt
        if self._active_target.get(attempt.target) == attempt.attempt_id:
            self._active_target.pop(attempt.target, None)
