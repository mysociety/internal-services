--
-- schema.sql:
-- Description of regional newspapers and their circulation.
--
-- Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: schema.sql,v 1.4 2006-03-26 13:18:46 louise Exp $
--

create table newspaper (
    id serial not null primary key,
    nsid integer not null unique,  -- Newspaper Society ID
    name text not null,
    editor text,
    address text not null,
    postcode text not null,
    lat double precision,
    lon double precision,
    website text,
    -- publication schedule
    -- daily or weekly?
    isweekly boolean not null default false,
    -- morning or evening
    isevening boolean not null default false,
    -- free or paid for?
    free integer not null default 0,
    -- editorial contact details
    email text,
    fax text,
    telephone text,
    circulation integer, 
    isdeleted boolean not null default false,
    check ((lat is null and lon is null)
            or (lat is not null and lon is not null))
);

create table location (
   id serial not null primary key,
   name text not null,
   population integer not null,
   lat double precision,
   lon double precision,
   check((lat is null and lon is null)
        or (lat is not null and lon is not null))
);

create table coverage (
    id serial not null primary key,
    newspaper_id integer not null references newspaper(id),  
    location_id integer not null references location(id),  
    coverage integer not null
);

create index coverage_newspaper_id_idx on coverage(newspaper_id);
create index coverage_location_id_idx on coverage(location_id);
create index location_lat_idx on location(lat);
create index location_lon_idx on location(lon);

create table newspaper_edit_history (
    id serial not null primary key,
    newspaper_id integer not null references newspaper(id),
    lastchange timestamp not null default current_timestamp,
    source text,            -- either null to mean scraped data, or a username
    data bytea not null,    -- serialised NeWs::Paper object
    isdeleted boolean not null default false
);

