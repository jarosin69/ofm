-- 008 Polled PLC sources (ADR-0018).
-- Adds 'ethernetip' (Rockwell Logix controllers: ControlLogix, CompactLogix)
-- to the protocols a source may use, and checks the protocol settings the
-- runtime reads from config.source.settings:
--   s7          {"rack": 0, "slot": 1, "pollIntervalMs": 1000}   rack and slot required
--   ethernetip  {"slot": 0, "pollIntervalMs": 1000}               both optional
-- S7 must state rack and slot because the right slot differs between CPU
-- families (S7-1200/1500: 1; S7-300/400: 2) and a wrong one only shows up as
-- a refused connection.

ALTER TABLE config.source DROP CONSTRAINT source_protocol_check;
ALTER TABLE config.source ADD CONSTRAINT source_protocol_check
  CHECK (protocol IN ('opcua', 's7', 'ethernetip', 'modbus', 'mqtt'));

ALTER TABLE config.source ADD CONSTRAINT source_s7_rack_slot_required
  CHECK (protocol <> 's7'
         OR (COALESCE(jsonb_typeof(settings -> 'rack'), 'missing') = 'number'
             AND COALESCE(jsonb_typeof(settings -> 'slot'), 'missing') = 'number'));

ALTER TABLE config.source ADD CONSTRAINT source_poll_interval_valid
  CHECK (CASE
           WHEN NOT settings ? 'pollIntervalMs' THEN true
           WHEN jsonb_typeof(settings -> 'pollIntervalMs') <> 'number' THEN false
           ELSE (settings ->> 'pollIntervalMs')::numeric >= 100
         END);

COMMENT ON COLUMN config.source.settings IS
  'Protocol settings (JSON). opcua: securityMode, publishingIntervalMs, samplingIntervalMs. '
  's7: rack, slot (required), pollIntervalMs. ethernetip: slot, pollIntervalMs. '
  'pollIntervalMs: at least 100, default 1000 (ADR-0017, ADR-0018).';
