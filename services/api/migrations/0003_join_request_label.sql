-- A human-readable label for who is asking to join (the email claim from their login token), so the
-- host can recognise requests. Display only: it never grants anything and is not used for identity.
alter table world_join_requests add column requester_label text;
