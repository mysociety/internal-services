--
-- schema.sql:
-- Schema for event queuing service.
--
-- Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: schema.sql,v 1.1 2005-02-16 23:43:58 chris Exp $
--

--
-- Tasks on the queue are something like threads of control in a program. Each
-- task has an ID, a scope (identifying the subsystem which owns it) and a tag,
-- which identifies it to that subsystem (for instance, a message ID).
--
-- Each task has a stack. Each stack frame consists of some serialised data
-- (representing local variables, in effect). Tasks also have a map between
-- events (which may either be specific times, or labelled events which other
-- code informs us of) and the code to pass control to when those events occur,
-- identified as a RABX URL and function call (with optional arguments).
--
-- As well as passing control to other code when an event occurs, it is also
-- possible to pass control to a new state, and to return control to a previous
-- state (analogous to a subroutine call and return in a conventional program).
-- 

create table task (
    id serial not null primary key,
    scope text not null,            -- subsystem owning, e.g. "fyr-queue"
    tag text not null               -- optional subsystem-specific data to
                                    -- identify task, for instance a message ID
);

create index task_scope_idx on task(scope);
create index task_tag_idx on task(tag);

create unique index task_scope_tag_idx on task(scope, tag);

-- Stack frame. A "subroutine call" creates a new frame, which will have a
-- larger ID than the last. So current stack frame is the one with the largest
-- id for a given task_id.
create table frame (
    id serial not null primary key,
    task_id integer not null references task(id),
    state bytea not null            -- serialised local variables
);

-- View to tell us the current stack frame of a task.
create view task_currentframe (task_id, frame_id) as
    select id,
        (select frame.id from frame where frame.task_id = id
            order by id desc limit 1)
    from task;

-- What events take effect on a task. We can only be waiting on events in one
-- frame, so these are task-global.
create table event_handler (
    id serial not null primary key,
    task_id integer not null references task(id),
    label text,                     -- label for a labelled event
    deadline integer,               -- time for a timed event
    url text not null,              -- RABX URL to call
    functionname text not null,     -- function name to call
    arguments bytea,                -- optional arguments
    check ((label is null and deadline is not null)
            or (label is not null and deadline is null))
);

create index event_handler_frame_id_label_deadline_idx on event_handler(frame_id, label, deadline);
create index event_handler_deadline_idx on event_handler(deadline);
create index event_handler_label_idx on event_handler(label);

-- Pending labelled events.
create table event (
    task_id integer not null references task(id),
    label text not null,
    arguments bytea,                -- optional further arguments
    primary key (task_id, label)
);
