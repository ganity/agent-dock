create table sessions (
  id text primary key,
  root_id text not null,
  workspace_path text not null,
  source_kind text not null,
  agent_kind text not null,
  runtime_session_id text,
  status text not null,
  created_at text not null,
  updated_at text not null
);

create table session_events (
  id integer primary key autoincrement,
  session_id text not null,
  event_type text not null,
  payload_json text not null,
  created_at text not null
);
