DO $$
DECLARE
  column_type text;
BEGIN
  SELECT data_type INTO column_type
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'transfer_reports'
    AND column_name = 'move_effective_on';

  IF column_type IS DISTINCT FROM 'text' THEN
    RAISE EXCEPTION 'move_effective_on must be nullable text, got %', column_type;
  END IF;
END;
$$;

CREATE TEMP TABLE transfer_effective_on_probe (
  move_effective_on text CHECK (
    move_effective_on IS NULL
    OR move_effective_on ~ '^[0-9]{4}-(0[1-9]|1[0-2])(-[0-9]{2})?$'
  )
);

INSERT INTO transfer_effective_on_probe (move_effective_on)
VALUES (NULL), ('2027-06'), ('2027-06-30');

DO $$
BEGIN
  BEGIN
    INSERT INTO transfer_effective_on_probe (move_effective_on) VALUES ('2027-13');
    RAISE EXCEPTION 'invalid month was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END;
$$;
