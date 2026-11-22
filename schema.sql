SHOW search_path;
BEGIN;
DROP TABLE IF EXISTS sim_frame;
DROP TABLE IF EXISTS sim_state;
CREATE TABLE sim_state (
  singleton_id  BOOLEAN PRIMARY KEY DEFAULT TRUE,
  w             INTEGER NOT NULL,
  h             INTEGER NOT NULL,
  chunks        INTEGER NOT NULL,
  tick          INTEGER NOT NULL DEFAULT 0,
  dir           INTEGER NOT NULL DEFAULT 0,
  running       BOOLEAN NOT NULL DEFAULT FALSE,
  solid         BIGINT[][] NOT NULL,
  sand          BIGINT[][] NOT NULL,
  full_mask     BIGINT[] NOT NULL,
  last_mask     BIGINT NOT NULL,
  edge_left     BIGINT[] NOT NULL,
  edge_right    BIGINT[] NOT NULL,
  mom_l         BIGINT[][] NOT NULL DEFAULT array_fill(0::bigint, ARRAY[1,1])::bigint[][],
  mom_r         BIGINT[][] NOT NULL DEFAULT array_fill(0::bigint, ARRAY[1,1])::bigint[][],
  keep_frames   INTEGER NOT NULL DEFAULT 900
);
CREATE TABLE sim_frame (
  tick        INTEGER PRIMARY KEY,
  dir         INTEGER NOT NULL,
  sand        BIGINT[][] NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  mom_l       BIGINT[][],
  mom_r       BIGINT[][]
);
CREATE OR REPLACE FUNCTION sim_mask64()
RETURNS BIGINT
LANGUAGE SQL
IMMUTABLE
AS $$
  SELECT x'FFFFFFFFFFFFFFFF'::bit(64)::bigint;
$$;
CREATE OR REPLACE FUNCTION sim_row_zero(chunks INTEGER)
RETURNS BIGINT[]
LANGUAGE SQL
IMMUTABLE
AS $$
  SELECT array_fill(0::bigint, ARRAY[chunks]);
