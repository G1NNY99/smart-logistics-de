# Docker Compose: полный запуск PostgreSQL → ETL → DWH → ML

Из корня проекта запустите:

```powershell
docker compose up --build -d
```

На **первом** запуске PostgreSQL 17 инициализирует исходные таблицы SQL-скриптами из `task/sql/`, создает 300 000 синтетических строк; дальнейшие запуски используют `postgres_data` (данные не перегенерируются). Инициализация БД считается готовой после TCP-healthcheck. Конфигурация использует три одноразовые задачи, которые выполняются **последовательно**:

1. `db`: PostgreSQL 17, `pg_isready` → healthy.
2. `etl`: Python/SQL очистка, нормализация, FX, Core и DQ quarantine. Запуск только после healthy БД, успешное завершение (`exit 0`) разблокирует DWH.
3. `mart`: SQL создание/пересчет `mart.market_observations` и `mart.market_corridor`; успешное завершение разблокирует ML.
4. `ml`: CatBoost — обучение на фиксированном историческом срезе и прогноз на test/future. Результаты в `mart.ml_price_predictions`, метрики в `mart.ml_model_runs`, `.cbm` и JSON в `artifacts/` (игнорируется Git).

Используются `depends_on: condition: service_healthy` и `condition: service_completed_successfully`. `etl`, `mart`, `ml` по завершении находятся в состоянии **Exited (0)**, это нормально; база остается запущена. Профиль `ml` удален: обычный `docker compose up` включает все четыре сервиса.

## Интеграционная проверка

На Windows в PowerShell из корня проекта:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify_full_pipeline.ps1
```

Тест применяет `docker compose up --build --force-recreate -d`, чтобы гарантированно выполнить все этапы заново даже при ранее завершившихся job-контейнерах; том БД **не удаляется**. Затем проверяет exit code каждого этапа, контрольные количества строк, отсутствие доступного факта/ошибок для future, SQL-assertions ML и выходные артефакты.

## Работа с отдельными этапами

```powershell
docker compose ps -a
docker compose logs --tail=60 etl mart ml
```

`docker compose run --rm --no-deps ml` повторно обучает и сохраняет прогнозы без повторного запуска ETL/DWH (БД должна быть запущена и Core заполнен). Для независимого Backfill ETL потребуется затем пересчитать `mart`; для согласованной полной цепочки используйте `docker compose up --build --force-recreate -d`.

Не выполняйте `docker compose down -v` для обычной остановки: `-v` **удалит** том с БД. `.env` хранит локальный пароль и не должен попадать в Git. Исходные файлы работодателя под `task/` не изменяются.

## Данные и оценка ML

Дата среза фиксирована по ТЗ: **2026-10-26**, а не сегодняшняя дата ОС. Train `2026-07-26..2026-10-04`, test `2026-10-05..2026-10-26`, future — позднее 2026-10-26. Метрики R²/MAPE/RMSE/MAE относятся только к test. Описание модели и факторов — в `docs/ML_PIPELINE.md`.
