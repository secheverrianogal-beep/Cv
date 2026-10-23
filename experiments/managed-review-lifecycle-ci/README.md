# Managed GitHub Code Review lifecycle — CI contract prototype

Standalone executable reference model for lifecycle invariants proposed for openai/codex#55890.

**Scope:** This is a contract prototype, not a production patch for the managed Codex review backend. The worker that owns Codex Review Summary was not located in the public openai/codex source checked for this task.

## Covered invariants

- duplicate trigger delivery maps to the original attempt;
- distinct triggers do not create duplicate concurrent work for the same repository/PR/head;
- terminal failure permits a controlled new attempt;
- stale lease generations cannot mutate state;
- deadline expiry yields an explicit terminal state;
- an ambiguous provider outcome is reported as outcome_unknown rather than guessed;
- changed HEAD supersedes an old attempt before publication;
- publication receipts are idempotent for an exact target/head;
- publication cannot start until the provider result has been persisted.

The model uses an in-memory store for tests. Production requires transactional durable storage, a persisted lease-generation fence, an outbox/unique publication key, and provider/GitHub reconciliation. Exactly-once external execution is not claimed where the provider outcome is unknown.

## Run locally

    python -m pip install -r requirements-dev.txt
    python -m pytest -q
