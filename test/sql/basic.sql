-- Pruebas que no dependen de ninguna extensión de vectores, así que corren en
-- cualquier PostgreSQL. Cubren lo que hay que garantizar aunque el usuario no
-- tenga pgvector instalado: que la extensión carga, que el descubrimiento no
-- inventa índices, y que los errores enseñan en vez de devolver un número.

-- Sin esto, el CONTEXT de cada error trae el numero de linea de la funcion
-- plpgsql ("line 19 at RAISE") y el test se rompe cada vez que alguien edita el
-- SQL, aunque el comportamiento sea identico. Un test que falla por motivos que
-- no son fallas se termina ignorando.
\set SHOW_CONTEXT never

CREATE EXTENSION IF NOT EXISTS pg_recall_guard CASCADE;

-- La vista existe y no rompe en una base sin índices vectoriales.
SELECT count(*) >= 0 AS vista_responde FROM recall_guard.vector_indexes;

-- Las tablas de estado están y arrancan vacías.
SELECT count(*) AS baselines FROM recall_guard.baselines;
SELECT count(*) AS measurements FROM recall_guard.measurements;

-- check() sin nada aprobado devuelve cero filas, no un error.
SELECT count(*) AS chequeos FROM recall_guard.check();

-- Un índice que NO ordena por operador de distancia debe ser rechazado con un
-- mensaje que diga dónde mirar. Es el caso más probable de mal uso: alguien
-- apunta la herramienta a un btree cualquiera.
CREATE TABLE rg_t (id int PRIMARY KEY, txt text);
CREATE INDEX rg_btree ON rg_t (txt);

\set ON_ERROR_STOP off
SELECT recall_guard.evaluate_query('rg_btree'::regclass, '[1,2,3]', 10);
SELECT recall_guard.measure('rg_btree'::regclass, 10, 5);
\set ON_ERROR_STOP on

-- Un btree tampoco debe aparecer en el descubrimiento.
SELECT count(*) AS btree_descubierto
  FROM recall_guard.vector_indexes WHERE index_name = 'public.rg_btree';

DROP TABLE rg_t;
