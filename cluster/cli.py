"""Typer entry point for the cluster CLI."""

from __future__ import annotations

from pathlib import Path
from typing import Optional

import typer

from cluster import __version__
from cluster.libpath import ensure_libssh2

ensure_libssh2()

from cluster.commands import apt as apt_commands  # noqa: E402
from cluster.commands import clone as clone_commands  # noqa: E402
from cluster.commands import run as run_commands  # noqa: E402
from cluster.commands import transfer as transfer_commands  # noqa: E402
from cluster.config import load_config  # noqa: E402

app = typer.Typer(
    name="cluster",
    help="Manage Raspberry Pi cluster nodes in parallel (SSH via parallel-ssh).",
    no_args_is_help=True,
    pretty_exceptions_show_locals=False,
)
app.add_typer(apt_commands.apt_app, name="apt")


def _version_callback(value: bool) -> None:
    if value:
        typer.echo(__version__)
        raise typer.Exit(0)


@app.callback()
def main(
    ctx: typer.Context,
    config: Optional[Path] = typer.Option(
        None,
        "--config",
        "-c",
        help="Path to YAML config (default: CLUSTER_CONFIG or ~/.config/cluster/config.yaml)",
        exists=False,
        dir_okay=False,
        readable=True,
    ),
    hosts: Optional[str] = typer.Option(
        None,
        "--hosts",
        "-H",
        help="Comma-separated host list (overrides config hosts)",
    ),
    group: Optional[str] = typer.Option(
        None,
        "--group",
        "-g",
        help="Host group name from config",
    ),
    user: Optional[str] = typer.Option(
        None,
        "--user",
        "-u",
        help="SSH user (default: admin)",
    ),
    key: Optional[Path] = typer.Option(
        None,
        "--key",
        "-i",
        help="SSH private key path",
        exists=False,
        dir_okay=False,
    ),
    timeout: Optional[float] = typer.Option(
        None,
        "--timeout",
        "-t",
        help="Per-host SSH timeout in seconds",
    ),
    version: Optional[bool] = typer.Option(
        None,
        "--version",
        callback=_version_callback,
        is_eager=True,
        help="Show version and exit",
    ),
) -> None:
    ctx.ensure_object(dict)
    try:
        cfg = load_config(config)
    except (OSError, ValueError) as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(1) from exc

    if user:
        cfg.user = user
    if key:
        cfg.key = str(key.expanduser())
    if timeout is not None:
        cfg.timeout = timeout

    try:
        selected = cfg.resolve_hosts(hosts=hosts, group=group)
    except ValueError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(1) from exc

    ctx.obj["config"] = cfg
    ctx.obj["hosts"] = selected
    ctx.obj["client"] = None


run_commands.register(app)
clone_commands.register(app)
transfer_commands.register(app)


if __name__ == "__main__":
    app()
