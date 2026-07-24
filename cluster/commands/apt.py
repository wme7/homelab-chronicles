"""cluster apt subcommands."""

from __future__ import annotations

import shlex

import typer

from cluster.client import ClusterClient, print_results, prompt_sudo_password
from cluster.context import get_client

apt_app = typer.Typer(help="Run apt-get operations in parallel on all hosts.")


def _apt_get(ctx: typer.Context, *args: str, ask_sudo: bool) -> int:
    client: ClusterClient = get_client(ctx)
    sudo_password = ctx.obj.get("sudo_password")
    if ask_sudo and sudo_password is None:
        sudo_password = prompt_sudo_password()
        ctx.obj["sudo_password"] = sudo_password

    remote_args = " ".join(shlex.quote(a) for a in args)
    command = f"DEBIAN_FRONTEND=noninteractive apt-get {remote_args}"
    results = client.run(command, sudo=True, sudo_password=sudo_password)
    return print_results(results)


@apt_app.command("update")
def update(
    ctx: typer.Context,
    ask_sudo: bool = typer.Option(
        True,
        "--ask-sudo/--no-ask-sudo",
        "-K",
        help="Prompt for the sudo password (needed when admin has no passwordless sudo)",
    ),
) -> None:
    """apt-get update on all hosts."""
    raise typer.Exit(_apt_get(ctx, "update", ask_sudo=ask_sudo))


@apt_app.command("upgrade")
def upgrade(
    ctx: typer.Context,
    yes: bool = typer.Option(True, "--yes/--no-yes", help="Pass -y to apt-get"),
    ask_sudo: bool = typer.Option(
        True,
        "--ask-sudo/--no-ask-sudo",
        "-K",
        help="Prompt for the sudo password (needed when admin has no passwordless sudo)",
    ),
) -> None:
    """apt-get upgrade on all hosts."""
    args = ["upgrade"]
    if yes:
        args.append("-y")
    raise typer.Exit(_apt_get(ctx, *args, ask_sudo=ask_sudo))


@apt_app.command("install")
def install(
    ctx: typer.Context,
    packages: list[str] = typer.Argument(..., help="Package names to install"),
    yes: bool = typer.Option(True, "--yes/--no-yes", help="Pass -y to apt-get"),
    ask_sudo: bool = typer.Option(
        True,
        "--ask-sudo/--no-ask-sudo",
        "-K",
        help="Prompt for the sudo password (needed when admin has no passwordless sudo)",
    ),
) -> None:
    """apt-get install packages on all hosts."""
    args = ["install"]
    if yes:
        args.append("-y")
    args.extend(packages)
    raise typer.Exit(_apt_get(ctx, *args, ask_sudo=ask_sudo))


@apt_app.command("remove")
def remove(
    ctx: typer.Context,
    packages: list[str] = typer.Argument(..., help="Package names to remove"),
    yes: bool = typer.Option(True, "--yes/--no-yes", help="Pass -y to apt-get"),
    ask_sudo: bool = typer.Option(
        True,
        "--ask-sudo/--no-ask-sudo",
        "-K",
        help="Prompt for the sudo password (needed when admin has no passwordless sudo)",
    ),
) -> None:
    """apt-get remove packages on all hosts."""
    args = ["remove"]
    if yes:
        args.append("-y")
    args.extend(packages)
    raise typer.Exit(_apt_get(ctx, *args, ask_sudo=ask_sudo))


@apt_app.command("autoremove")
def autoremove(
    ctx: typer.Context,
    yes: bool = typer.Option(True, "--yes/--no-yes", help="Pass -y to apt-get"),
    purge: bool = typer.Option(
        False,
        "--purge",
        help="Also remove leftover configuration files",
    ),
    ask_sudo: bool = typer.Option(
        True,
        "--ask-sudo/--no-ask-sudo",
        "-K",
        help="Prompt for the sudo password (needed when admin has no passwordless sudo)",
    ),
) -> None:
    """apt-get autoremove unused dependency packages on all hosts."""
    args = ["autoremove"]
    if purge:
        args.append("--purge")
    if yes:
        args.append("-y")
    raise typer.Exit(_apt_get(ctx, *args, ask_sudo=ask_sudo))


@apt_app.command("clean")
def clean(
    ctx: typer.Context,
    ask_sudo: bool = typer.Option(
        True,
        "--ask-sudo/--no-ask-sudo",
        "-K",
        help="Prompt for the sudo password (needed when admin has no passwordless sudo)",
    ),
) -> None:
    """apt-get clean — clear the local downloaded package cache on all hosts."""
    raise typer.Exit(_apt_get(ctx, "clean", ask_sudo=ask_sudo))


@apt_app.command("autoclean")
def autoclean(
    ctx: typer.Context,
    ask_sudo: bool = typer.Option(
        True,
        "--ask-sudo/--no-ask-sudo",
        "-K",
        help="Prompt for the sudo password (needed when admin has no passwordless sudo)",
    ),
) -> None:
    """apt-get autoclean — remove obsolete packages from the download cache."""
    raise typer.Exit(_apt_get(ctx, "autoclean", ask_sudo=ask_sudo))
