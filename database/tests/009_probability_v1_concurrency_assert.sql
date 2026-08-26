\set ON_ERROR_STOP on

DO $$
BEGIN
  IF (
    SELECT count(*) = 2
      AND count(*) FILTER (WHERE raw_probability IS NOT NULL) = 2
      AND count(*) FILTER (WHERE normalized_probability IS NOT NULL) = 2
    FROM transfer_reports
    WHERE id IN (SELECT report_id FROM probability_v1_concurrency_fixture)
  ) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'concurrent case applications did not both commit';
  END IF;

  IF (
    SELECT sum(normalized_probability) + max(stay_probability) = 1.00000
    FROM transfer_reports report
    JOIN transfer_cases transfer_case ON transfer_case.id = report.transfer_case_id
    WHERE report.id IN (SELECT report_id FROM probability_v1_concurrency_fixture)
  ) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'concurrent case projections do not total 1.00000';
  END IF;
END;
$$;

DROP TRIGGER probability_v1_concurrency_pause ON transfer_evidence;
DROP FUNCTION probability_v1_concurrency_pause();
DROP TABLE probability_v1_concurrency_fixture;

SELECT 'probability-v1 concurrency test passed' AS result;
