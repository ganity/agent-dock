alter table sessions add column runtime_health text not null default 'unknown';
alter table sessions add column runtime_error_message text;
