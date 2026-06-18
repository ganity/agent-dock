create table session_message_receipts (
  session_id text not null,
  client_message_id text not null,
  event_id integer not null,
  created_at text not null,
  primary key (session_id, client_message_id)
);
