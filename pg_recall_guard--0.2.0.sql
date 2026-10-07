-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_recall_guard 0.2.0 — vigila que un índice vectorial siga devolviendo lo que aprobaste.
--
-- El problema: un índice ANN degradado NO falla. Devuelve k vecinos plausibles y
-- nunca avisa que cuatro de los diez buenos quedaron afuera. No hay error, no hay
-- log, no hay alerta — igual que una regresión de plan, que devuelve las mismas
-- filas y sólo deja de usar el índice.
--
-- Lo que hace: descubre los índices vectoriales por CATÁLOGO (no por nombre de
-- extensión), mide su recall real contra ground truth exacto, guarda una línea base
-- y avisa cuando el recall se aleja de ella.
--
-- Agnóstico por construcción: funciona sobre cualquier índice cuyo access method
-- declare operadores de ordenamiento (pg_amop.amoppurpose='o'), que hoy es hnsw,
-- ivfflat, diskann, gist y spgist — y mañana lo que venga, sin tocar este código.

\echo Use "CREATE EXTENSION pg_recall_guard" to load this file. \quit

CREATE SCHEMA IF NOT EXISTS recall_guard;

-- ---------------------------------------------------------------------------
-- 1. Descubrimiento
-- ---------------------------------------------------------------------------

-- Todo índice del cluster que pueda responder un ORDER BY por operador de
-- distancia, con los datos que hacen falta para reconstruir esa consulta.
CREATE VIEW recall_guard.vector_indexes AS
SELECT
    i.indexrelid                              AS index_oid,
    i.indexrelid::regclass::text              AS index_name,
    n.nspname                                 AS schema_name,
    t.relname                                 AS table_name,
    a.attname                                 AS column_name,
    am.amname                                 AS access_method,
    op.oprname                                AS operator,
    -- El operador NO vive en pg_catalog sino donde se instaló la extensión que lo
    -- trae, así que su esquema se lee del catálogo en vez de suponerse. Asumir
    -- pg_catalog acá da "operator does not exist: vector pg_catalog.<=> vector".
    opn.nspname                               AS operator_schema,
    oc.opcname                                AS opclass,
    pg_relation_size(i.indexrelid)            AS index_bytes
FROM pg_index i
JOIN pg_class     c  ON c.oid  = i.indexrelid
JOIN pg_class     t  ON t.oid  = i.indrelid
JOIN pg_namespace n  ON n.oid  = t.relnamespace
JOIN pg_am        am ON am.oid = c.relam
JOIN pg_opclass   oc ON oc.oid = i.indclass[0]
JOIN pg_attribute a  ON a.attrelid = i.indexrelid AND a.attnum = 1
JOIN pg_amop      ao ON ao.amopfamily = oc.opcfamily AND ao.amoppurpose = 'o'
JOIN pg_operator  op ON op.oid = ao.amopopr
JOIN pg_namespace opn ON opn.oid = op.oprnamespace
WHERE i.indisvalid
  AND n.nspname NOT IN ('pg_catalog', 'information_schema');

COMMENT ON VIEW recall_guard.vector_indexes IS
    'Índices que responden ORDER BY por operador de distancia, detectados por catálogo. '
    'No nombra ninguna extensión: sirve para pgvector, pgvectorscale, VectorChord o lo que venga.';

-- ---------------------------------------------------------------------------
-- 2. Estado persistido
-- ---------------------------------------------------------------------------

CREATE TABLE recall_guard.baselines (
    index_name   text        PRIMARY KEY,
    k            int         NOT NULL,
    sample_size  int         NOT NULL,
    recall       numeric(5,4) NOT NULL,
    approved_at  timestamptz NOT NULL DEFAULT now(),
    note         text
);

COMMENT ON TABLE recall_guard.baselines IS
    'El recall que el dueño aceptó como bueno. Sin línea base no hay drift que medir: '
    '"0,82" no dice nada, "0,82 donde aprobaste 0,97" lo dice todo.';

