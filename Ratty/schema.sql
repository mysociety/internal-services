--
-- schema.sql:
-- Postgres schema for rate-limiting.
--
-- Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: schema.sql,v 1.4 2004-11-16 11:11:17 francis Exp $
--

create table rule (
    id serial not null primary key,
    requests integer not null,  -- maximum allowed rate is requests / interval
    interval integer not null,  -- in seconds
    sequence integer not null,  -- place where this rule fits in the order
    note text,                  -- human-readable description
    message text                -- message to display to website user who is blocked
);

create index rule_key_idx on rule(key);

create table condition (
    id serial not null primary key,
    rule_id integer not null references rule(id),
    field text not null,
    -- conditions:
    -- 'S'  single (see below)
    -- 'D'  distinct (see below)
    -- 'E'  exact match (apply rule only when field=value)
    -- 'R'  regex match (apply rule only when field matches perl regexp of value)
    -- 'I'  IP address/mask match (apply rule only when field matches IP mask: w.x.y.z/a.b.c.d or a.b.c.d or w.x.y.z/nn)
    condition char(1) check (condition = 'S' or condition = 'D' or condition = 'E' or condition = 'R' or condition = 'I'),
    value text
);

-- How does the single/distinct stuff work?  When a hit happens for a 
-- rule which has single or disinct conditions, the following happens:
-- 1. Take all of the fields which are matched as single and checksum.
-- 2. Take all of the fields which are matched as distinct and checksum them
-- 3. Save both in rule_hit
-- 4. Now the test for whether the rate limit has triggered is based
--    on the number of hits where the shash is the same and the dhash is
--    different from this hit

-- e.g. Suppose I have a rule limiting to 60 hits / second, by IP
-- address. If the condition was "single" then it would allow every IP to
-- have 60 hits per second each. If the condition was "distinct" then only
-- 60 different IPs would be allowed to access the web page in each
-- second.

create index condition_rule_id_idx on condition(rule_id);

-- used for counting up requests in the time interval, so it knows when the limit is exceeded.
-- this table is not modified to set up rules, it is only written to by ratty
create table rule_hit (
    rule_id integer not null references rule(id),
    hit float8 not null,        -- UNIX timestamp + microseconds
    shash text null,            -- SHA1 of matching field values for 'S' matches
    dhash text null             -- SHA1 of matching field values for 'D' matches
);

create index rule_hit_rule_id_idx on rule_hit(rule_id);
create index rule_hit_shash_idx on rule_hit(shash);
create index rule_hit_dhash_idx on rule_hit(dhash);

-- list of available fields, automatically filled in by ratty.
-- (specify the fields in PHP when you call ratty)
create table available_fields (
    field text not null unique,
    example text not null
);

-- grant all on database ratty to ratty;



