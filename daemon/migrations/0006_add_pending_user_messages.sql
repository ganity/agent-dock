create table pending_user_messages (
  id integer primary key autoincrement,
  session_id text not null,
  text text not null,
  image_paths_json text not null,
  status text not null default 'pending',
  sent_at text,
  created_at text not null,
  foreign key(session_id) references sessions(id) on delete cascade
);

create index idx_pending_user_messages_session_id_id
  on pending_user_messages(session_id, id);

create index idx_pending_user_messages_session_id_status_id
  on pending_user_messages(session_id, status, id);
