"""cluster run / ping commands."""

from __future__ import annotations

import typer

from cluster.client import print_results, prompt_sudo_password
from cluster.context import get_client


def register(app: typer.Typer) -> None:
    @app.command("ping")
    def ping(ctx: typer.Context) -> None:
        """Check SSH connectivity to selected hosts."""
        results = get_client(ctx).run("hostname")
        raise typer.Exit(print_results(results))

    @app.command("run")
    def run(
        ctx: typer.Context,
        command: str = typer.Argument(..., help='Remote command, e.g. "df -h"'),
        sudo: bool = typer.Option(False, "--sudo", help="Run with sudo on remote hosts"),
        ask_sudo: bool = typer.Option(
            True,
            "--ask-sudo/--no-ask-sudo",
            "-K",
            help="When using --sudo, prompt for the sudo password",
        ),
    ) -> None:
        """Run a shell command in parallel on all selected hosts."""
        client = get_client(ctx)
        sudo_password = None
        if sudo:
            sudo_password = ctx.obj.get("sudo_password")
            if sudo_password is None and ask_sudo:
                sudo_password = prompt_sudo_password()
                ctx.obj["sudo_password"] = sudo_password
        results = client.run(command, sudo=sudo, sudo_password=sudo_password)
        raise typer.Exit(print_results(results))
