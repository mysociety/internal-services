--
-- schema.sql:
-- Postgres schema for rate-limiting.
--
-- Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: schema.sql,v 1.1 2004-11-10 13:08:00 francis Exp $
--

create table rule (
    id serial not null primary key,
    requests integer not null,  -- maximum allowed rate is requests / interval
    interval integer not null,  -- in seconds
    sequence integer not null,  -- place where this rule fits in the order
    key text,                   -- key usable by other code
    note text                   -- human-readable description
);

create index rule_key_idx on rule(key);

create table condition (
    id serial not null primary key,
    rule_id integer not null references rule(id),
    field text not null,
    -- conditions:
    -- 'S'  single
    -- 'D'  distinct
    -- 'E'  exact match
    -- 'R'  regex match
    -- 'I'  IP address/mask match
    condition char(1) check (condition = 'S' or condition = 'D' or condition = 'E' or condition = 'R' or condition = 'I'),
    value text
);

create index condition_rule_id_idx on condition(rule_id);

create table rule_hit (
    rule_id integer not null references rule(id),
    hit float8 not null,        -- UNIX timestamp + microseconds
    shash text null,            -- SHA1 of matching field values for 'S' matches
    dhash text null             -- SHA1 of matching field values for 'D' matches
);

create index rule_hit_rule_id_idx on rule_hit(rule_id);
create index rule_hit_shash_idx on rule_hit(shash);
create index rule_hit_dhash_idx on rule_hit(dhash);

-- grant all on database ratty to ratty;
