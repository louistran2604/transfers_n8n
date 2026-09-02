ALTER TABLE transfer_reports
  ADD COLUMN move_effective_on text;

ALTER TABLE transfer_reports
  ADD CONSTRAINT transfer_reports_move_effective_on_format
  CHECK (
    move_effective_on IS NULL
    OR move_effective_on ~ '^[0-9]{4}-(0[1-9]|1[0-2])(-[0-9]{2})?$'
  );
