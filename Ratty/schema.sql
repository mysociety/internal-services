--
-- schema.sql:
-- Postgres schema for rate-limiting.
--
-- Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: schema.sql,v 1.12 2005-01-13 13:44:45 chris Exp $
--

create table rule (
    id serial not null primary key,
    requests integer not null,  -- maximum allowed rate is requests / interval
    interval integer not null,  -- in seconds
    sequence integer not null,  -- place where this rule fits in the order
    scope text not null,        -- subsystem for which this rule applies
    note text,                  -- human-readable description
    message text                -- string associated with the rule; its meaning
                                -- depends on scope
);

create table condition (
    id serial not null primary key,
    rule_id integer not null references rule(id),
    field text not null,
    value text,
    -- conditions:
    condition char(1) check (
           condition = 'S'  -- single (see below)
        or condition = 'D'  -- distinct (see below)

        -- The remainder are called "local" conditions -- they only consider
        -- the values supplied for each hit, not for previous hits. See below.

        or condition = 'E'  -- exact match (apply rule only when field = value)
        or condition = 'R'  -- regex match (apply rule only when field matches
                            -- perl regex of value)
        or condition = 'I'  -- IP address/mask match (apply rule only when
                            -- field matches IP mask: w.x.y.z or w.x.y.z/nn or
                            -- w.x.y.z/a.b.c.d)
        or condition = '>'  -- numerically greater than (apply rule only when
                            -- field is numeric and field > value)
        or condition = '<'  -- numerically less than
        -- XXX we should also have 'T' for 'loose text match' and 'P' for
        -- 'field is present'
    ),
    -- should the sense of the check be inverted?
    invert boolean not null default ('f')
);

create index condition_rule_id_idx on condition(rule_id);

-- How does the single/distinct stuff work? When a hit happens for a 
-- rule which has single or disinct conditions, the following happens:
-- 
-- 1. Take all of the fields which are matched as single and checksum; call
--    this "shash".
-- 2. Take all of the fields which are matched as distinct and checksum them;
--    call this "dhash".
-- 3. Save both in rule_hit
-- 4. Now the test for whether the rate limit has triggered is based
--    on the number of hits where the shash is the same and the dhash is
--    different from this hit
-- 
-- e.g. Suppose I have a rule limiting to 60 hits / second, by IP
-- address. If the condition was "single" then it would allow every IP to
-- have 60 hits per second each. If the condition was "distinct" then only
-- 60 different IPs would be allowed to access the web page in each
-- second.


-- We want to keep track of any changes to the rule or condition tables, so
-- that ratty can update its own idea of which rules are current.
create table generation (
    number integer not null
);

insert into generation (number) values (0);

create function rule_modify_notify() returns trigger as '
    begin
    update generation set number = number + 1;
    return null;
    end;
' language 'plpgsql';

-- These should be statement triggers, but those aren't implemented in the
-- version of Postgres we're using.
create trigger rule_notify
    after delete or insert or update
    on rule
    for each row
    execute procedure rule_modify_notify();

create trigger condition_notify
    after delete or insert or update
    on condition
    for each row
    execute procedure rule_modify_notify();


-- Used for counting up requests in the time interval, so it knows when the
-- limit is exceeded. This table is not modified to set up rules, it is only
-- written to by ratty.
create table rule_hit (
    rule_id integer not null references rule(id),
    hit float8 not null,        -- UNIX timestamp + microseconds
    shash text null,            -- SHA1 of matching field values for 'S' matches
    dhash text null             -- SHA1 of matching field values for 'D' matches
);

create index rule_hit_rule_id_idx on rule_hit(rule_id);
create index rule_hit_shash_idx on rule_hit(shash);
create index rule_hit_dhash_idx on rule_hit(dhash);

create table field_example (
    scope text not null,
    field text not null,
    example text not null,
    -- no primary key as save >1 example for each field
);

create index field_example_scope_idx on field_example(scope);
create index field_example_scope_field_idx on field_example(scope, field);

create table field_description (
    scope text not null,
    field text not null,
    description text not null,
    primary key (scope, field)
);

create index field_description_scope_idx on field_description(scope);

-- grant all on database ratty to ratty;

