create table if not exists users (
  id text primary key,
  username text not null unique,
  password_hash text not null,
  is_admin integer not null default 0,
  created_at text not null
);
