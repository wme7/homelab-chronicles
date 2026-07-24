"""cluster clone command."""

from __future__ import annotations

import shlex
from pathlib import PurePosixPath
from urllib.parse import urlparse

import typer

from cluster.client import print_results
from cluster.context import get_client


def _default_dir(url: str) -> str:
    path = urlparse(url).path.rstrip("/")
    name = PurePosixPath(path).name
    if name.endswith(".git"):
        name = name[: -len(".git")]
    if not name:
        raise typer.BadParameter("Could not infer directory from URL; pass DIR explicitly")
    return name


def register(app: typer.Typer) -> None:
    @app.command("clone")
    def clone(
        ctx: typer.Context,
        url: str = typer.Argument(..., help="Git repository URL"),
        directory: str | None = typer.Argument(
            None,
            help="Remote destination directory (default: repo name in cwd)",
        ),
        pull: bool = typer.Option(
            False,
            "--pull",
            help="If the directory already exists, run git pull instead of failing",
        ),
    ) -> None:
        """Clone a git repository on all selected hosts."""
        client = get_client(ctx)
        dest = directory or _default_dir(url)
        url_q = shlex.quote(url)
        dest_q = shlex.quote(dest)

        if pull:
            command = (
                f"if [ -d {dest_q}/.git ]; then "
                f"git -C {dest_q} pull; "
                f"else git clone {url_q} {dest_q}; fi"
            )
        else:
            command = f"git clone {url_q} {dest_q}"

        results = client.run(command)
        raise typer.Exit(print_results(results))
