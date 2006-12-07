--
-- schema.sql:
-- Description of regional newspapers and their circulation.
--
-- Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: schema.sql,v 1.6 2006-12-07 15:45:40 louise Exp $
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

-- 
-- Geographical stuff
-- 

-- angle_between A1 A2
-- Given two angles A1 and A2 on a circle expressed in radians, return the
-- smallest angle between them.
create function angle_between(double precision, double precision)
    returns double precision as '
select case
    when abs($1 - $2) > pi() then 2 * pi() - abs($1 - $2)
    else abs($1 - $2)
    end;
' language sql immutable;

-- R_e
-- Radius of the earth, in km. This is something like 6372.8 km:
--  http://en.wikipedia.org/wiki/Earth_radius
create function R_e()
    returns double precision as '
select 6372.8::double precision;
' language sql immutable;

create type location_nearby_match as (
    location_id integer,
    distance double precision   -- km
);

-- location_find_nearby LATITUDE LONGITUDE DISTANCE
-- Find locations within DISTANCE (km) of (LATITUDE, LONGITUDE).
create function location_find_nearby(double precision, double precision, double precision)
    returns setof location_nearby_match as
    -- Write as SQL function so that we don't have to construct a temporary
    -- table or results set in memory. That means we can't check the values of
    -- the parameters, sadly.
    -- Through sheer laziness, just use great-circle distance; that'll be off
    -- by ~0.1%:
    --  http://www.ga.gov.au/nmd/geodesy/datums/distance.jsp
    -- We index locations on lat/lon so that we can select the locations which lie
    -- within a wedge of side about 2 * DISTANCE. That cuts down substantially
    -- on the amount of work we have to do.
'
    -- trunc due to inaccuracies in floating point arithmetic
    select location.id,
           R_e() * acos(trunc(
                (sin(radians($1)) * sin(radians(lat))
                + cos(radians($1)) * cos(radians(lat))
                    * cos(radians($2 - lon)))::numeric, 14)
            ) as distance
        from location
        where
            lon is not null and lat is not null
            and radians(lat) > radians($1) - ($3 / R_e())
            and radians(lat) < radians($1) + ($3 / R_e())
            and (abs(radians($1)) + ($3 / R_e()) > pi() / 2     -- case where search pt is near pole
                    or angle_between(radians(lon), radians($2))
                            < $3 / (R_e() * cos(radians($1 + $3 / R_e()))))
            -- ugly -- unable to use attribute name "distance" here, sadly
            and R_e() * acos(trunc(
                (sin(radians($1)) * sin(radians(lat))
                + cos(radians($1)) * cos(radians(lat))
                    * cos(radians($2 - lon)))::numeric, 14)
                ) < $3
        order by distance desc
' language sql; -- should be "stable" rather than volatile per default?

-- Journalists
--
create table journalist (
    id serial not null primary key,
    name text not null,
    newspaper_id integer not null references newspaper(id),
    lastchange timestamp not null default current_timestamp,
    interests text,
    email text,
    telephone text, 
    fax text,
    isdeleted boolean not null default false
);

create index journalist_newspaper_id_idx on journalist(newspaper_id);

create table journalist_edit_history (
    id serial not null primary key,
    journalist_id integer not null references journalist(id),
    lastchange timestamp not null default current_timestamp,
    source text,            -- a username
    data bytea not null,    -- serialised NeWs::Journalist object
    isdeleted boolean not null default false
);
