"""Pure invite-accept decision (stdlib only — no upstream SDK)."""

from __future__ import annotations


def should_accept_invite(
    invite_pending: bool, invite_from: str, allowlist: list[str]
) -> bool:
    """Accept only a pending invite from an allowlisted name."""
    if not invite_pending or not allowlist:
        return False
    return invite_from.strip().lower() in [n.strip().lower() for n in allowlist]