$$;
CREATE OR REPLACE FUNCTION sim_row_or(a BIGINT[], b BIGINT[])
RETURNS BIGINT[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE n INT; i INT; r BIGINT[];
BEGIN
  n := array_length(a,1);
  r := a;
  FOR i IN 1..n LOOP r[i] := a[i] | b[i]; END LOOP;
  RETURN r;
END;
$$;
CREATE OR REPLACE FUNCTION sim_row_and(a BIGINT[], b BIGINT[])
RETURNS BIGINT[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE n INT; i INT; r BIGINT[];
BEGIN
  n := array_length(a,1);
  r := a;
  FOR i IN 1..n LOOP r[i] := a[i] & b[i]; END LOOP;
  RETURN r;
END;
$$;
CREATE OR REPLACE FUNCTION sim_row_andnot(a BIGINT[], b BIGINT[])
RETURNS BIGINT[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE n INT; i INT; r BIGINT[];
BEGIN
  n := array_length(a,1);
  r := a;
  FOR i IN 1..n LOOP r[i] := a[i] & (~b[i]); END LOOP;
  RETURN r;
END;
$$;
CREATE OR REPLACE FUNCTION sim_row_not(a BIGINT[], full_mask BIGINT[])
RETURNS BIGINT[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE n INT; i INT; r BIGINT[];
BEGIN
  n := array_length(a,1);
  r := a;
  FOR i IN 1..n LOOP r[i] := (~a[i]) & full_mask[i]; END LOOP;
  RETURN r;
END;
$$;
CREATE OR REPLACE FUNCTION sim_row_shl1(a BIGINT[], full_mask BIGINT[], last_mask BIGINT)
RETURNS BIGINT[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  n INT; i INT;
  carry_in BIGINT := 0;
  carry_out BIGINT;
  r BIGINT[];
  v BIGINT;
BEGIN
  n := array_length(a,1);
  r := a;
  FOR i IN 1..n LOOP
    v := a[i];
    carry_out := (v >> 63) & 1;
    r[i] := (v << 1) | carry_in;
    IF i = n THEN r[i] := r[i] & last_mask;
    ELSE r[i] := r[i] & full_mask[i];
    END IF;
    carry_in := carry_out;
  END LOOP;
  RETURN r;
END;
$$;
CREATE OR REPLACE FUNCTION sim_row_shr1(a BIGINT[], full_mask BIGINT[], last_mask BIGINT)
RETURNS BIGINT[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  n INT; i INT;
  carry_in BIGINT := 0;
  carry_out BIGINT;
  r BIGINT[];
  v BIGINT;
BEGIN
  n := array_length(a,1);
  r := a;
  FOR i IN REVERSE n..1 LOOP
    v := a[i];
    carry_out := v & 1;
    r[i] := (v >> 1) | (carry_in << 63);
    IF i = n THEN r[i] := r[i] & last_mask;
    ELSE r[i] := r[i] & full_mask[i];
    END IF;
    carry_in := carry_out;
  END LOOP;
  RETURN r;
END;
$$;
CREATE OR REPLACE FUNCTION sim_row_empty(solid BIGINT[], sand BIGINT[], full_mask BIGINT[])
RETURNS BIGINT[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE occ BIGINT[];
BEGIN
  occ := sim_row_or(solid, sand);
  RETURN sim_row_not(occ, full_mask);
END;
$$;
CREATE OR REPLACE FUNCTION sim_rand_mask64(tick_i INTEGER, row_y INTEGER, chunk_i INTEGER)
RETURNS BIGINT
LANGUAGE SQL
IMMUTABLE
AS $$
  SELECT (
    (
      ('x' || substr(md5((tick_i::text || ':' || row_y::text || ':' || chunk_i::text)), 1, 16))
    )::bit(64)::bigint
  );
$$;
CREATE OR REPLACE FUNCTION sim_rand_sparse_mask64(tick_i INTEGER, row_y INTEGER, chunk_i INTEGER)
RETURNS BIGINT
LANGUAGE SQL
IMMUTABLE
AS $$
  SELECT
    sim_rand_mask64(tick_i, row_y, chunk_i)
    & sim_rand_mask64(tick_i + 101, row_y, chunk_i)
    & sim_rand_mask64(tick_i + 211, row_y, chunk_i);
$$;
CREATE OR REPLACE FUNCTION sim_start()
RETURNS VOID
LANGUAGE SQL
AS $$
  UPDATE sim_state SET running = TRUE WHERE singleton_id = TRUE;
$$;
CREATE OR REPLACE FUNCTION sim_stop()
RETURNS VOID
LANGUAGE SQL
AS $$
  UPDATE sim_state SET running = FALSE WHERE singleton_id = TRUE;
$$;
CREATE OR REPLACE FUNCTION sim_status()
RETURNS TABLE(
  w INTEGER, h INTEGER, chunks INTEGER,
  tick INTEGER, dir INTEGER, running BOOLEAN,
  keep_frames INTEGER
)
LANGUAGE SQL
AS $$
  SELECT w, h, chunks, tick, dir, running, keep_frames
  FROM sim_state
  WHERE singleton_id = TRUE;
$$;
CREATE OR REPLACE FUNCTION sim_get_state()
RETURNS TABLE(
  w INTEGER, h INTEGER, chunks INTEGER,
  tick INTEGER, running BOOLEAN,
  solid BIGINT[][],
  sand BIGINT[][]
)
LANGUAGE SQL
AS $$
  SELECT w, h, chunks, tick, running, solid, sand
  FROM sim_state
  WHERE singleton_id = TRUE;
$$;
CREATE OR REPLACE FUNCTION sim_history_range()
RETURNS TABLE(min_tick INTEGER, max_tick INTEGER)
LANGUAGE SQL
AS $$
  SELECT MIN(tick), MAX(tick) FROM sim_frame;
$$;
CREATE OR REPLACE FUNCTION sim_rewind(target_tick INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  state_data RECORD;
  frame_data RECORD;
BEGIN
  SELECT * INTO state_data FROM sim_state WHERE singleton_id = TRUE FOR UPDATE;
  IF state_data.running THEN
    RAISE EXCEPTION 'Cannot rewind while running. Stop the simulation first.';
  END IF;
  SELECT * INTO frame_data FROM sim_frame WHERE tick = target_tick;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No such tick in history: %', target_tick;
  END IF;
  UPDATE sim_state
  SET tick = frame_data.tick,
      dir  = frame_data.dir,
      sand = frame_data.sand,
      mom_l = COALESCE(state_data.mom_l, sim_grid_zero(state_data.h, state_data.chunks)),
      mom_r = COALESCE(state_data.mom_r, sim_grid_zero(state_data.h, state_data.chunks))
  WHERE singleton_id = TRUE;
  RETURN frame_data.tick;
END;
$$;
CREATE OR REPLACE FUNCTION sim_init(sim_w INTEGER DEFAULT 256, sim_h INTEGER DEFAULT 144, sim_keep_frames INTEGER DEFAULT 900)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  chunks INTEGER;
  last_bits INTEGER;
  full_mask_arr BIGINT[];
  last_mask BIGINT;
  edge_left_arr BIGINT[];
  edge_right_arr BIGINT[];
  bitpos INTEGER;
  state_data RECORD;
BEGIN
  IF sim_w <= 0 OR sim_h <= 0 THEN
    RAISE EXCEPTION 'Invalid dimensions';
  END IF;
  chunks := (sim_w + 63) / 64;
  last_bits := sim_w - (chunks - 1) * 64;
  full_mask_arr := array_fill(sim_mask64(), ARRAY[chunks]);
  IF last_bits = 64 THEN
    last_mask := sim_mask64();
  ELSE
    last_mask := ((1::bigint << last_bits) - 1);
  END IF;
  edge_left_arr := array_fill(0::bigint, ARRAY[chunks]);
  edge_left_arr[1] := 1;
  edge_right_arr := array_fill(0::bigint, ARRAY[chunks]);
  bitpos := (sim_w - 1) % 64;
  edge_right_arr[chunks] := (1::bigint << bitpos);
  INSERT INTO sim_state (
    singleton_id, w, h, chunks, tick, dir, running,
    solid, sand,
    mom_l, mom_r,
    full_mask, last_mask, edge_left, edge_right,
    keep_frames
  )
  VALUES (
    TRUE, sim_w, sim_h, chunks, 0, 0, FALSE,
    sim_grid_zero(sim_h, chunks),
    sim_grid_zero(sim_h, chunks),
    sim_grid_zero(sim_h, chunks),
    sim_grid_zero(sim_h, chunks),
    full_mask_arr, last_mask, edge_left_arr, edge_right_arr,
    sim_keep_frames
  )
  ON CONFLICT (singleton_id) DO UPDATE
  SET w=EXCLUDED.w,
      h=EXCLUDED.h,
      chunks=EXCLUDED.chunks,
      tick=0,
      dir=0,
      running=FALSE,
      solid=EXCLUDED.solid,
      sand=EXCLUDED.sand,
      mom_l=EXCLUDED.mom_l,
      mom_r=EXCLUDED.mom_r,
      full_mask=EXCLUDED.full_mask,
      last_mask=EXCLUDED.last_mask,
      edge_left=EXCLUDED.edge_left,
      edge_right=EXCLUDED.edge_right,
      keep_frames=EXCLUDED.keep_frames;
END;
$$;
DROP FUNCTION IF EXISTS sim_grid_zero(integer, integer);
CREATE FUNCTION sim_grid_zero(h INTEGER, chunks INTEGER)
RETURNS BIGINT[][]
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  g BIGINT[][];
BEGIN
  IF h IS NULL OR chunks IS NULL THEN
    RAISE EXCEPTION 'sim_grid_zero called with NULL args: h=% chunks=%', h, chunks;
  END IF;
  IF h < 0 OR chunks <= 0 THEN
    RAISE EXCEPTION 'sim_grid_zero called with invalid args: h=% chunks=%', h, chunks;
  END IF;
  g := array_fill(0::bigint, ARRAY[h, chunks])::bigint[][];
  IF h > 0 AND chunks > 0 THEN
    IF g[1][1] IS NULL THEN
      RAISE EXCEPTION 'sim_grid_zero produced NULL at [1][1] unexpectedly';
    END IF;
  END IF;
  RETURN g;
END;
$$;
CREATE OR REPLACE FUNCTION sim_add_solid_rect(x0 INTEGER, y0 INTEGER, rw INTEGER, rh INTEGER)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  state_data RECORD;
  x1 INTEGER := x0 + rw - 1;
  y1 INTEGER := y0 + rh - 1;
  y INTEGER;
  chunks INTEGER;
  w INTEGER;
  last_mask BIGINT;
  solid_grid BIGINT[][];
  i INTEGER;
  chunk_idx INTEGER;
  bit_from INTEGER;
  bit_to INTEGER;
  mask BIGINT;
  local_from INTEGER;
  local_to INTEGER;
  cur BIGINT;
BEGIN
  SELECT * INTO state_data FROM sim_state WHERE singleton_id = TRUE FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'sim_add_solid_rect called but sim_state is missing (did sim_init fail?)';
  END IF;
  w := state_data.w;
  chunks := state_data.chunks;
  last_mask := state_data.last_mask;
  solid_grid := state_data.solid;
  IF rw <= 0 OR rh <= 0 THEN RETURN; END IF;
  IF x0 < 0 THEN x0 := 0; END IF;
  IF y0 < 0 THEN y0 := 0; END IF;
  IF x1 >= w THEN x1 := w - 1; END IF;
  IF y1 >= state_data.h THEN y1 := state_data.h - 1; END IF;
  IF x0 > x1 OR y0 > y1 THEN RETURN; END IF;
  FOR y IN y0..y1 LOOP
    FOR i IN 0..(chunks-1) LOOP
      chunk_idx := i + 1;
      bit_from := i * 64;
      bit_to := bit_from + 63;
      IF x1 < bit_from OR x0 > bit_to THEN
        CONTINUE;
      END IF;
      local_from := GREATEST(0, x0 - bit_from);
      local_to   := LEAST(63, x1 - bit_from);
      IF local_to = 63 THEN
        mask := x'FFFFFFFFFFFFFFFF'::bit(64)::bigint;
      ELSE
        mask := (1::bigint << (local_to + 1)) - 1;
      END IF;
      IF local_from > 0 THEN
        mask := mask & ~((1::bigint << local_from) - 1);
      END IF;
      cur := COALESCE(solid_grid[y+1][chunk_idx], 0::bigint);
      solid_grid[y+1][chunk_idx] := cur | mask;
    END LOOP;
    solid_grid[y+1][chunks] := COALESCE(solid_grid[y+1][chunks], 0::bigint) & last_mask;
  END LOOP;
  UPDATE sim_state
  SET solid = solid_grid
  WHERE singleton_id = TRUE;
END;
$$;
CREATE OR REPLACE FUNCTION sim_add_sand_rect(x0 INTEGER, y0 INTEGER, rw INTEGER, rh INTEGER)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  state_data RECORD;
  x1 INTEGER := x0 + rw - 1;
  y1 INTEGER := y0 + rh - 1;
  y INTEGER;
  chunks INTEGER;
  w INTEGER;
  last_mask BIGINT;
  sand_grid BIGINT[][];
  solid_grid BIGINT[][];
  i INTEGER;
  chunk_idx INTEGER;
  bit_from INTEGER;
  bit_to INTEGER;
  mask BIGINT;
  local_from INTEGER;
  local_to INTEGER;
  curw BIGINT;
  curs BIGINT;
BEGIN
  SELECT * INTO state_data FROM sim_state WHERE singleton_id = TRUE FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'sim_add_sand_rect called but sim_state is missing (did sim_init fail?)';
  END IF;
  w := state_data.w;
  chunks := state_data.chunks;
  last_mask := state_data.last_mask;
  sand_grid := state_data.sand;
  solid_grid := state_data.solid;
  IF rw <= 0 OR rh <= 0 THEN RETURN; END IF;
  IF x0 < 0 THEN x0 := 0; END IF;
  IF y0 < 0 THEN y0 := 0; END IF;
  IF x1 >= w THEN x1 := w - 1; END IF;
  IF y1 >= state_data.h THEN y1 := state_data.h - 1; END IF;
  IF x0 > x1 OR y0 > y1 THEN RETURN; END IF;
  FOR y IN y0..y1 LOOP
    FOR i IN 0..(chunks-1) LOOP
      chunk_idx := i + 1;
      bit_from := i * 64;
      bit_to := bit_from + 63;
      IF x1 < bit_from OR x0 > bit_to THEN
        CONTINUE;
      END IF;
      local_from := GREATEST(0, x0 - bit_from);
      local_to   := LEAST(63, x1 - bit_from);
      IF local_to = 63 THEN
        mask := x'FFFFFFFFFFFFFFFF'::bit(64)::bigint;
      ELSE
        mask := (1::bigint << (local_to + 1)) - 1;
      END IF;
      IF local_from > 0 THEN
        mask := mask & ~((1::bigint << local_from) - 1);
      END IF;
      curs := COALESCE(solid_grid[y+1][chunk_idx], 0::bigint);
      curw := COALESCE(sand_grid[y+1][chunk_idx], 0::bigint);
      mask := mask & ~curs;
      sand_grid[y+1][chunk_idx] := curw | mask;
    END LOOP;
    sand_grid[y+1][chunks] := COALESCE(sand_grid[y+1][chunks], 0::bigint) & last_mask;
  END LOOP;
  UPDATE sim_state
  SET sand = sand_grid
  WHERE singleton_id = TRUE;
END;
$$;
CREATE OR REPLACE FUNCTION sim_grid_get_row(g BIGINT[][], y INTEGER, chunks INTEGER)
RETURNS BIGINT[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  r BIGINT[] := array_fill(0::bigint, ARRAY[chunks]);
  i INTEGER;
BEGIN
  FOR i IN 1..chunks LOOP
    r[i] := COALESCE(g[y][i], 0::bigint);
  END LOOP;
  RETURN r;
END;
$$;
CREATE OR REPLACE FUNCTION sim_grid_set_row(g BIGINT[][], y INTEGER, r BIGINT[])
RETURNS BIGINT[][]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  i INTEGER;
  chunks INTEGER := array_length(r, 1);
BEGIN
  FOR i IN 1..chunks LOOP
    g[y][i] := COALESCE(r[i], 0::bigint);
  END LOOP;
  RETURN g;
END;
$$;
CREATE OR REPLACE FUNCTION sim_step()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  w_state INTEGER;
  h_state INTEGER;
  chunks_state INTEGER;
  last_mask_state BIGINT;
  full_mask_arr BIGINT[];
  edge_left_arr BIGINT[];
  edge_right_arr BIGINT[];
  keep_frames_state INTEGER;
  running_state BOOLEAN;
  tick_state INTEGER;
  dir_step INTEGER;
  solid_grid BIGINT[][];
  sand_grid BIGINT[][];
  momL_grid BIGINT[][];
  momR_grid BIGINT[][];
  empt_grid BIGINT[][];
  y INTEGER;
  row_w BIGINT[];
  row_s BIGINT[];
  row_e BIGINT[];
  above_e BIGINT[];
  below_w BIGINT[];
  below_e BIGINT[];
  fall BIGINT[];
  stay BIGINT[];
  want BIGINT[];
  src BIGINT[];
  tgt BIGINT[];
  row_mL BIGINT[];
  row_mR BIGINT[];
  surface BIGINT[];
  rmask BIGINT[];
  r BIGINT;
  next_tick INTEGER;
  lateral_steps INTEGER := 2;
  surface_steps INTEGER := 1;
  step_i INTEGER;
  row_dir INTEGER;
BEGIN
  SELECT
    w, h, chunks, last_mask, full_mask, edge_left, edge_right,
    keep_frames, running, tick, dir,
    solid, sand, mom_l, mom_r
  INTO
    w_state, h_state, chunks_state, last_mask_state, full_mask_arr, edge_left_arr, edge_right_arr,
    keep_frames_state, running_state, tick_state, dir_step,
    solid_grid, sand_grid, momL_grid, momR_grid
  FROM sim_state
  WHERE singleton_id = TRUE
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF NOT running_state THEN
    RETURN tick_state;
  END IF;
  empt_grid := sim_grid_zero(h_state, chunks_state);
  FOR y IN 1..h_state LOOP
    row_s := sim_grid_get_row(solid_grid, y, chunks_state);
    row_w := sim_grid_get_row(sand_grid, y, chunks_state);
    row_e := sim_row_empty(row_s, row_w, full_mask_arr);
    empt_grid := sim_grid_set_row(empt_grid, y, row_e);
  END LOOP;
  FOR y IN 2..h_state LOOP
    row_w := sim_grid_get_row(sand_grid, y, chunks_state);
    below_e := sim_grid_get_row(empt_grid, y-1, chunks_state);
    fall := sim_row_and(row_w, below_e);
    IF fall IS DISTINCT FROM sim_row_zero(chunks_state) THEN
      row_w := sim_row_andnot(row_w, fall);
      sand_grid := sim_grid_set_row(sand_grid, y, row_w);
      below_w := sim_grid_get_row(sand_grid, y-1, chunks_state);
      below_w := sim_row_or(below_w, fall);
      sand_grid := sim_grid_set_row(sand_grid, y-1, below_w);
      row_mL := sim_grid_get_row(momL_grid, y, chunks_state);
      row_mR := sim_grid_get_row(momR_grid, y, chunks_state);
      src := sim_row_and(row_mL, fall);
      row_mL := sim_row_andnot(row_mL, fall);
      momL_grid := sim_grid_set_row(momL_grid, y, row_mL);
      tgt := sim_grid_get_row(momL_grid, y-1, chunks_state);
      tgt := sim_row_or(tgt, src);
      momL_grid := sim_grid_set_row(momL_grid, y-1, tgt);
      src := sim_row_and(row_mR, fall);
      row_mR := sim_row_andnot(row_mR, fall);
      momR_grid := sim_grid_set_row(momR_grid, y, row_mR);
      tgt := sim_grid_get_row(momR_grid, y-1, chunks_state);
      tgt := sim_row_or(tgt, src);
      momR_grid := sim_grid_set_row(momR_grid, y-1, tgt);
      row_e := sim_grid_get_row(empt_grid, y, chunks_state);
      row_e := sim_row_or(row_e, fall);
      empt_grid := sim_grid_set_row(empt_grid, y, row_e);
      below_e := sim_row_andnot(below_e, fall);
      empt_grid := sim_grid_set_row(empt_grid, y-1, below_e);
    END IF;
  END LOOP;
  FOR y IN 2..h_state LOOP
    row_w := sim_grid_get_row(sand_grid, y, chunks_state);
    below_e := sim_grid_get_row(empt_grid, y-1, chunks_state);
    stay := sim_row_andnot(row_w, below_e);
    IF stay IS DISTINCT FROM sim_row_zero(chunks_state) THEN
      IF dir_step = 0 THEN
        want := sim_row_shl1(below_e, full_mask_arr, last_mask_state);
        src  := sim_row_and(stay, want);
        src  := sim_row_andnot(src, edge_left_arr);
        IF src IS DISTINCT FROM sim_row_zero(chunks_state) THEN
          tgt := sim_row_shr1(src, full_mask_arr, last_mask_state);
          row_w := sim_row_andnot(row_w, src);
          sand_grid := sim_grid_set_row(sand_grid, y, row_w);
          below_w := sim_grid_get_row(sand_grid, y-1, chunks_state);
          below_w := sim_row_or(below_w, tgt);
          sand_grid := sim_grid_set_row(sand_grid, y-1, below_w);
          row_mL := sim_grid_get_row(momL_grid, y, chunks_state);
          row_mR := sim_grid_get_row(momR_grid, y, chunks_state);
          fall := sim_row_and(row_mL, src);
          row_mL := sim_row_andnot(row_mL, src);
          momL_grid := sim_grid_set_row(momL_grid, y, row_mL);
          want := sim_row_and(row_mR, src);
          row_mR := sim_row_andnot(row_mR, src);
          momR_grid := sim_grid_set_row(momR_grid, y, row_mR);
          below_w := sim_grid_get_row(momL_grid, y-1, chunks_state);
          below_w := sim_row_or(below_w, sim_row_shr1(fall, full_mask_arr, last_mask_state));
          below_w := sim_row_or(below_w, tgt);
          momL_grid := sim_grid_set_row(momL_grid, y-1, below_w);
          below_w := sim_grid_get_row(momR_grid, y-1, chunks_state);
          below_w := sim_row_or(below_w, sim_row_shr1(want, full_mask_arr, last_mask_state));
          momR_grid := sim_grid_set_row(momR_grid, y-1, below_w);
          row_e := sim_grid_get_row(empt_grid, y, chunks_state);
          row_e := sim_row_or(row_e, src);
          empt_grid := sim_grid_set_row(empt_grid, y, row_e);
          below_e := sim_row_andnot(below_e, tgt);
          empt_grid := sim_grid_set_row(empt_grid, y-1, below_e);
          stay := sim_row_andnot(stay, src);
          below_e := sim_grid_get_row(empt_grid, y-1, chunks_state);
        END IF;
        want := sim_row_shr1(below_e, full_mask_arr, last_mask_state);
        src  := sim_row_and(stay, want);
        src  := sim_row_andnot(src, edge_right_arr);
        IF src IS DISTINCT FROM sim_row_zero(chunks_state) THEN
          tgt := sim_row_shl1(src, full_mask_arr, last_mask_state);
          row_w := sim_grid_get_row(sand_grid, y, chunks_state);
          row_w := sim_row_andnot(row_w, src);
          sand_grid := sim_grid_set_row(sand_grid, y, row_w);
          below_w := sim_grid_get_row(sand_grid, y-1, chunks_state);
          below_w := sim_row_or(below_w, tgt);
          sand_grid := sim_grid_set_row(sand_grid, y-1, below_w);
          row_mL := sim_grid_get_row(momL_grid, y, chunks_state);
          row_mR := sim_grid_get_row(momR_grid, y, chunks_state);
          fall := sim_row_and(row_mL, src);
          row_mL := sim_row_andnot(row_mL, src);
          momL_grid := sim_grid_set_row(momL_grid, y, row_mL);
          want := sim_row_and(row_mR, src);
          row_mR := sim_row_andnot(row_mR, src);
          momR_grid := sim_grid_set_row(momR_grid, y, row_mR);
          below_w := sim_grid_get_row(momL_grid, y-1, chunks_state);
          below_w := sim_row_or(below_w, sim_row_shl1(fall, full_mask_arr, last_mask_state));
          momL_grid := sim_grid_set_row(momL_grid, y-1, below_w);
          below_w := sim_grid_get_row(momR_grid, y-1, chunks_state);
          below_w := sim_row_or(below_w, sim_row_shl1(want, full_mask_arr, last_mask_state));
          below_w := sim_row_or(below_w, tgt);
          momR_grid := sim_grid_set_row(momR_grid, y-1, below_w);
          row_e := sim_grid_get_row(empt_grid, y, chunks_state);
          row_e := sim_row_or(row_e, src);
          empt_grid := sim_grid_set_row(empt_grid, y, row_e);
          below_e := sim_grid_get_row(empt_grid, y-1, chunks_state);
          below_e := sim_row_andnot(below_e, tgt);
          empt_grid := sim_grid_set_row(empt_grid, y-1, below_e);
        END IF;
      ELSE
        want := sim_row_shr1(below_e, full_mask_arr, last_mask_state);
        src  := sim_row_and(stay, want);
        src  := sim_row_andnot(src, edge_right_arr);
        IF src IS DISTINCT FROM sim_row_zero(chunks_state) THEN
          tgt := sim_row_shl1(src, full_mask_arr, last_mask_state);
          row_w := sim_row_andnot(row_w, src);
          sand_grid := sim_grid_set_row(sand_grid, y, row_w);
          below_w := sim_grid_get_row(sand_grid, y-1, chunks_state);
          below_w := sim_row_or(below_w, tgt);
          sand_grid := sim_grid_set_row(sand_grid, y-1, below_w);
          row_mL := sim_grid_get_row(momL_grid, y, chunks_state);
          row_mR := sim_grid_get_row(momR_grid, y, chunks_state);
          fall := sim_row_and(row_mL, src);
          row_mL := sim_row_andnot(row_mL, src);
          momL_grid := sim_grid_set_row(momL_grid, y, row_mL);
          want := sim_row_and(row_mR, src);
          row_mR := sim_row_andnot(row_mR, src);
          momR_grid := sim_grid_set_row(momR_grid, y, row_mR);
          below_w := sim_grid_get_row(momL_grid, y-1, chunks_state);
          below_w := sim_row_or(below_w, sim_row_shl1(fall, full_mask_arr, last_mask_state));
          momL_grid := sim_grid_set_row(momL_grid, y-1, below_w);
          below_w := sim_grid_get_row(momR_grid, y-1, chunks_state);
          below_w := sim_row_or(below_w, sim_row_shl1(want, full_mask_arr, last_mask_state));
          below_w := sim_row_or(below_w, tgt);
          momR_grid := sim_grid_set_row(momR_grid, y-1, below_w);
          row_e := sim_grid_get_row(empt_grid, y, chunks_state);
          row_e := sim_row_or(row_e, src);
          empt_grid := sim_grid_set_row(empt_grid, y, row_e);
          below_e := sim_row_andnot(below_e, tgt);
          empt_grid := sim_grid_set_row(empt_grid, y-1, below_e);
          stay := sim_row_andnot(stay, src);
          below_e := sim_grid_get_row(empt_grid, y-1, chunks_state);
        END IF;
        want := sim_row_shl1(below_e, full_mask_arr, last_mask_state);
        src  := sim_row_and(stay, want);
        src  := sim_row_andnot(src, edge_left_arr);
        IF src IS DISTINCT FROM sim_row_zero(chunks_state) THEN
          tgt := sim_row_shr1(src, full_mask_arr, last_mask_state);
          row_w := sim_grid_get_row(sand_grid, y, chunks_state);
          row_w := sim_row_andnot(row_w, src);
          sand_grid := sim_grid_set_row(sand_grid, y, row_w);
          below_w := sim_grid_get_row(sand_grid, y-1, chunks_state);
          below_w := sim_row_or(below_w, tgt);
          sand_grid := sim_grid_set_row(sand_grid, y-1, below_w);
          row_mL := sim_grid_get_row(momL_grid, y, chunks_state);
          row_mR := sim_grid_get_row(momR_grid, y, chunks_state);
          fall := sim_row_and(row_mL, src);
          row_mL := sim_row_andnot(row_mL, src);
          momL_grid := sim_grid_set_row(momL_grid, y, row_mL);
          want := sim_row_and(row_mR, src);
          row_mR := sim_row_andnot(row_mR, src);
          momR_grid := sim_grid_set_row(momR_grid, y, row_mR);
          below_w := sim_grid_get_row(momL_grid, y-1, chunks_state);
          below_w := sim_row_or(below_w, sim_row_shr1(fall, full_mask_arr, last_mask_state));
          below_w := sim_row_or(below_w, tgt);
          momL_grid := sim_grid_set_row(momL_grid, y-1, below_w);
          below_w := sim_grid_get_row(momR_grid, y-1, chunks_state);
          below_w := sim_row_or(below_w, sim_row_shr1(want, full_mask_arr, last_mask_state));
          momR_grid := sim_grid_set_row(momR_grid, y-1, below_w);
          row_e := sim_grid_get_row(empt_grid, y, chunks_state);
          row_e := sim_row_or(row_e, src);
          empt_grid := sim_grid_set_row(empt_grid, y, row_e);
          below_e := sim_grid_get_row(empt_grid, y-1, chunks_state);
          below_e := sim_row_andnot(below_e, tgt);
          empt_grid := sim_grid_set_row(empt_grid, y-1, below_e);
        END IF;
      END IF;
    END IF;
  END LOOP;
  FOR step_i IN 1..lateral_steps LOOP
    FOR y IN 1..h_state LOOP
      row_w := sim_grid_get_row(sand_grid, y, chunks_state);
      row_e := sim_grid_get_row(empt_grid, y, chunks_state);
      IF row_w IS DISTINCT FROM sim_row_zero(chunks_state) THEN
        row_mL := sim_grid_get_row(momL_grid, y, chunks_state);
        row_mR := sim_grid_get_row(momR_grid, y, chunks_state);
        r := sim_rand_mask64(tick_state + step_i, y, 1);
        row_dir := CASE
          WHEN ((sim_rand_mask64((tick_state / 6), y, 1) & 7)::int) = 0
            THEN 1 - dir_step
          ELSE dir_step
        END;
        IF row_dir = 0 THEN
          want := sim_row_shl1(row_e, full_mask_arr, last_mask_state);
          src  := sim_row_and(row_w, want);
          src  := sim_row_andnot(src, edge_left_arr);
          rmask := sim_row_zero(chunks_state);
          FOR r IN 1..chunks_state LOOP
            rmask[r] := sim_rand_mask64(tick_state + step_i, y, r);
          END LOOP;
          fall := sim_row_and(src, row_mL);
          IF fall IS DISTINCT FROM sim_row_zero(chunks_state) THEN
            tgt := sim_row_shr1(fall, full_mask_arr, last_mask_state);
            row_w := sim_row_andnot(row_w, fall);
            row_w := sim_row_or(row_w, tgt);
            sand_grid := sim_grid_set_row(sand_grid, y, row_w);
            row_mL := sim_row_andnot(row_mL, fall);
            row_mL := sim_row_or(row_mL, tgt);
            momL_grid := sim_grid_set_row(momL_grid, y, row_mL);
            row_mR := sim_row_andnot(row_mR, fall);
            momR_grid := sim_grid_set_row(momR_grid, y, row_mR);
            row_e := sim_row_or(row_e, fall);
            row_e := sim_row_andnot(row_e, tgt);
            empt_grid := sim_grid_set_row(empt_grid, y, row_e);
          END IF;
          row_w := sim_grid_get_row(sand_grid, y, chunks_state);
          row_e := sim_grid_get_row(empt_grid, y, chunks_state);
          want := sim_row_shl1(row_e, full_mask_arr, last_mask_state);
          src  := sim_row_and(row_w, want);
          src  := sim_row_andnot(src, edge_left_arr);
          src  := sim_row_and(row_w, want);
          src  := sim_row_andnot(src, edge_left_arr);
          src  := sim_row_andnot(src, row_mL);
          src  := sim_row_and(src, rmask);
          IF src IS DISTINCT FROM sim_row_zero(chunks_state) THEN
            tgt := sim_row_shr1(src, full_mask_arr, last_mask_state);
            row_w := sim_row_andnot(row_w, src);
            row_w := sim_row_or(row_w, tgt);
            sand_grid := sim_grid_set_row(sand_grid, y, row_w);
            row_mL := sim_grid_get_row(momL_grid, y, chunks_state);
            row_mR := sim_grid_get_row(momR_grid, y, chunks_state);
            row_mL := sim_row_or(sim_row_andnot(row_mL, src), tgt);
            row_mR := sim_row_andnot(row_mR, src);
            momL_grid := sim_grid_set_row(momL_grid, y, row_mL);
            momR_grid := sim_grid_set_row(momR_grid, y, row_mR);
            row_e := sim_row_or(row_e, src);
            row_e := sim_row_andnot(row_e, tgt);
            empt_grid := sim_grid_set_row(empt_grid, y, row_e);
          END IF;
          row_w := sim_grid_get_row(sand_grid, y, chunks_state);
          row_e := sim_grid_get_row(empt_grid, y, chunks_state);
          want := sim_row_shr1(row_e, full_mask_arr, last_mask_state);
          src  := sim_row_and(row_w, want);
          src  := sim_row_andnot(src, edge_right_arr);
          src := sim_row_and(src, rmask);
          IF src IS DISTINCT FROM sim_row_zero(chunks_state) THEN
            tgt := sim_row_shl1(src, full_mask_arr, last_mask_state);
            row_w := sim_row_andnot(row_w, src);
            row_w := sim_row_or(row_w, tgt);
            sand_grid := sim_grid_set_row(sand_grid, y, row_w);
            row_mL := sim_grid_get_row(momL_grid, y, chunks_state);
            row_mR := sim_grid_get_row(momR_grid, y, chunks_state);
            row_mR := sim_row_or(sim_row_andnot(row_mR, src), tgt);
            row_mL := sim_row_andnot(row_mL, src);
            momR_grid := sim_grid_set_row(momR_grid, y, row_mR);
            momL_grid := sim_grid_set_row(momL_grid, y, row_mL);
            row_e := sim_row_or(row_e, src);
            row_e := sim_row_andnot(row_e, tgt);
            empt_grid := sim_grid_set_row(empt_grid, y, row_e);
          END IF;
        ELSE
          want := sim_row_shr1(row_e, full_mask_arr, last_mask_state);
          src  := sim_row_and(row_w, want);
          src  := sim_row_andnot(src, edge_right_arr);
          rmask := sim_row_zero(chunks_state);
          FOR r IN 1..chunks_state LOOP
            rmask[r] := sim_rand_mask64(tick_state + step_i, y, r);
          END LOOP;
          fall := sim_row_and(src, row_mR);
          IF fall IS DISTINCT FROM sim_row_zero(chunks_state) THEN
            tgt := sim_row_shl1(fall, full_mask_arr, last_mask_state);
            row_w := sim_row_andnot(row_w, fall);
            row_w := sim_row_or(row_w, tgt);
            sand_grid := sim_grid_set_row(sand_grid, y, row_w);
            row_mR := sim_row_andnot(row_mR, fall);
            row_mR := sim_row_or(row_mR, tgt);
            momR_grid := sim_grid_set_row(momR_grid, y, row_mR);
            row_mL := sim_row_andnot(row_mL, fall);
            momL_grid := sim_grid_set_row(momL_grid, y, row_mL);
            row_e := sim_row_or(row_e, fall);
            row_e := sim_row_andnot(row_e, tgt);
            empt_grid := sim_grid_set_row(empt_grid, y, row_e);
          END IF;
          row_w := sim_grid_get_row(sand_grid, y, chunks_state);
          row_e := sim_grid_get_row(empt_grid, y, chunks_state);
          want := sim_row_shr1(row_e, full_mask_arr, last_mask_state);
          src  := sim_row_and(row_w, want);
          src  := sim_row_andnot(src, edge_right_arr);
          src  := sim_row_andnot(src, row_mR);
          src  := sim_row_and(src, rmask);
          IF src IS DISTINCT FROM sim_row_zero(chunks_state) THEN
            tgt := sim_row_shl1(src, full_mask_arr, last_mask_state);
            row_w := sim_row_andnot(row_w, src);
            row_w := sim_row_or(row_w, tgt);
            sand_grid := sim_grid_set_row(sand_grid, y, row_w);
            row_mL := sim_grid_get_row(momL_grid, y, chunks_state);
            row_mR := sim_grid_get_row(momR_grid, y, chunks_state);
            row_mR := sim_row_or(sim_row_andnot(row_mR, src), tgt);
            row_mL := sim_row_andnot(row_mL, src);
            momR_grid := sim_grid_set_row(momR_grid, y, row_mR);
            momL_grid := sim_grid_set_row(momL_grid, y, row_mL);
            row_e := sim_row_or(row_e, src);
            row_e := sim_row_andnot(row_e, tgt);
            empt_grid := sim_grid_set_row(empt_grid, y, row_e);
          END IF;
          row_w := sim_grid_get_row(sand_grid, y, chunks_state);
          row_e := sim_grid_get_row(empt_grid, y, chunks_state);
          want := sim_row_shl1(row_e, full_mask_arr, last_mask_state);
          src  := sim_row_and(row_w, want);
          src  := sim_row_andnot(src, edge_left_arr);
          src := sim_row_and(src, rmask);
          IF src IS DISTINCT FROM sim_row_zero(chunks_state) THEN
            tgt := sim_row_shr1(src, full_mask_arr, last_mask_state);
            row_w := sim_row_andnot(row_w, src);
            row_w := sim_row_or(row_w, tgt);
            sand_grid := sim_grid_set_row(sand_grid, y, row_w);
            row_mL := sim_grid_get_row(momL_grid, y, chunks_state);
            row_mR := sim_grid_get_row(momR_grid, y, chunks_state);
            row_mL := sim_row_or(sim_row_andnot(row_mL, src), tgt);
            row_mR := sim_row_andnot(row_mR, src);
            momL_grid := sim_grid_set_row(momL_grid, y, row_mL);
            momR_grid := sim_grid_set_row(momR_grid, y, row_mR);
            row_e := sim_row_or(row_e, src);
            row_e := sim_row_andnot(row_e, tgt);
            empt_grid := sim_grid_set_row(empt_grid, y, row_e);
          END IF;
        END IF;
      END IF;
    END LOOP;
  END LOOP;
  FOR step_i IN 1..surface_steps LOOP
    FOR y IN 1..(h_state-1) LOOP
      row_w := sim_grid_get_row(sand_grid, y, chunks_state);
      above_e := sim_grid_get_row(empt_grid, y+1, chunks_state);
      surface := sim_row_and(row_w, above_e);
      IF surface IS DISTINCT FROM sim_row_zero(chunks_state) THEN
        row_e := sim_grid_get_row(empt_grid, y, chunks_state);
        rmask := sim_row_zero(chunks_state);
        FOR r IN 1..chunks_state LOOP
          rmask[r] := sim_rand_mask64(tick_state + 1000 + step_i, y, r);
        END LOOP;
        IF ((dir_step + step_i) % 2) = 0 THEN
          want := sim_row_shl1(row_e, full_mask_arr, last_mask_state);
          src  := sim_row_and(surface, want);
          src  := sim_row_andnot(src, edge_left_arr);
          src  := sim_row_and(src, rmask);
          IF src IS DISTINCT FROM sim_row_zero(chunks_state) THEN
            tgt := sim_row_shr1(src, full_mask_arr, last_mask_state);
            row_w := sim_row_andnot(row_w, src);
            row_w := sim_row_or(row_w, tgt);
            sand_grid := sim_grid_set_row(sand_grid, y, row_w);
            row_e := sim_row_or(row_e, src);
            row_e := sim_row_andnot(row_e, tgt);
            empt_grid := sim_grid_set_row(empt_grid, y, row_e);
          END IF;
        ELSE
          want := sim_row_shr1(row_e, full_mask_arr, last_mask_state);
          src  := sim_row_and(surface, want);
          src  := sim_row_andnot(src, edge_right_arr);
          src  := sim_row_and(src, rmask);
          IF src IS DISTINCT FROM sim_row_zero(chunks_state) THEN
            tgt := sim_row_shl1(src, full_mask_arr, last_mask_state);
            row_w := sim_row_andnot(row_w, src);
            row_w := sim_row_or(row_w, tgt);
            sand_grid := sim_grid_set_row(sand_grid, y, row_w);
            row_e := sim_row_or(row_e, src);
            row_e := sim_row_andnot(row_e, tgt);
            empt_grid := sim_grid_set_row(empt_grid, y, row_e);
          END IF;
        END IF;
      END IF;
    END LOOP;
  END LOOP;
  FOR y IN 1..h_state LOOP
    IF (tick_state % 2) = 0 THEN
      rmask := sim_row_zero(chunks_state);
      FOR r IN 1..chunks_state LOOP
        rmask[r] := sim_rand_sparse_mask64(tick_state + 9999, y, r);
      END LOOP;
      row_mL := sim_row_andnot(row_mL, rmask);
      row_mR := sim_row_andnot(row_mR, rmask);
    END IF;
    rmask := sim_row_zero(chunks_state);
    FOR r IN 1..chunks_state LOOP
      rmask[r] := sim_rand_mask64(tick_state + 9999, y, r);
    END LOOP;
    row_mL := sim_row_andnot(row_mL, rmask);
    row_mR := sim_row_andnot(row_mR, rmask);
    momL_grid := sim_grid_set_row(momL_grid, y, row_mL);
    momR_grid := sim_grid_set_row(momR_grid, y, row_mR);
  END LOOP;
  next_tick := tick_state + 1;
  UPDATE sim_state
  SET sand = sand_grid,
      mom_l = momL_grid,
      mom_r = momR_grid,
      tick = next_tick,
      dir = 1 - dir_step
  WHERE singleton_id = TRUE;
  INSERT INTO sim_frame(tick, dir, sand, mom_l, mom_r)
  VALUES (next_tick, 1 - dir_step, sand_grid, momL_grid, momR_grid)
  ON CONFLICT (tick) DO NOTHING;
  DELETE FROM sim_frame
  WHERE tick < next_tick - keep_frames_state;
  RETURN next_tick;
END;
$$;
COMMIT;