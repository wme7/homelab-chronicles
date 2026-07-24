"""ParallelSSH client wrapper."""

from __future__ import annotations

import getpass
import sys
from dataclasses import dataclass
from pathlib import Path

from gevent import joinall

from cluster.config import ClusterConfig
from cluster.libpath import ensure_libssh2

ensure_libssh2()

from pssh.clients import ParallelSSHClient  # noqa: E402


@dataclass
class CommandResult:
    host: str
    exit_code: int | None
    stdout: str
    stderr: str
    exception: BaseException | None = None

    @property
    def ok(self) -> bool:
        return self.exception is None and self.exit_code == 0


def prompt_sudo_password(prompt: str = "Sudo password: ") -> str:
    """Prompt on the controlling terminal (hidden input)."""
    try:
        return getpass.getpass(prompt)
    except (EOFError, KeyboardInterrupt) as exc:
        raise SystemExit("Sudo password entry cancelled") from exc


class ClusterClient:
    def __init__(self, config: ClusterConfig, hosts: list[str] | None = None):
        self.config = config
        self.hosts = list(hosts if hosts is not None else config.hosts)
        if not self.hosts:
            raise ValueError("No hosts selected")

        kwargs: dict = {
            "hosts": self.hosts,
            "user": config.user,
            "timeout": config.timeout,
        }
        if config.key:
            kwargs["pkey"] = config.key

        self._client = ParallelSSHClient(**kwargs)

    def run(
        self,
        command: str,
        *,
        sudo: bool = False,
        sudo_password: str | None = None,
    ) -> list[CommandResult]:
        """Run a remote command.

        With ``sudo=True``, parallel-ssh uses ``sudo -S``. If ``sudo_password`` is
        set, it is written to each host's stdin. Omit the password for passwordless sudo.
        """
        output = self._client.run_command(
            command,
            sudo=sudo,
            stop_on_errors=False,
        )

        if sudo and sudo_password is not None:
            # parallel-ssh runs `sudo -S`, which reads the password from stdin.
            payload = sudo_password if sudo_password.endswith("\n") else f"{sudo_password}\n"
            for host_out in output:
                if host_out.exception is not None or host_out.stdin is None:
                    continue
                host_out.stdin.write(payload)
                host_out.stdin.flush()

        self._client.join(output)
        results: list[CommandResult] = []
        for host_out in output:
            if host_out.exception is not None:
                results.append(
                    CommandResult(
                        host=host_out.host,
                        exit_code=None,
                        stdout="",
                        stderr="",
                        exception=host_out.exception,
                    )
                )
                continue
            stdout = "\n".join(list(host_out.stdout or []))
            stderr_lines = list(host_out.stderr or [])
            # parallel-ssh prefixes stderr lines with "\t[err]" when using its reader
            stderr = "\n".join(line.removeprefix("\t[err]") for line in stderr_lines)
            results.append(
                CommandResult(
                    host=host_out.host,
                    exit_code=host_out.exit_code,
                    stdout=stdout,
                    stderr=stderr,
                )
            )
        return results

    def copy_to(self, local_path: str, remote_path: str, *, recurse: bool = False) -> None:
        greenlets = self._client.copy_file(local_path, remote_path, recurse=recurse)
        joinall(greenlets, raise_error=True)

    def copy_from(
        self,
        remote_path: str,
        local_base: Path,
        *,
        recurse: bool = False,
    ) -> list[Path]:
        """Download remote_path from each host into local_base/<host>/..."""
        remote = Path(remote_path)
        destinations: list[Path] = []
        copy_args: list[dict[str, str]] = []

        for host in self.hosts:
            dest = local_base / host / remote.name
            dest.parent.mkdir(parents=True, exist_ok=True)
            destinations.append(dest)
            copy_args.append({"dest": str(dest)})

        greenlets = self._client.copy_remote_file(
            remote_path,
            "%(dest)s",
            recurse=recurse,
            copy_args=copy_args,
        )
        joinall(greenlets, raise_error=True)
        return destinations


def _format_exception(exc: BaseException) -> str:
    args = getattr(exc, "args", ())
    if len(args) >= 2 and isinstance(args[0], str) and "%s" in args[0]:
        try:
            return args[0] % args[1:]
        except Exception:
            pass
    return str(exc)


def print_results(results: list[CommandResult]) -> int:
    """Pretty-print per-host results. Returns process exit code (0 if all ok)."""
    failed = 0
    for result in results:
        print(f"=== {result.host} ===")
        if result.exception is not None:
            print(f"ERROR: {_format_exception(result.exception)}")
            failed += 1
            print()
            continue
        if result.stdout:
            print(result.stdout)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        code = result.exit_code if result.exit_code is not None else "?"
        print(f"[exit {code}]")
        print()
        if not result.ok:
            failed += 1

    if failed:
        print(f"Failed on {failed}/{len(results)} host(s)", file=sys.stderr)
        return 1
    return 0
