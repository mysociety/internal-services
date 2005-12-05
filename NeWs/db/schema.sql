--
-- schema.sql:
-- Description of regional newspapers and their circulation.
--
-- Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: schema.sql,v 1.1 2005-12-05 18:03:40 chris Exp $
--

create table newspaper (
    nsid integer not null primary key,  -- Newspaper Society ID
    deleted boolean not null default false,
    name text not null,
    editor text,
    address text not null,
    website text,
    -- publication schedule
    -- daily or weekly?
    frequency char(1) not null check (frequency in ('D', 'W')),
    -- morning or evening
    daytime char(1) not null check (daytime in ('M', 'E')),
    -- free or paid for?
    isfree boolean not null default false,
    -- editorial contact details
    email text,
    fax text
);

create table coverage (
    nsid integer not null references newspaper(nsid),
    name text not null,
    population integer not null,
    circulation integer not null,
    lat double precision,
    lon double precision,
    check((lat is null and lon is null)
        or (lat is not null and lon is not null))
);

create index coverage_nsid_idx on coverage(nsid);
create index coverage_lat_idx on coverage(lat);
create index coverage_lon_idx on coverage(lon);

create table newspaper_edit_history (
    id serial not null primary key,
    nsid integer not null references newspaper(nsid),
    lastchange timestamp not null default current_timestamp,
    source text,            -- either null to mean scraped data, or a username
    data bytea not null     -- serialised NeWs::Paper object
);