CREATE TABLE recall_guard.measurements (
    id           bigserial   PRIMARY KEY,
    index_name   text        NOT NULL,
    k            int         NOT NULL,
    sample_size  int         NOT NULL,
    recall       numeric(5,4) NOT NULL,
    index_bytes  bigint,
    measured_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON recall_guard.measurements (index_name, measured_at DESC);

-- ---------------------------------------------------------------------------
-- 3. La medición
-- ---------------------------------------------------------------------------

-- Recall de UNA consulta: cuántos de los k vecinos que devuelve el índice están
-- entre los k verdaderos.
--
-- La honestidad de esta función depende de dos cosas que se COMPRUEBAN, no se
-- asumen: que el lado indexado de verdad usó el índice, y que el lado exacto de
-- verdad NO lo usó. Si cualquiera de las dos falla, el número sería un 1.0000
-- inventado — el peor resultado posible, porque es tranquilizador y falso. Por eso
-- se verifica el plan con EXPLAIN y se levanta excepción en vez de devolver algo.
CREATE FUNCTION recall_guard.evaluate_query(
    p_index   regclass,
    p_vector  text,
    p_k       int DEFAULT 10,
    p_exclude tid DEFAULT NULL   -- el ctid de origen, cuando la consulta sale de la tabla
) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE
    v          record;
    q_indexed  text;
    q_exact    text;
    plan_txt   text;
    tids_idx   tid[];
    tids_exact tid[];
    v_limit    int;
    hits       int;
BEGIN
    -- Si la consulta sale de una fila de la tabla, esa fila se encuentra a sí misma
    -- a distancia 0 y regala un acierto en todas las consultas: con k=10 el recall
    -- nunca puede bajar de 0,1 por más roto que esté el índice. Se pide uno de más
    -- y se descarta el propio ctid de los dos lados.
    v_limit := p_k + CASE WHEN p_exclude IS NULL THEN 0 ELSE 1 END;
    SELECT * INTO v FROM recall_guard.vector_indexes WHERE index_oid = p_index;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_recall_guard: % no es un índice con operador de ordenamiento', p_index
            USING HINT = 'Mira recall_guard.vector_indexes para los que sí lo son.';
    END IF;

    q_indexed := format(
        'SELECT array_agg(ctid) FROM (SELECT ctid FROM %I.%I ORDER BY %I OPERATOR(%I.%s) %L::%s LIMIT %s) s',
        v.schema_name, v.table_name, v.column_name,
        v.operator_schema, v.operator,
        p_vector, recall_guard._vector_type(p_index), v_limit);
    q_exact := q_indexed;

    -- Lado indexado: forzar el índice y COMPROBAR que se usó.
    --
    -- El plan se pide en JSON y no en texto porque EXPLAIN (FORMAT TEXT) devuelve
    -- UNA FILA POR LÍNEA, y un INTO se queda sólo con la primera: el "Index Scan"
    -- que aparece más abajo no se vería nunca y la comprobación sería decorativa.
    SET LOCAL enable_seqscan = off;
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || q_indexed INTO plan_txt;
    IF plan_txt NOT LIKE '%Index Scan%' THEN
        RAISE EXCEPTION 'pg_recall_guard: el plan no usó el índice %', v.index_name
            USING DETAIL = plan_txt,
                  HINT   = 'Sin index scan la medición compararía el índice contra sí mismo y daría 1.0 siempre.';
    END IF;
    EXECUTE q_indexed INTO tids_idx;
    RESET enable_seqscan;

    -- Ground truth: prohibir todo acceso por índice y COMPROBAR que no se usó.
    SET LOCAL enable_indexscan  = off;
    SET LOCAL enable_bitmapscan = off;
    SET LOCAL enable_indexonlyscan = off;
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || q_exact INTO plan_txt;
    IF plan_txt LIKE '%Index Scan%' THEN
        RAISE EXCEPTION 'pg_recall_guard: no se pudo obtener ground truth exacto para %', v.index_name
            USING DETAIL = plan_txt,
                  HINT   = 'El planner insistió con el índice pese a los enable_*=off.';
    END IF;
    EXECUTE q_exact INTO tids_exact;
    RESET enable_indexscan; RESET enable_bitmapscan; RESET enable_indexonlyscan;

    -- Fuera el self-match de ambos lados, y recién ahí recortar a k. Si se
    -- recortara antes, el hueco que deja el descarte se llenaría con el vecino
    -- k+1 y volveríamos a contar de más.
    IF p_exclude IS NOT NULL THEN
        SELECT array_agg(x) INTO tids_idx
        FROM (SELECT x FROM unnest(tids_idx) x WHERE x <> p_exclude LIMIT p_k) s;
        SELECT array_agg(x) INTO tids_exact
        FROM (SELECT x FROM unnest(tids_exact) x WHERE x <> p_exclude LIMIT p_k) s;
    END IF;

    IF tids_exact IS NULL OR array_length(tids_exact, 1) IS NULL THEN
        RAISE EXCEPTION 'pg_recall_guard: el ground truth salió vacío para %', v.index_name;
    END IF;

    SELECT count(*) INTO hits
    FROM unnest(tids_idx) x
    WHERE x = ANY (tids_exact);

    RETURN round(hits::numeric / array_length(tids_exact, 1), 4);
END;
$$;

-- El tipo de la columna indexada, para castear el literal del vector sin asumir
-- que siempre es `vector`: puede ser halfvec, sparsevec o lo que traiga la
-- extensión de turno.
CREATE FUNCTION recall_guard._vector_type(p_index regclass)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT format_type(a.atttypid, a.atttypmod)
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
    WHERE i.indexrelid = p_index;
$$;

-- ---------------------------------------------------------------------------
-- 4. Muestreo y medición agregada
-- ---------------------------------------------------------------------------

-- Recall promedio del índice sobre una muestra de consultas.
--
-- Las consultas salen de vectores de la propia tabla, y eso tiene una trampa que
-- hay que desactivar: un vector de la tabla SIEMPRE se encuentra a sí mismo a
-- distancia 0, y ese acierto regalado infla el recall — con k=10 son 10 puntos
-- gratis en cada consulta. Por eso se piden k+1 vecinos y se descarta el propio
-- ctid de los dos lados. Es la diferencia entre medir el índice y medir que un
-- vector es igual a sí mismo.
CREATE FUNCTION recall_guard.measure(
    p_index       regclass,
    p_k           int DEFAULT 10,
    p_sample_size int DEFAULT 30
) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE
    v        record;
    muestra  record;
    total    numeric := 0;
    n        int     := 0;
    r        numeric;
BEGIN
    SELECT * INTO v FROM recall_guard.vector_indexes WHERE index_oid = p_index;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_recall_guard: % no es un índice vectorial', p_index;
    END IF;

    -- Se trae el ctid junto al vector: sin él no se puede descartar el self-match
    -- y el recall queda con un piso artificial de 1/k.
    FOR muestra IN EXECUTE format(
        'SELECT ctid, %I::text AS vec FROM %I.%I TABLESAMPLE SYSTEM_ROWS(%s) WHERE %I IS NOT NULL',
        v.column_name, v.schema_name, v.table_name, p_sample_size, v.column_name)
    LOOP
        r := recall_guard.evaluate_query(p_index, muestra.vec, p_k, muestra.ctid);
        total := total + r;
        n := n + 1;
    END LOOP;

    IF n = 0 THEN
        RAISE EXCEPTION 'pg_recall_guard: la muestra salió vacía para %', v.index_name
            USING HINT = '¿La tabla tiene filas con esa columna no nula?';
    END IF;

    INSERT INTO recall_guard.measurements (index_name, k, sample_size, recall, index_bytes)
    VALUES (v.index_name, p_k, n, round(total / n, 4), v.index_bytes);

    RETURN round(total / n, 4);
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. La línea base y el drift
-- ---------------------------------------------------------------------------

-- "Este recall es el que acepto." Sin esto, un 0,82 no dice nada; con esto,
-- dice que perdiste 15 puntos desde que lo aprobaste.
CREATE FUNCTION recall_guard.approve(
    p_index       regclass,
    p_k           int DEFAULT 10,
    p_sample_size int DEFAULT 30,
    p_note        text DEFAULT NULL
) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE
    v_name text;
    r      numeric;
BEGIN
    SELECT index_name INTO v_name FROM recall_guard.vector_indexes WHERE index_oid = p_index;
    r := recall_guard.measure(p_index, p_k, p_sample_size);

    INSERT INTO recall_guard.baselines (index_name, k, sample_size, recall, note)
    VALUES (v_name, p_k, p_sample_size, r, p_note)
    ON CONFLICT (index_name) DO UPDATE
        SET k = EXCLUDED.k, sample_size = EXCLUDED.sample_size,
            recall = EXCLUDED.recall, approved_at = now(), note = EXCLUDED.note;

    RETURN r;
END;
$$;

-- El chequeo que se agenda: vuelve a medir todo lo aprobado y reporta la caída.
-- Devuelve filas en vez de escribir en el log porque un monitor lo consume mejor.
CREATE FUNCTION recall_guard.check()
RETURNS TABLE (
    index_name text,
    baseline   numeric,
    current    numeric,
    drift      numeric,
    verdict    text
)
LANGUAGE plpgsql AS $$
DECLARE
    b record;
    r numeric;
BEGIN
    FOR b IN SELECT * FROM recall_guard.baselines LOOP
        BEGIN
            r := recall_guard.measure(b.index_name::regclass, b.k, b.sample_size);
        EXCEPTION WHEN OTHERS THEN
            -- Un índice que ya no se puede medir es una novedad, no un silencio.
            index_name := b.index_name; baseline := b.recall;
            current := NULL; drift := NULL;
            verdict := 'NO SE PUDO MEDIR: ' || SQLERRM;
            RETURN NEXT;
            CONTINUE;
        END;

        index_name := b.index_name;
        baseline   := b.recall;
        current    := r;
        drift      := round(r - b.recall, 4);
        verdict    := CASE
            WHEN r >= b.recall - 0.02 THEN 'ok'
            WHEN r >= b.recall - 0.10 THEN 'degradado'
            ELSE 'critico'
        END;
        RETURN NEXT;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION recall_guard.check() IS
    'Vuelve a medir cada índice aprobado y compara con su línea base. '
    'Pensado para agendarse con pg_cron: la degradación de un índice ANN es gradual '
    'y silenciosa, así que el único momento en que se detecta es cuando alguien mira.';
