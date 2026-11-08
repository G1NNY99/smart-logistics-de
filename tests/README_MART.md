# Шаг 5.1 — DWH: маршрутный рыночный коридор

Исходные SQL-файлы `task/sql/` не изменяются. Построение DWH идет поверх `core.prices` и справочников `public`.

## Что создается

- `mart.market_observations` (materialized view) — **одно наблюдение на `(month, price_id, body_group_id)`**. `month` берется из `public.price_dates.price_date`, а не из `core.prices.loading_date`. Один рейс может учитываться в нескольких месяцах и **разных** группах кузова, но не дважды в одной группе кузова.
- `mart.market_corridor` (materialized view) — **одна ячейка на `(month, loading_city_gcid, unloading_city_gcid, body_group_id, weight_category)`**. `volume_category` намеренно не входит в grain. Для BI доступны русские подписи городов и кузовов.

Города дедуплицируются через `DISTINCT ON (gc_id) ... ORDER BY gc_id, id`. Кузов нормализуется по `body_types.std_id`; если записей в `price_body_types` нет, используется `core.prices.body_type`, а затем категория `Не указан`.

В статистику входят только `is_fact = true`, `price_type IN (1,2,3,4,5,9)`, `complex = false`, положительные `price_rub` и `distance_km`, `outlier_mark = false`, `price_dates.price_date <= '2026-10-26'`. Граница `as_of=2026-10-26` зафиксирована для воспроизводимости.

**Метрики:** P25/P50/P75 и AVG за рейс; P25/P50/P75 за км; `trips_count`, `carriers_count` (только `price_type IN (3,9)`), `cv_rate` (`NULL` при `n < 2`), MoM и YoY по *строго календарным* периодам, `reliability_level`.

Для `HIGH` используется `trips_count >= 30`, `carriers_count >= 5`, `(as_of - MAX(price_dates.price_date)) <= 30 дней` **в рамках самой ячейки**; для `MEDIUM` — `trips_count >= 10`, иначе `LOW_DATA`. Это явное определение «свежести», не вычисляемое из системной даты и не основанное на `etl_loaded_at`.

При вычислении MoM/YoY используется отношение **отображаемых медиан с округлением до 2 знаков**; отсутствующий календарный месяц остается `NULL`, а не заменяется предыдущим доступным.

## Запуск и проверки

Из корня проекта в Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify_mart.ps1
```

Скрипт копирует SQL через `docker compose cp` и выполняет через `docker compose exec ... psql -v ON_ERROR_STOP=1`. Создаёт представления/индексы, обновляет их, проверяет бизнес-инварианты и повторяет обновление со сравнением контрольной суммы данных. В случае ошибки SQL останавливается благодаря `ON_ERROR_STOP=1`, а PowerShell завершится с исключением. Содержимое таблиц `public` и `core` не изменяется.

**Важно:** `REFRESH MATERIALIZED VIEW` повторяем, но **не обновляется автоматически при любом изменении Core**. На следующем этапе свяжем обновление с конвейером Compose / ETL. После ETL Backfill до появления оркестратора следует повторно запустить этот скрипт.

Пример BI-запроса:

```sql
SELECT month, loading_city, unloading_city, body_group, weight_category,
       trips_count, carriers_count, p25_trip, median_trip, p75_trip,
       p25_km, median_km, p75_km, mom_pct, yoy_pct, cv_rate, reliability_level
FROM mart.market_corridor
WHERE loading_city_gcid = 1001 AND unloading_city_gcid = 1003
ORDER BY month DESC, trips_count DESC
LIMIT 15;
```

## Ограничения

- Подготовленная витрина является batch snapshot, а не real-time. Снимок заморожен на `2026-10-26`.
- Для одного рейса несколько допустимых типов кузова могут дать по одному наблюдению в разных группах; суммировать `trips_count` по всем группам кузова как уникальные физические рейсы нельзя.
- Последний день `2026-10-26` в исходных данных не прошел ночную маркировку выбросов; `outlier_mark` переносится и фильтруется как дано.
- Для скорости реализации не используются ClickHouse, Superset и Airflow.
