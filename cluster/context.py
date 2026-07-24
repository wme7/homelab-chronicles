"""Shared Typer context helpers."""

from __future__ import annotations

import typer

from cluster.client import ClusterClient
from cluster.config import ClusterConfig


def get_client(ctx: typer.Context) -> ClusterClient:
    """Lazily build the ParallelSSH client (avoids connecting on --help)."""
    client = ctx.obj.get("client")
    if client is not None:
        return client
    cfg: ClusterConfig = ctx.obj["config"]
    hosts: list[str] = ctx.obj["hosts"]
    try:
        client = ClusterClient(cfg, hosts=hosts)
    except Exception as exc:
        typer.secho(f"Failed to create SSH client: {exc}", fg=typer.colors.RED, err=True)
        raise typer.Exit(1) from exc
    ctx.obj["client"] = client
    return client
