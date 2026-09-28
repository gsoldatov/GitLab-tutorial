import sys
from pathlib import Path

_project_root = Path(__file__).resolve().parent.parent
if str(_project_root) not in sys.path:
    sys.path.insert(0, str(_project_root))

import uvicorn  # noqa: E402

from src.app import create_app  # noqa: E402
from src.config import get_config  # noqa: E402


def main() -> None:
    config = get_config()
    app = create_app(config)
    uvicorn.run(app, host=config.backend.host, port=config.backend.port)


if __name__ == "__main__":
    main()
