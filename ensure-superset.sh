#!/usr/bin/env bash
source $1

docker exec -it $SUPERSET_CONTAINER superset db upgrade

# 2) Create admin user
echo "[superset] ensure admin exists (create if missing)..."
docker exec "$SUPERSET_CONTAINER" superset fab create-admin \
  --username "$SUPERSET_ADMIN_EMAIL" \
  --firstname "$SUPERSET_ADMIN_FIRST" \
  --lastname "$SUPERSET_ADMIN_LAST" \
  --email "$SUPERSET_ADMIN_EMAIL" \
  --password "$SUPERSET_ADMIN_PASSWORD" \
  >/dev/null 2>&1 || true

  echo "[superset] reset password if user exists..."
docker exec -i "$SUPERSET_CONTAINER" superset shell <<PY
from superset import app, appbuilder
from superset.extensions import db

USERNAME = "${SUPERSET_ADMIN_EMAIL}"
NEW_PASSWORD = "${SUPERSET_ADMIN_PASSWORD}"

with app.app_context():
    sm = appbuilder.sm
    user = sm.find_user(username=USERNAME)
    if not user:
        print(f"User not found: {USERNAME}")
    else:
        user.password = sm.get_password_hash(NEW_PASSWORD)
        user.active = True
        if hasattr(user, "fail_login_count"):
            user.fail_login_count = 0
        db.session.commit()
        print(f"Password reset for user: {USERNAME}")
PY

echo "[superset] done"

# 3) Initialize roles, perms, etc.
docker exec -it superset superset init
