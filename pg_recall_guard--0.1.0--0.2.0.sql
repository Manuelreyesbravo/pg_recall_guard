-- pg_recall_guard 0.1.0 -> 0.2.0
--
-- La 0.2.0 no cambia el codigo: agrega la suite de pruebas (make installcheck,
-- verde en PostgreSQL 18.6 y 19beta2) y con eso pasa de 'testing' a 'stable'.
-- El script existe igual porque la 0.1.0 estuvo publicada y alguien puede
-- tenerla instalada: sin el, su ALTER EXTENSION ... UPDATE falla.
\echo Use "ALTER EXTENSION pg_recall_guard UPDATE TO '0.2.0'" to load this file. \quit
