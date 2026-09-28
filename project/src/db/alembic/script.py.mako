<%!
# Alembic renders identifiers with repr(), i.e. with single quotes, which
# ruff's formatter would rewrite; the template quotes them itself so that a
# generated revision is already format-clean.
def _literal(value: object) -> str:
    return repr(value).replace("'", '"')
%>"""${message}

Revision ID: ${up_revision}
Revises:${" " + comma(down_revision) if down_revision else ""}
Create Date: ${create_date}
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
% if imports:
${imports}
% endif

# revision identifiers, used by Alembic.
revision: str = ${_literal(up_revision)}
down_revision: str | None = ${_literal(down_revision)}
branch_labels: str | Sequence[str] | None = ${_literal(branch_labels)}
depends_on: str | Sequence[str] | None = ${_literal(depends_on)}


def upgrade() -> None:
    ${upgrades if upgrades else "pass"}


def downgrade() -> None:
    ${downgrades if downgrades else "pass"}
