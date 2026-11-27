-- Enum additions must commit before functions use the new value.
alter type public.task_status add value 'abandoned';
