"""cluster pull / push commands."""

from __future__ import annotations

from pathlib import Path

import typer

from cluster.context import get_client


def register(app: typer.Typer) -> None:
    @app.command("pull")
    def pull(
        ctx: typer.Context,
        remote: str = typer.Argument(..., help="Remote file or directory path"),
        local: Path = typer.Argument(..., help="Local destination directory"),
        recurse: bool = typer.Option(
            False,
            "--recurse",
            "-r",
            help="Recurse into remote directories",
        ),
    ) -> None:
        """Download a remote path from each host into LOCAL/<hostname>/..."""
        client = get_client(ctx)
        local = local.expanduser()
        local.mkdir(parents=True, exist_ok=True)
        try:
            destinations = client.copy_from(remote, local, recurse=recurse)
        except Exception as exc:
            typer.secho(f"Transfer failed: {exc}", fg=typer.colors.RED, err=True)
            raise typer.Exit(1) from exc

        for host, dest in zip(client.hosts, destinations, strict=True):
            print(f"=== {host} ===")
            print(f"-> {dest}")
            print()

    @app.command("push")
    def push(
        ctx: typer.Context,
        local: Path = typer.Argument(..., help="Local file or directory"),
        remote: str = typer.Argument(..., help="Remote destination path"),
        recurse: bool = typer.Option(
            False,
            "--recurse",
            "-r",
            help="Recurse into local directories",
        ),
    ) -> None:
        """Upload a local path to the same remote path on each host."""
        client = get_client(ctx)
        local = local.expanduser()
        if not local.exists():
            typer.secho(f"Local path not found: {local}", fg=typer.colors.RED, err=True)
            raise typer.Exit(1)
        if local.is_dir() and not recurse:
            typer.secho(
                f"{local} is a directory; pass --recurse to upload it",
                fg=typer.colors.RED,
                err=True,
            )
            raise typer.Exit(1)

        try:
            client.copy_to(str(local), remote, recurse=recurse)
        except Exception as exc:
            typer.secho(f"Transfer failed: {exc}", fg=typer.colors.RED, err=True)
            raise typer.Exit(1) from exc

        for host in client.hosts:
            print(f"=== {host} ===")
            print(f"{local} -> {remote}")
            print()
