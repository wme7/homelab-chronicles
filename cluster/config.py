"""Configuration loading for the cluster CLI."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

DEFAULT_HOSTS = ("pi-node0", "pi-node1", "pi-node2", "pi-node3")
DEFAULT_USER = "admin"
DEFAULT_CONFIG_PATH = Path.home() / ".config" / "cluster" / "config.yaml"


@dataclass
class ClusterConfig:
    hosts: list[str] = field(default_factory=lambda: list(DEFAULT_HOSTS))
    user: str = DEFAULT_USER
    key: str | None = None
    timeout: float | None = None
    groups: dict[str, list[str]] = field(default_factory=dict)

    def resolve_hosts(self, hosts: str | None = None, group: str | None = None) -> list[str]:
        if hosts and group:
            raise ValueError("Use either --hosts or --group, not both")
        if hosts:
            return [h.strip() for h in hosts.split(",") if h.strip()]
        if group:
            if group not in self.groups:
                known = ", ".join(sorted(self.groups)) or "(none)"
                raise ValueError(f"Unknown group {group!r}; known groups: {known}")
            return list(self.groups[group])
        return list(self.hosts)


def _expand_key(key: str | None) -> str | None:
    if not key:
        return None
    return str(Path(key).expanduser())


def _from_mapping(data: dict[str, Any]) -> ClusterConfig:
    hosts = data.get("hosts") or list(DEFAULT_HOSTS)
    groups_raw = data.get("groups") or {}
    groups = {str(name): list(members) for name, members in groups_raw.items()}
    timeout = data.get("timeout")
    return ClusterConfig(
        hosts=[str(h) for h in hosts],
        user=str(data.get("user") or DEFAULT_USER),
        key=_expand_key(data.get("key")),
        timeout=float(timeout) if timeout is not None else None,
        groups=groups,
    )


def _load_yaml(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        loaded = yaml.safe_load(handle) or {}
    if not isinstance(loaded, dict):
        raise ValueError(f"Config {path} must be a YAML mapping")
    return loaded


def resolve_config_path(explicit: Path | None = None) -> Path | None:
    if explicit is not None:
        return explicit.expanduser()
    env = os.environ.get("CLUSTER_CONFIG")
    if env:
        return Path(env).expanduser()
    if DEFAULT_CONFIG_PATH.is_file():
        return DEFAULT_CONFIG_PATH
    return None


def load_config(explicit: Path | None = None) -> ClusterConfig:
    """Load config from --config, CLUSTER_CONFIG, ~/.config/cluster/config.yaml, or defaults."""
    path = resolve_config_path(explicit)
    if path is None:
        return ClusterConfig()
    if not path.is_file():
        raise FileNotFoundError(f"Config file not found: {path}")
    return _from_mapping(_load_yaml(path))
