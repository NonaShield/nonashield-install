@echo off
docker compose down -v
docker compose up -d
docker exec payshield-backend alembic upgrade head
echo Demo data reset complete
pause
