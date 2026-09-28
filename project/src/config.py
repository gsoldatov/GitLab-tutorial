from pathlib import Path

from src.models.config import Config

PROJECT_ROOT = Path(__file__).resolve().parent.parent


def _resolve_env_path(env_path: str | Path | None = None) -> Path:
    """Resolves the absolute path to the .env file.

    Args:
        env_path: Path to the .env file, absolute or relative to PROJECT_ROOT.
                  Defaults to `.env` in the project root.
    """
    if env_path is None:
        return PROJECT_ROOT / ".env"
    resolved = Path(env_path)
    if not resolved.is_absolute():
        return PROJECT_ROOT / resolved
    return resolved


def get_config(env_path: str | Path | None = None) -> Config:
    """Loads and validates the configuration.

    Environment variables always override the .env file, and a missing file
    is not an error: containers and CI provide the whole configuration
    through the environment.

    Args:
        env_path: Path to the .env file, absolute or relative to PROJECT_ROOT.
                  Defaults to `.env` in the project root.
    """
    resolved = _resolve_env_path(env_path)
    return Config(_env_file=resolved if resolved.exists() else None)
